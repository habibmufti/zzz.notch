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
import Defaults
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
/// time for one-off events, lifetime for ongoing ones),
/// `activity` (type|search|build|push|read: the mascot's pose),
/// `agents` (running subagent count, shown as a badge),
/// `prompt` (the user's request, shown in place of `body` while set),
/// `now` (headline of the current step), `intent` (why), `command` (raw
/// command, path or pattern, monospaced), `step` (plan position, sticky),
/// `agentList` (running subagents, one "name · task" per line, sticky; `agents=0` clears it).
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
            displayDuration: query["duration"].flatMap(TimeInterval.init).map { min(max($0, 1), 86_400) },
            activity: query["activity"],
            agents: query["agents"].flatMap(Int.init),
            prompt: query["prompt"],
            now: query["now"],
            intent: query["intent"],
            command: query["command"],
            step: query["step"],
            agentList: query["agentList"]
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
    /// Last few `detail` lines per id, oldest first, shown on row hover.
    @Published private(set) var recent: [String: [String]] = [:]

    /// An ongoing state nobody updates (crashed tool, killed terminal) must
    /// not haunt the notch forever.
    private let defaultLifetime: TimeInterval = 3600
    /// How long an `ok`/`fail` keeps its mascot on screen when no ongoing
    /// status follows.
    private let resultLinger: TimeInterval = 4
    /// Idle for this long, a mascot falls asleep and sorts last.
    private let sleepAfter: TimeInterval = 180
    private let recentLimit = 5
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
            playSound(for: event.status)
            SystemNotificationManager.shared.post(event)
            return
        }

        // Re-sends of the same state (e.g. a subagent count change) must
        // not re-pop or re-ring.
        let wasWaiting = items.first(where: { $0.id == event.id })?.status == .wait
        upsert(event)
        if let detail = event.subtitle, recent[event.id]?.last != detail {
            recent[event.id] = Array((recent[event.id, default: []] + [detail]).suffix(recentLimit))
        }
        if event.status == .wait, !wasWaiting {
            var popup = event
            popup.displayDuration = nil
            playSound(for: .wait)
            SystemNotificationManager.shared.post(popup)
        } else if event.status == .run {
            // Work resumed: the "waiting" popup for this id is stale.
            SystemNotificationManager.shared.dismissActive(token: event.id)
        }
    }

    func remove(_ id: String) {
        expiry.removeValue(forKey: id)?.cancel()
        celebratingUntil[id] = nil
        recent[id] = nil
        items.removeAll { $0.id == id }
    }

    func mood(of item: SystemNotification, at now: Date) -> MascotMood {
        if let until = celebratingUntil[item.id], until > now { return .done }
        if item.status == .idle, now.timeIntervalSince(item.receivedAt) > sleepAfter { return .sleep }
        return item.status?.mascotMood ?? .idle
    }

    /// The Dev tab's order: waiting first, then running, finished, idle, and
    /// sleeping idle last. Stable within a priority, so rows move only when
    /// their state does. The closed notch keeps `items` order instead.
    var sortedItems: [SystemNotification] {
        let now = Date()
        return items.enumerated()
            .sorted { lhs, rhs in
                let a = priority(of: lhs.element, at: now)
                let b = priority(of: rhs.element, at: now)
                return a != b ? a < b : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private func priority(of item: SystemNotification, at now: Date) -> Int {
        if let until = celebratingUntil[item.id], until > now { return 2 }
        switch item.status {
        case .wait: return 0
        case .run: return 1
        case .ok: return 2
        case .idle: return now.timeIntervalSince(item.receivedAt) > sleepAfter ? 4 : 3
        case .info, .fail, .none: return 3
        }
    }

    private func playSound(for status: DevEventStatus?) {
        guard Defaults[.devSounds] else { return }
        let name: String
        switch status {
        case .ok: name = "Glass"
        case .fail: name = "Basso"
        case .wait: name = "Ping"
        default: return
        }
        NSSound(named: name)?.play()
    }

    private func upsert(_ event: SystemNotification) {
        if let index = items.firstIndex(where: { $0.id == event.id }) {
            // Detail-only updates keep the clock of the state they belong to,
            // and a prompt, step or agent list stays until a new one replaces it.
            var event = event
            if items[index].status == event.status { event.receivedAt = items[index].receivedAt }
            if event.prompt == nil { event.prompt = items[index].prompt }
            if event.step == nil { event.step = items[index].step }
            // `agents=0` says no subagents are left; otherwise a missing list carries over.
            if event.agents == 0 {
                event.agentList = nil
            } else if event.agentList == nil {
                event.agentList = items[index].agentList
            }
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
