//
//  DevEvent.swift
//  zzz.notch
//
//  Events pushed by local dev tooling (agent hooks, build scripts) through
//  `zzznotch://` URLs.
//
//  - `run` and `wait` are ongoing states: they live in `DevActivityStore`,
//    shown as a count in the closed notch and as a list in the Dev tab, until
//    an event with the same id replaces them, `clear` removes them, or they
//    expire. `wait` also pops up once, since it needs the user.
//  - `ok`, `fail` and `info` are one-off results: they pop up through the
//    notification queue and end the ongoing state with the same id.
//

import AppKit
import SwiftUI

enum DevEventStatus: String {
    case info, ok, fail, wait, run

    var color: Color {
        switch self {
        case .info: .effectiveAccent
        case .ok: .green
        case .fail: .red
        case .wait: .yellow
        case .run: .cyan
        }
    }

    var isOngoing: Bool { self == .run || self == .wait }
}

/// `zzznotch://notify?title=…&body=…` with optional
/// `source` (header label), `status` (info|ok|fail|wait|run), `symbol` (SF Symbol),
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
            subtitle: nil,
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

    /// Ongoing (`run`/`wait`) events, waiting ones first, then newest first.
    @Published private(set) var items: [SystemNotification] = []

    /// An ongoing state nobody updates (crashed tool, killed terminal) must
    /// not haunt the notch forever.
    private let defaultLifetime: TimeInterval = 3600
    private var expiry: [String: Task<Void, Never>] = [:]

    var waitingCount: Int { items.count(where: { $0.status == .wait }) }

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
            remove(event.id)
            SystemNotificationManager.shared.post(event)
            return
        }

        upsert(event)
        if event.status == .wait {
            var popup = event
            popup.displayDuration = nil
            SystemNotificationManager.shared.post(popup)
        } else {
            // Work resumed: the "waiting" popup for this id is stale.
            SystemNotificationManager.shared.dismissActive(token: event.id)
        }
    }

    func remove(_ id: String) {
        expiry.removeValue(forKey: id)?.cancel()
        items.removeAll { $0.id == id }
    }

    private func upsert(_ event: SystemNotification) {
        items.removeAll { $0.id == event.id }
        items.append(event)
        items.sort { lhs, rhs in
            if (lhs.status == .wait) != (rhs.status == .wait) { return lhs.status == .wait }
            return lhs.receivedAt > rhs.receivedAt
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
