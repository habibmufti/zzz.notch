//
//  AboutView.swift
//  zzz.notch
//

import Defaults
import SwiftUI

struct AboutView: View {
    @State private var showBuildNumber: Bool = false
    @ObservedObject private var updater = CIUpdater.shared

    var body: some View {
        VStack {
            Form {
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        if showBuildNumber {
                            Text("(\(Bundle.main.buildVersionNumber ?? ""))")
                                .foregroundStyle(.secondary)
                        }
                        Text(Bundle.main.releaseVersionNumber ?? "unknown")
                            .foregroundStyle(.secondary)
                    }
                    .onTapGesture {
                        withAnimation {
                            showBuildNumber.toggle()
                        }
                    }

                    HStack {
                        Text("Commit")
                        Spacer()
                        Text(updater.currentShortSHA)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Version info")
                }

                UpdaterSettingsView()

                HStack(spacing: 30) {
                    Spacer(minLength: 0)
                    Button {
                        if let url = URL(string: "https://github.com/habibmufti/zzz.notch/issues") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: "exclamationmark.bubble")
                                .font(.system(size: 15, weight: .medium))
                                .frame(height: 18)
                            Text("Issues")
                        }
                        .contentShape(Rectangle())
                    }
                    Button {
                        if let url = URL(string: "https://github.com/habibmufti/zzz.notch") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        VStack(spacing: 5) {
                            Image("Github")
                                .resizable().scaledToFit()
                                .frame(width: 18, height: 18)
                                .foregroundStyle(.primary)
                            Text("GitHub")
                        }
                        .contentShape(Rectangle())
                    }
                    Spacer(minLength: 0)
                }
                .buttonStyle(PlainButtonStyle())
            }
            VStack(spacing: 0) {
                Divider()
                Text("zzz.notch · Forked from boring.notch (GPL-3.0)")
                    .foregroundStyle(.secondary)
                    .padding(.top, 5)
                    .padding(.bottom, 7)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .toolbar {
            CheckForUpdatesView()
        }
        .navigationTitle("About")
    }
}
