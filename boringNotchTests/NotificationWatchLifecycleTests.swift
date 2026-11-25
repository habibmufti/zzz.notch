//
//  NotificationWatchLifecycleTests.swift
//  boringNotchTests
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import XCTest
@testable import boringNotch

final class NotificationWatchLifecycleTests: XCTestCase {
    func testXPCTransactionGuardBalancesAcquireAndRelease() {
        var begins = 0
        var ends = 0

        do {
            let guardObject = XPCTransactionGuard(
                begin: { begins += 1 },
                end: { ends += 1 }
            )

            XCTAssertFalse(guardObject.isActive)
            guardObject.acquire()
            guardObject.acquire()
            XCTAssertTrue(guardObject.isActive)
            XCTAssertEqual(begins, 1)
            XCTAssertEqual(ends, 0)

            guardObject.release()
            guardObject.release()
            XCTAssertFalse(guardObject.isActive)
            XCTAssertEqual(begins, 1)
            XCTAssertEqual(ends, 1)

            guardObject.acquire()
            XCTAssertEqual(begins, 2)
            XCTAssertEqual(ends, 1)
        }

        // Deinit must release any still-held transaction.
        XCTAssertEqual(begins, 2)
        XCTAssertEqual(ends, 2)
    }

    @MainActor
    func testSupervisorRecoversAfterHelperDisconnectAndSyncsFilterBeforeStart() async {
        var events: [String] = []
        var startResults = [true, false, true]

        let supervisor = NotificationWatchSupervisor(
            disconnectDelay: .milliseconds(10),
            wakeDelay: .milliseconds(10),
            retryDelays: [.milliseconds(15), .milliseconds(30)],
            isAuthorized: {
                events.append("auth")
                return true
            },
            syncFilter: {
                events.append("filter")
            },
            startWatching: {
                events.append("start")
                return startResults.isEmpty ? true : startResults.removeFirst()
            },
            stopWatching: {
                events.append("stop")
            }
        )

        await supervisor.start()
        XCTAssertTrue(supervisor.isDesiredWatching)
        XCTAssertEqual(events, ["auth", "filter", "start"])

        // Simulate XPC helper idle-exit kill: first reconnect fails, retry succeeds.
        events.removeAll()
        supervisor.handleHelperDisconnected()
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(events, ["auth", "filter", "start", "auth", "filter", "start"])
    }

    @MainActor
    func testSupervisorReverifiesOnSystemWakeAndIgnoresEventsWhenStopped() async {
        var events: [String] = []

        let supervisor = NotificationWatchSupervisor(
            disconnectDelay: .milliseconds(10),
            wakeDelay: .milliseconds(10),
            wakeCooldown: .zero,
            retryDelays: [.milliseconds(15)],
            isAuthorized: {
                events.append("auth")
                return true
            },
            syncFilter: {
                events.append("filter")
            },
            startWatching: {
                events.append("start")
                return true
            },
            stopWatching: {
                events.append("stop")
            }
        )

        await supervisor.start()
        events.removeAll()

        supervisor.handleSystemWake()
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(events, ["auth", "filter", "start"])

        events.removeAll()
        supervisor.stop()
        XCTAssertFalse(supervisor.isDesiredWatching)
        XCTAssertEqual(events, ["stop"])

        events.removeAll()
        supervisor.handleHelperDisconnected()
        supervisor.handleSystemWake()
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(events.isEmpty)
    }

    @MainActor
    func testSupervisorSkipsRedundantWakeWithinCooldown() async {
        var startCalls = 0

        let supervisor = NotificationWatchSupervisor(
            disconnectDelay: .milliseconds(10),
            wakeDelay: .milliseconds(10),
            wakeCooldown: .seconds(5),
            retryDelays: [],
            isAuthorized: { true },
            syncFilter: {},
            startWatching: {
                startCalls += 1
                return true
            },
            stopWatching: {}
        )

        await supervisor.start()
        XCTAssertEqual(startCalls, 1)

        // Back-to-back didWake + screensDidWake immediately after start should not trigger redundant XPC work.
        supervisor.handleSystemWake()
        supervisor.handleSystemWake()
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(startCalls, 1)

        // Disconnect clears cooldown so helper recovery still runs immediately.
        supervisor.handleHelperDisconnected()
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(startCalls, 2)
    }

    @MainActor
    func testSupervisorCapsConsecutiveDisconnectRecoveryCrashLoops() async {
        var startCalls = 0

        let supervisor = NotificationWatchSupervisor(
            disconnectDelay: .milliseconds(5),
            wakeDelay: .milliseconds(5),
            retryDelays: [],
            maxConsecutiveDisconnectRecoveries: 2,
            isAuthorized: { true },
            syncFilter: {},
            startWatching: {
                startCalls += 1
                return false
            },
            stopWatching: {}
        )

        await supervisor.start()
        startCalls = 0

        supervisor.handleHelperDisconnected()
        try? await Task.sleep(for: .milliseconds(25))
        supervisor.handleHelperDisconnected()
        try? await Task.sleep(for: .milliseconds(25))
        // Third consecutive disconnect without a successful start is ignored.
        supervisor.handleHelperDisconnected()
        try? await Task.sleep(for: .milliseconds(25))

        XCTAssertEqual(startCalls, 2)
    }
}
