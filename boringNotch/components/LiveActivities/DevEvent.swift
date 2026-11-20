//
//  DevEvent.swift
//  zzz.notch
//
//  Events pushed by local dev tooling (agent hooks, shell hooks, CI watchers)
//  through the `zzznotch://notify` URL. They ride the notification pipeline:
//  same queue, same closed-notch live activity, same expanded view.
//

import AppKit
import SwiftUI

enum DevEventStatus: String {
    case info, ok, fail, wait

    var color: Color {
        switch self {
        case .info: .effectiveAccent
        case .ok: .green
        case .fail: .red
        case .wait: .yellow
        }
    }
}

/// `zzznotch://notify?title=…&body=…` with optional
/// `source` (header label), `status` (info|ok|fail|wait), `symbol` (SF Symbol),
/// `app` (bundle ID for the icon), `url` (opened on click),
/// `id` (an event reusing a live id replaces it), `duration` (seconds on screen).
enum DevEventURL {
    static let scheme = "zzznotch"

    static func notification(from url: URL, now: Date = Date()) -> SystemNotification? {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == "notify",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }

        var query: [String: String] = [:]
        for item in items {
            if let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                query[item.name] = value
            }
        }
        guard query["title"] != nil || query["body"] != nil else { return nil }

        return SystemNotification(
            id: "dev-" + (query["id"] ?? UUID().uuidString),
            appName: query["source"] ?? "zzz",
            bundleID: query["app"],
            title: query["title"],
            subtitle: nil,
            body: query["body"],
            receivedAt: now,
            symbol: query["symbol"],
            status: query["status"].flatMap { DevEventStatus(rawValue: $0.lowercased()) } ?? .info,
            actionURL: query["url"].flatMap(URL.init(string:)),
            displayDuration: query["duration"].flatMap(TimeInterval.init).map { min(max($0, 1), 3600) }
        )
    }
}
