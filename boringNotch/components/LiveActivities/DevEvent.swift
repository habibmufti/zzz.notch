//
//  DevEvent.swift
//  zzz.notch
//
//  Events pushed by local dev tooling (agent hooks, build scripts) through
//  `zzznotch://` URLs.
//
//  - `run`, `wait` and `idle` are ongoing states: they live in
//    `DevActivityStore`, one pixel mascot per id in the closed notch and a
//    row in the Dev tab, until `clear` removes them or they expire. Another
//    status for the same id changes the mascot's mood. `wait` also pops up
//    once, since it needs the user.
//  - `ok`, `fail` and `info` are one-off results: they pop up through the
//    notification queue. `ok`/`fail` on a live id let its mascot react for a
//    few seconds, then it leaves unless an ongoing status follows.
//

import AppKit
import SwiftUI

enum DevEventStatus: String {
    case info, ok, fail, wait, run, idle

    var color: Color {
        switch self {
        case .info: .effectiveAccent
        case .ok: .green
        case .fail: .red
        case .wait: .yellow
        case .run: .cyan
        case .idle: .gray
        }
    }

    var isOngoing: Bool { self == .run || self == .wait || self == .idle }

    var mascotMood: MascotMood {
        switch self {
        case .run: .working
        case .wait: .waiting
        case .ok: .done
        case .info, .fail, .idle: .idle
        }
    }
}

/// `zzznotch://notify?title=…&body=…` with optional
/// `detail` (what it is doing right now, e.g. the current tool call),
/// `source` (header label), `status` (info|ok|fail|wait|run|idle), `symbol` (SF Symbol),
/// `app` (bundle ID for the icon), `url` (opened on click),
/// `id` (an event reusing a live id replaces it), `duration` (seconds; popup
/// time for one-off events, lifetime for ongoing ones).
/// `zzznotch://clear?id=…` drops the ongoing state with that id.
enum DevEventURL {
    static let scheme = "zzznotch"

    static func notification(from url: URL, now: Date = Date()) -> SystemNotification? {
        guard let query = query(of: url, host: "notify"),
              query["title"] != nil || query["body"] != nil
        else { return nil }

        return SystemNotification(
            id: eventID(query["id"] ?? UUID().uuidString),
            appName: query["source"] ?? "zzz",
            bundleID: query["app"],
            title: query["title"],
            subtitle: query["detail"],
            body: query["body"],
            receivedAt: now,
            symbol: query["symbol"],
            status: query["status"].flatMap { DevEventStatus(rawValue: $0.lowercased()) } ?? .info,
            actionURL: query["url"].flatMap(URL.init(string:)),
            displayDuration: query["duration"].flatMap(TimeInterval.init).map { min(max($0, 1), 86_400) }
        )
    }

    static func clearedID(from url: URL) -> String? {
        query(of: url, host: "clear")?["id"].map(eventID)
    }

    private static func eventID(_ raw: String) -> String { "dev-" + raw }

    private static func query(of url: URL, host: String) -> [String: String]? {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }

        var query: [String: String] = [:]
        for item in items {
            if let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                query[item.name] = value
            }
        }
        return query
    }
}

@MainActor
final class DevActivityStore: ObservableObject {
    static let shared = DevActivityStore()

    /// Ongoing events, in the order their ids first appeared, so each
    /// session's mascot keeps its spot in the notch.
    @Published private(set) var items: [SystemNotification] = []
    /// Ids that just finished with `ok`, mapped to when their celebration ends.
    @Published private(set) var celebratingUntil: [String: Date] = [:]

    /// An ongoing state nobody updates (crashed tool, killed terminal) must
    /// not haunt the notch forever.
    private let defaultLifetime: TimeInterval = 3600
    /// How long an `ok`/`fail` keeps its mascot on screen when no ongoing
    /// status follows.
    private let resultLinger: TimeInterval = 4
    private var expiry: [String: Task<Void, Never>] = [:]

    func handle(_ url: URL) {
        if let id = DevEventURL.clearedID(from: url) {
            remove(id)
            SystemNotificationManager.shared.dismissActive(token: id)
        } else if let event = DevEventURL.notification(from: url) {
            post(event)
        }
    }

    func post(_ event: SystemNotification) {
        guard event.status?.isOngoing == true else {
            // A result ends the ongoing state; if one existed, its mascot
            // stays a moment to react before leaving.
            if items.contains(where: { $0.id == event.id }) {
                if event.status == .ok { celebratingUntil[event.id] = Date().addingTimeInterval(resultLinger) }
                var result = event
                result.displayDuration = resultLinger
                upsert(result)
            }
            SystemNotificationManager.shared.post(event)
            return
        }

        upsert(event)
        if event.status == .wait {
            var popup = event
            popup.displayDuration = nil
            SystemNotificationManager.shared.post(popup)
        } else if event.status == .run {
            // Work resumed: the "waiting" popup for this id is stale.
            SystemNotificationManager.shared.dismissActive(token: event.id)
        }
    }

    func remove(_ id: String) {
        expiry.removeValue(forKey: id)?.cancel()
        celebratingUntil[id] = nil
        items.removeAll { $0.id == id }
    }

    func mood(of item: SystemNotification, at now: Date) -> MascotMood {
        if let until = celebratingUntil[item.id], until > now { return .done }
        if item.status == .idle, now.timeIntervalSince(item.receivedAt) > 180 { return .sleep }
        return item.status?.mascotMood ?? .idle
    }

    private func upsert(_ event: SystemNotification) {
        if let index = items.firstIndex(where: { $0.id == event.id }) {
            // Detail-only updates keep the clock of the state they belong to.
            var event = event
            if items[index].status == event.status { event.receivedAt = items[index].receivedAt }
            items[index] = event
        } else {
            items.append(event)
        }

        expiry[event.id]?.cancel()
        let lifetime = event.displayDuration ?? defaultLifetime
        expiry[event.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(lifetime))
            guard !Task.isCancelled else { return }
            self?.remove(event.id)
        }
    }
}
