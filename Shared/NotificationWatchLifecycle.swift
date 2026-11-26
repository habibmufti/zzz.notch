//
//  NotificationWatchLifecycle.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import Foundation
import XPC

/// Balances `xpc_transaction_begin()` / `xpc_transaction_end()` so an XPC helper
/// holding a long-lived background observer is not killed by macOS `memorystatus`
/// idle-exit while watching, and becomes idle-exitable again once stopped.
final class XPCTransactionGuard: @unchecked Sendable {
    private let lock = NSLock()
    private let begin: () -> Void
    private let end: () -> Void
    private var active = false

    init(
        begin: @escaping () -> Void = { xpc_transaction_begin() },
        end: @escaping () -> Void = { xpc_transaction_end() }
    ) {
        self.begin = begin
        self.end = end
    }

    deinit {
        release()
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func acquire() {
        lock.lock()
        guard !active else {
            lock.unlock()
            return
        }
        active = true
        lock.unlock()
        begin()
    }

    func release() {
        lock.lock()
        guard active else {
            lock.unlock()
            return
        }
        active = false
        lock.unlock()
        end()
    }
}

/// Owns the app-side notification watching lifecycle: ensures the filter is
/// synced before watching starts, recovers automatically when the XPC helper
/// is interrupted/killed or macOS wakes from sleep, and retries with bounded
/// backoff when Notification Center or the helper is restarting.
@MainActor
final class NotificationWatchSupervisor {
    nonisolated static let defaultRetryDelays: [Duration] = [
        .milliseconds(500),
        .seconds(2),
        .seconds(5),
        .seconds(15)
    ]

    private(set) var isDesiredWatching = false

    private let disconnectDelay: Duration
    private let wakeDelay: Duration
    private let wakeCooldown: Duration
    private let retryDelays: [Duration]
    private let maxConsecutiveDisconnectRecoveries: Int
    private let isAuthorized: @MainActor @Sendable () async -> Bool
    private let syncFilter: @MainActor @Sendable () async -> Void
    private let startWatching: @MainActor @Sendable () async -> Bool
    private let stopWatching: @MainActor @Sendable () -> Void

    private var recoveryTask: Task<Void, Never>?
    private var consecutiveDisconnectFailures = 0
    private var lastSuccessfulStart: ContinuousClock.Instant?

    nonisolated init(
        disconnectDelay: Duration = .milliseconds(250),
        wakeDelay: Duration = .milliseconds(500),
        wakeCooldown: Duration = .seconds(3),
        retryDelays: [Duration] = NotificationWatchSupervisor.defaultRetryDelays,
        maxConsecutiveDisconnectRecoveries: Int = 5,
        isAuthorized: @escaping @MainActor @Sendable () async -> Bool,
        syncFilter: @escaping @MainActor @Sendable () async -> Void,
        startWatching: @escaping @MainActor @Sendable () async -> Bool,
        stopWatching: @escaping @MainActor @Sendable () -> Void
    ) {
        self.disconnectDelay = disconnectDelay
        self.wakeDelay = wakeDelay
        self.wakeCooldown = wakeCooldown
        self.retryDelays = retryDelays
        self.maxConsecutiveDisconnectRecoveries = maxConsecutiveDisconnectRecoveries
        self.isAuthorized = isAuthorized
        self.syncFilter = syncFilter
        self.startWatching = startWatching
        self.stopWatching = stopWatching
    }

    deinit {
        recoveryTask?.cancel()
    }

    func start() async {
        isDesiredWatching = true
        consecutiveDisconnectFailures = 0
        recoveryTask?.cancel()
        recoveryTask = nil

        let outcome = await attemptStartOnce()
        if outcome == .retryableFailure && isDesiredWatching {
            scheduleRecovery(initialDelay: .zero, fromDisconnect: false, skipImmediateAttempt: true)
        }
    }

    func stop() {
        isDesiredWatching = false
        consecutiveDisconnectFailures = 0
        lastSuccessfulStart = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        stopWatching()
    }

    func handleHelperDisconnected() {
        guard isDesiredWatching else { return }
        lastSuccessfulStart = nil
        guard consecutiveDisconnectFailures < maxConsecutiveDisconnectRecoveries else { return }
        consecutiveDisconnectFailures += 1
        scheduleRecovery(initialDelay: disconnectDelay, fromDisconnect: true, skipImmediateAttempt: false)
    }

    func handleSystemWake() {
        guard isDesiredWatching else { return }
        if wakeCooldown > .zero,
           let lastSuccessfulStart,
           lastSuccessfulStart.duration(to: .now) < wakeCooldown {
            return
        }
        consecutiveDisconnectFailures = 0
        scheduleRecovery(initialDelay: wakeDelay, fromDisconnect: false, skipImmediateAttempt: false)
    }

    private enum StartOutcome {
        case started
        case stoppedOrUnauthorized
        case retryableFailure
    }

    private func attemptStartOnce() async -> StartOutcome {
        guard isDesiredWatching else { return .stoppedOrUnauthorized }
        guard await isAuthorized() else { return .stoppedOrUnauthorized }
        guard isDesiredWatching else { return .stoppedOrUnauthorized }

        await syncFilter()
        guard isDesiredWatching else { return .stoppedOrUnauthorized }

        let started = await startWatching()
        if started {
            consecutiveDisconnectFailures = 0
            lastSuccessfulStart = .now
            return .started
        }
        return .retryableFailure
    }

    private func scheduleRecovery(
        initialDelay: Duration,
        fromDisconnect: Bool,
        skipImmediateAttempt: Bool
    ) {
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if initialDelay > .zero {
                try? await Task.sleep(for: initialDelay)
            }
            guard !Task.isCancelled, self.isDesiredWatching else { return }

            if !skipImmediateAttempt {
                let outcome = await self.attemptStartOnce()
                if outcome != .retryableFailure { return }
            }

            for delay in self.retryDelays {
                guard !Task.isCancelled, self.isDesiredWatching else { return }
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, self.isDesiredWatching else { return }

                let outcome = await self.attemptStartOnce()
                if outcome != .retryableFailure { return }
            }

            if fromDisconnect {
                self.consecutiveDisconnectFailures = max(self.consecutiveDisconnectFailures, 1)
            }
        }
    }
}
