//
//  SoftwareUpdater.swift
//  zzz.notch
//
//  Replaces upstream Sparkle (which cannot re-sign locally and resets macOS
//  privacy grants on every update) with a lightweight GitHub Actions CI
//  checker + detached runner for `tools/install.sh`.
//

import Defaults
import Foundation
import SwiftUI

@MainActor
final class CIUpdater: ObservableObject {
    static let shared = CIUpdater()

    enum State: Equatable {
        case idle
        case checking
        case upToDate(sha: String)
        case available(runID: String, sha: String, title: String)
        case installing(runID: String)
        case failed(String)
    }

    static let repo = "habibmufti/zzz.notch"
    static let branch = "main"
    static let workflow = "Build for macOS"

    @Published private(set) var state: State = .idle

    var currentSHA: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "ZZZBuildSHA") as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var currentShortSHA: String {
        currentSHA.map { String($0.prefix(7)) } ?? "local"
    }

    private struct CIRun: Decodable, Sendable {
        let databaseId: Int
        let headSha: String
        let displayTitle: String
    }

    func checkForUpdates() {
        guard state != .checking else { return }
        state = .checking
        let localSHA = currentSHA

        Task {
            do {
                let latest = try await Self.fetchLatestSuccessfulRun()
                let shortSHA = String(latest.headSha.prefix(7))
                if let localSHA, latest.headSha.hasPrefix(localSHA) || localSHA.hasPrefix(latest.headSha) {
                    state = .upToDate(sha: shortSHA)
                } else {
                    state = .available(
                        runID: String(latest.databaseId),
                        sha: shortSHA,
                        title: latest.displayTitle
                    )
                }
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func installLatest(runID: String? = nil) {
        let scriptPath = NSString(string: Defaults[.devInstallScriptPath]).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: scriptPath) else {
            state = .failed("install.sh not found or not executable at \(scriptPath)")
            return
        }

        state = .installing(runID: runID ?? "latest")

        Task.detached {
            let escapedScript = Self.shellQuote(scriptPath)
            let arg = runID.map { " " + Self.shellQuote($0) } ?? ""
            let cmd = "nohup /bin/bash \(escapedScript)\(arg) >/tmp/zzz-notch-update.log 2>&1 </dev/null &"

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", cmd]
            var env = ProcessInfo.processInfo.environment
            let extraPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            env["PATH"] = extraPath + (env["PATH"].map { ":" + $0 } ?? "")
            process.environment = env

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    await MainActor.run {
                        CIUpdater.shared.state = .failed("Failed to launch install.sh (exit \(process.terminationStatus))")
                    }
                }
            } catch {
                await MainActor.run {
                    CIUpdater.shared.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    private nonisolated static func fetchLatestSuccessfulRun() async throws -> CIRun {
        try await Task.detached {
            let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
                .first { FileManager.default.isExecutableFile(atPath: $0) }
            guard let gh else {
                throw NSError(
                    domain: "CIUpdater",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "`gh` CLI not found in PATH"]
                )
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: gh)
            process.arguments = [
                "run", "list",
                "-R", repo,
                "--branch", branch,
                "--workflow", workflow,
                "--status", "success",
                "-L", "1",
                "--json", "databaseId,headSha,displayTitle",
            ]
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err

            try process.run()
            process.waitUntilExit()

            let data = out.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "gh exited \(process.terminationStatus)"
                throw NSError(domain: "CIUpdater", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errText])
            }

            let runs = try JSONDecoder().decode([CIRun].self, from: data)
            guard let latest = runs.first else {
                throw NSError(domain: "CIUpdater", code: 2, userInfo: [NSLocalizedDescriptionKey: "No successful CI runs found"])
            }
            return latest
        }.value
    }

    private nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var updater = CIUpdater.shared

    var body: some View {
        Button(buttonTitle) {
            switch updater.state {
            case .available(let runID, _, _):
                updater.installLatest(runID: runID)
            default:
                updater.installLatest()
            }
        }
        .disabled(isBusy)
    }

    private var isBusy: Bool {
        if case .installing = updater.state { return true }
        return false
    }

    private var buttonTitle: String {
        switch updater.state {
        case .available(_, let sha, _): "Install CI Update (\(sha))…"
        case .installing: "Installing CI Update…"
        default: "Update from Latest CI…"
        }
    }
}

struct UpdaterSettingsView: View {
    @ObservedObject private var updater = CIUpdater.shared
    @Default(.devInstallScriptPath) private var installScriptPath

    var body: some View {
        Section {
            HStack {
                Text("Status")
                Spacer()
                statusView
            }

            TextField("Installer script", text: $installScriptPath)
                .font(.system(size: 11, design: .monospaced))

            HStack {
                Button("Check CI") {
                    updater.checkForUpdates()
                }
                .disabled(updater.state == .checking)

                Spacer()

                if case .available(let runID, let sha, _) = updater.state {
                    Button("Install \(sha)") {
                        updater.installLatest(runID: runID)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Install Latest CI") {
                        updater.installLatest()
                    }
                }
            }
        } header: {
            Text("CI Updates")
        } footer: {
            Text("Downloads the latest GitHub Actions build on branch main and re-signs it with your local identity via install.sh so macOS privacy grants persist.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch updater.state {
        case .idle:
            Text("Ready")
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        case .upToDate(let sha):
            Text("Up to date (\(sha))")
                .foregroundStyle(.green)
        case .available(_, let sha, let title):
            Text("\(sha) · \(title)")
                .foregroundStyle(.orange)
                .lineLimit(1)
        case .installing(let runID):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Installing \(runID)…").foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }
}
