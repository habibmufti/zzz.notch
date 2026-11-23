//
//  NotchUIEventTests.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Smoke tests for the seams introduced during the architecture remediation.
//

import XCTest
import Combine
import SwiftUI
@testable import boringNotch

final class NotchUIEventTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    /// Managers publish; the presenter subscribes — the seam that replaced
    /// direct manager->coordinator calls. This is the contract.
    func testSneakPeekEventDeliversPayload() {
        let expectation = expectation(description: "event delivered")
        NotchUIEventBus.events
            .sink { event in
                guard case .sneakPeek(let type, let value, let icon, _, let uuid, _) = event else {
                    XCTFail("unexpected event")
                    return
                }
                XCTAssertEqual(type, .volume)
                XCTAssertEqual(value, 0.5, accuracy: 0.0001)
                XCTAssertEqual(icon, "speaker.wave.2")
                XCTAssertNil(uuid)
                expectation.fulfill()
            }
            .store(in: &cancellables)

        NotchUIEventBus.events.send(.sneakPeek(type: .volume, value: 0.5, icon: "speaker.wave.2"))
        waitForExpectations(timeout: 1.0)
    }

    func testExpandingViewEventDeliversType() {
        let expectation = expectation(description: "expanding event delivered")
        NotchUIEventBus.events
            .sink { event in
                guard case .expandingView(let type) = event else {
                    XCTFail("unexpected event")
                    return
                }
                XCTAssertEqual(type, .download)
                expectation.fulfill()
            }
            .store(in: &cancellables)

        NotchUIEventBus.events.send(.expandingView(type: .download))
        waitForExpectations(timeout: 1.0)
    }
}

final class MediaAppBundleIDTests: XCTestCase {
    func testBundleIDsAreDistinctAndWellFormed() {
        let ids = [
            MediaAppBundleID.appleMusic,
            MediaAppBundleID.spotify,
            MediaAppBundleID.youTubeMusic,
        ]
        XCTAssertEqual(ids.count, Set(ids).count, "bundle IDs must be unique")
        for id in ids {
            XCTAssertFalse(id.isEmpty)
            XCTAssertTrue(id.contains("."), "malformed bundle id: \(id)")
        }
    }
}

final class PlaybackStateTests: XCTestCase {
    func testEquatableIgnoresVolatileFields() {
        var a = PlaybackState(bundleIdentifier: MediaAppBundleID.spotify, isPlaying: true)
        a.title = "Track"
        a.currentTime = 42

        var b = a
        // Volatile/monitor-side fields that must not defeat `==`:
        // volume, playbackRate and lastUpdated are intentionally excluded.
        b.volume = 0.9
        b.playbackRate = 0.75
        b.lastUpdated = Date()

        XCTAssertEqual(a, b)
    }

    func testEquatableTracksUserVisibleFields() {
        var a = PlaybackState(bundleIdentifier: MediaAppBundleID.spotify, isPlaying: true)
        a.title = "Track"

        var b = a
        b.isFavorite = true
        XCTAssertNotEqual(a, b, "isFavorite is user-visible and must be compared")

        b = a
        b.currentTime += 1
        XCTAssertNotEqual(a, b, "position changes must be visible to == to drive UI updates")
    }
}

@MainActor final class ExpandedViewPixelTests: XCTestCase {

    /// Renders NotificationExpandedView offscreen and counts non-black
    /// pixels. Guards the reported "open notch is empty with a notification"
    /// regression.
    func testNotificationExpandedViewPaintsContent() throws {
        let notification = SystemNotification(
            id: "test-token", appName: "WhatsApp", bundleID: "net.whatsapp.WhatsApp",
            title: "Sender", subtitle: nil, body: "hello",
            receivedAt: Date())

        let view = NotificationExpandedView(notification: notification)
            .environmentObject(BoringViewModel())
            .frame(width: 380, height: 132)

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = CGRect(x: 0, y: 0, width: 380, height: 132)
        hostingView.layoutSubtreeIfNeeded()

        guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            XCTFail("could not create bitmap rep")
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)

        guard let data = rep.bitmapData else {
            XCTFail("no bitmap data")
            return
        }
        var nonBlack = 0
        let bytes = rep.pixelsWide * rep.pixelsHigh * max(1, rep.samplesPerPixel)
        for i in stride(from: 0, to: bytes, by: 4 * 40) { // sample every ~10th px
            if data[i] > 30 || data[i + 1] > 30 || data[i + 2] > 30 {
                nonBlack += 1
            }
        }
        XCTAssertGreaterThan(nonBlack, 20, "expanded view rendered ~empty")
    }

    func testPeekContentShownForSystemNotifications() {
        let whatsapp = SystemNotification(
            id: "wa-1", appName: "WhatsApp", bundleID: "net.whatsapp.WhatsApp",
            title: "Budi", subtitle: nil, body: "Lagi dimana?",
            receivedAt: Date())
        XCTAssertEqual(
            NotificationLiveActivity.peekContent(for: whatsapp),
            .init(title: "Budi", source: "WhatsApp", body: "Lagi dimana?")
        )

        let mail = SystemNotification(
            id: "mail-1", appName: "Mail", bundleID: "com.apple.mail",
            title: "Alice", subtitle: "Standup", body: "Starts in 5 min",
            receivedAt: Date())
        XCTAssertEqual(
            NotificationLiveActivity.peekContent(for: mail),
            .init(title: "Alice", source: "Mail", body: "Standup · Starts in 5 min")
        )

        let noTitle = SystemNotification(
            id: "cal-1", appName: "Calendar", bundleID: "com.apple.iCal",
            title: nil, subtitle: nil, body: "Meeting now",
            receivedAt: Date())
        XCTAssertEqual(
            NotificationLiveActivity.peekContent(for: noTitle),
            .init(title: "Calendar", source: nil, body: "Meeting now")
        )

        let matchingTitle = SystemNotification(
            id: "discord-1", appName: "Discord", bundleID: "com.hnc.Discord",
            title: "Discord", subtitle: "General", body: nil,
            receivedAt: Date())
        XCTAssertEqual(
            NotificationLiveActivity.peekContent(for: matchingTitle),
            .init(title: "Discord", source: nil, body: "General")
        )

        let devDone = SystemNotification(
            id: "dev-1", appName: "agy", bundleID: nil,
            title: "● zzz.notch", subtitle: "bash: xcodebuild", body: "Done",
            receivedAt: Date(), status: .ok)
        XCTAssertEqual(
            NotificationLiveActivity.peekContent(for: devDone),
            .init(title: "zzz.notch", source: "agy", body: "Done")
        )

        let empty = SystemNotification(
            id: "empty-1", appName: nil, bundleID: nil,
            title: nil, subtitle: nil, body: nil,
            receivedAt: Date())
        XCTAssertNil(NotificationLiveActivity.peekContent(for: empty))
    }

    func testSystemNotificationLiveActivityExpandsBelowPill() {
        let vm = BoringViewModel()
        vm.hideOnClosed = false
        vm.closedNotchSize = CGSize(width: 185, height: 32)

        let notification = SystemNotification(
            id: "wa-peek", appName: "WhatsApp", bundleID: "net.whatsapp.WhatsApp",
            title: "Sender", subtitle: nil, body: "Hello from WhatsApp",
            receivedAt: Date())

        let view = NotificationLiveActivity(notification: notification)
            .environmentObject(vm)
        let hostingView = NSHostingView(rootView: view)
        let fittingSize = hostingView.fittingSize

        XCTAssertGreaterThan(
            fittingSize.height,
            vm.effectiveClosedNotchHeight + 10,
            "system notification should grow downward with peek content like dev notifications"
        )
    }

    func testNotificationHistoryLifecycleAndPersistence() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zzznotch-history-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("notification-history.json")

        let manager = SystemNotificationManager(storageURL: fileURL, observeSystemNotifications: false)
        let now = Date()

        // 1. Capture dev result & regular notification; ignore ongoing run/idle.
        let running = SystemNotification(
            id: "dev-run", appName: "agy", bundleID: nil,
            title: "zzz.notch", subtitle: nil, body: "Working",
            receivedAt: now, status: .run)
        manager.post(running)
        XCTAssertTrue(manager.history.isEmpty, "ongoing run events should not spam history")

        let done = SystemNotification(
            id: "dev-done", appName: "agy", bundleID: nil,
            title: "zzz.notch", subtitle: nil, body: "Finished build",
            receivedAt: now, status: .ok)
        manager.post(done)
        XCTAssertEqual(manager.history.count, 1)
        XCTAssertEqual(manager.unreadCount, 1)

        // Timeout dismiss keeps item in history.
        manager.dismissActive(token: "dev-done")
        XCTAssertNil(manager.activeNotification)
        XCTAssertEqual(manager.history.count, 1)

        // 2. Dedupe moves updated item to top and marks unread.
        manager.markAllHistoryRead()
        XCTAssertEqual(manager.unreadCount, 0)

        let wa = SystemNotification(
            id: "wa-1", appName: "WhatsApp", bundleID: "net.whatsapp.WhatsApp",
            title: "Budi", subtitle: nil, body: "Halo",
            receivedAt: now.addingTimeInterval(5))
        manager.recordInHistory(wa, now: now.addingTimeInterval(5))
        XCTAssertEqual(manager.history.map(\.id), ["wa-1", "dev-done"])
        XCTAssertEqual(manager.unreadCount, 1)

        let doneUpdated = SystemNotification(
            id: "dev-done", appName: "agy", bundleID: nil,
            title: "zzz.notch", subtitle: nil, body: "Finished tests",
            receivedAt: now.addingTimeInterval(10), status: .ok)
        manager.recordInHistory(doneUpdated, now: now.addingTimeInterval(10))
        XCTAssertEqual(manager.history.map(\.id), ["dev-done", "wa-1"])
        XCTAssertEqual(manager.history.first?.body, "Finished tests")
        XCTAssertEqual(manager.unreadCount, 2)

        // 3. Explicit dismiss with removeFromHistory removes it from history.
        manager.post(wa)
        manager.dismissActive(token: "wa-1", dismissNative: false, removeFromHistory: true)
        XCTAssertEqual(manager.history.map(\.id), ["dev-done"])

        // 4. Reload from disk preserves surviving items and prunes expired (>24h).
        let stale = SystemNotification(
            id: "stale-1", appName: "Mail", bundleID: "com.apple.mail",
            title: "Old", subtitle: nil, body: "Yesterday",
            receivedAt: now.addingTimeInterval(-(SystemNotificationManager.historyRetention + 60)))
        manager.recordInHistory(stale, now: now.addingTimeInterval(-(SystemNotificationManager.historyRetention + 60)))
        let reloaded = SystemNotificationManager(storageURL: fileURL, observeSystemNotifications: false)
        XCTAssertEqual(reloaded.history.map(\.id), ["dev-done"])

        // 5. Enforces 50-item capacity cap (newest kept).
        for i in 0..<60 {
            let note = SystemNotification(
                id: "cap-\(i)", appName: "App", bundleID: nil,
                title: "Title \(i)", subtitle: nil, body: "Body \(i)",
                receivedAt: now.addingTimeInterval(Double(i)))
            reloaded.recordInHistory(note, now: now.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(reloaded.history.count, SystemNotificationManager.historyLimit)
        XCTAssertEqual(reloaded.history.first?.id, "cap-59")
        XCTAssertEqual(reloaded.history.last?.id, "cap-10")

        // 6. Clicking a history entry removes it from the list (inbox-zero).
        let clickTarget = SystemNotification(
            id: "dev-click", appName: "agy", bundleID: nil,
            title: "zzz.notch", subtitle: nil, body: "Ready",
            receivedAt: now.addingTimeInterval(70), status: .ok)
        reloaded.recordInHistory(clickTarget, now: now.addingTimeInterval(70))
        let topEntry = try XCTUnwrap(reloaded.history.first)
        XCTAssertEqual(topEntry.id, "dev-click")
        _ = await reloaded.openHistoryEntry(topEntry)
        XCTAssertFalse(reloaded.history.contains(where: { $0.id == "dev-click" }))

        // 7. Clear removes everything and persists empty state.
        reloaded.clearHistory()
        XCTAssertTrue(reloaded.history.isEmpty)
        let afterClear = SystemNotificationManager(storageURL: fileURL, observeSystemNotifications: false)
        XCTAssertTrue(afterClear.history.isEmpty)
    }

    func testHomeRecentNotificationsShowsTopThree() {
        let now = Date()
        let entries = (0..<5).map { idx in
            NotificationHistoryEntry(
                from: SystemNotification(
                    id: "home-\(idx)", appName: "App", bundleID: nil,
                    title: "Title \(idx)", subtitle: nil, body: "Body \(idx)",
                    receivedAt: now.addingTimeInterval(Double(-idx))
                )
            )
        }
        let visible = HomeRecentNotificationsView.visibleEntries(from: entries)
        XCTAssertEqual(visible.map(\.id), ["home-0", "home-1", "home-2"])
        XCTAssertTrue(HomeRecentNotificationsView.visibleEntries(from: []).isEmpty)
    }
}
