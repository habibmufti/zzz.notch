//
//  SystemUsageMonitor.swift
//  zzz.notch
//

import Defaults
import Foundation

/// Lazy, consumer-counted system telemetry monitor.
/// Sampling runs strictly while at least one visible SystemUsageView holds an
/// active lease; idle cost when the notch is closed or on another tab is zero.
@MainActor
final class SystemUsageMonitor: ObservableObject {
    static let shared = SystemUsageMonitor()

    @Published private(set) var snapshot: SystemUsageSnapshot = .initial
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var networkHistory: [NetworkSamplePoint] = []
    @Published private(set) var peakNetworkRate: Double = 0
    @Published private(set) var topCPUProcesses: [TopProcessItem] = []
    @Published private(set) var topMemoryProcesses: [TopProcessItem] = []
    @Published private(set) var isLoadingTopProcesses = false

    private let sampler: SystemUsageSampler
    private let historyLimit: Int
    private let resetCooldownSeconds: Double
    private let warmUpDelaySeconds: Double
    private let intervalProvider: @MainActor () -> TimeInterval

    private var activeConsumers: Set<UUID> = []
    private var pollingTask: Task<Void, Never>?
    private var cooldownResetTask: Task<Void, Never>?
    private var topProcessTask: Task<Void, Never>?

    var isPolling: Bool { pollingTask != nil }
    var activeConsumerCount: Int { activeConsumers.count }
    var historyCapacity: Int { historyLimit }

    init(
        sampler: SystemUsageSampler = SystemUsageSampler(),
        historyLimit: Int = 30,
        warmUpDelaySeconds: Double = 0.25,
        resetCooldownSeconds: Double = 10,
        intervalProvider: @escaping @MainActor () -> TimeInterval = {
            min(max(Defaults[.systemRefreshInterval], 0.5), 10)
        }
    ) {
        self.sampler = sampler
        self.historyLimit = historyLimit
        self.warmUpDelaySeconds = warmUpDelaySeconds
        self.resetCooldownSeconds = resetCooldownSeconds
        self.intervalProvider = intervalProvider
    }

    func acquire(_ consumerID: UUID) {
        cooldownResetTask?.cancel()
        cooldownResetTask = nil

        let wasEmpty = activeConsumers.isEmpty
        activeConsumers.insert(consumerID)
        if wasEmpty {
            startPolling()
        }
    }

    func release(_ consumerID: UUID) {
        activeConsumers.remove(consumerID)
        guard activeConsumers.isEmpty else { return }
        stopPolling()
    }

    private func startPolling() {
        pollingTask?.cancel()
        let sampler = self.sampler
        let warmUp = self.warmUpDelaySeconds

        pollingTask = Task { [weak self] in
            // Always start from a fresh CPU/Network baseline so a quick reopen
            // reports live activity (via the 250ms warm-up) instead of averaging
            // over the time the notch was closed.
            await sampler.resetBaselines()
            guard !Task.isCancelled else { return }

            // 1. Immediate snapshot: shows Memory, Disk, Thermal, Battery at t = 0
            //    and establishes CPU/Network baselines.
            let initial = await sampler.sample()
            guard !Task.isCancelled, let self else { return }
            self.apply(initial)

            // 2. Fast warm-up delta so CPU % & Network rate appear within ~250ms
            //    instead of waiting a full refresh interval.
            try? await Task.sleep(for: .seconds(warmUp))
            guard !Task.isCancelled else { return }
            let warmed = await sampler.sample()
            guard !Task.isCancelled else { return }
            self.apply(warmed)

            // 3. Steady-state polling while any consumer remains active.
            while !Task.isCancelled {
                let interval = self.intervalProvider()
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                let next = await sampler.sample()
                guard !Task.isCancelled else { return }
                self.apply(next)
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        topProcessTask?.cancel()
        topProcessTask = nil
        isLoadingTopProcesses = false

        let cooldown = self.resetCooldownSeconds
        cooldownResetTask?.cancel()
        cooldownResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(cooldown))
            guard !Task.isCancelled, let self, self.activeConsumers.isEmpty else { return }
            self.snapshot = .initial
            self.cpuHistory.removeAll()
            self.networkHistory.removeAll()
            self.peakNetworkRate = 0
            self.topCPUProcesses.removeAll()
            self.topMemoryProcesses.removeAll()
        }
    }

    /// One-shot, on-demand snapshot of the top 3 CPU or Memory processes.
    /// Never runs on a timer so background/idle cost stays strictly zero.
    func refreshTopProcesses(for kind: SystemProcessKind) {
        topProcessTask?.cancel()
        isLoadingTopProcesses = true
        let sampler = self.sampler

        topProcessTask = Task { [weak self] in
            let items: [TopProcessItem]
            switch kind {
            case .cpu:
                items = await sampler.sampleTopCPUProcesses(limit: 3)
            case .memory:
                items = await sampler.sampleTopMemoryProcesses(limit: 3)
            }
            guard !Task.isCancelled, let self else { return }
            switch kind {
            case .cpu:
                self.topCPUProcesses = items
            case .memory:
                self.topMemoryProcesses = items
            }
            self.isLoadingTopProcesses = false
        }
    }

    private func apply(_ next: SystemUsageSnapshot) {
        if !next.hasDeltaSample && snapshot.hasDeltaSample {
            // Quick reopen within cooldown: refresh instant metrics immediately
            // while holding previous CPU/Network readouts for 250ms to avoid a
            // "—" flicker before the warm-up sample arrives.
            snapshot = SystemUsageSnapshot(
                cpu: snapshot.cpu,
                memory: next.memory,
                network: snapshot.network,
                disk: next.disk,
                thermal: next.thermal,
                battery: next.battery,
                hasDeltaSample: true
            )
            return
        }

        snapshot = next
        guard next.hasDeltaSample else { return }

        cpuHistory.append(next.cpu.totalPercent)
        if cpuHistory.count > historyLimit {
            cpuHistory.removeFirst(cpuHistory.count - historyLimit)
        }
        networkHistory.append(
            NetworkSamplePoint(
                downloadBytesPerSecond: next.network.downloadBytesPerSecond,
                uploadBytesPerSecond: next.network.uploadBytesPerSecond
            )
        )
        if networkHistory.count > historyLimit {
            networkHistory.removeFirst(networkHistory.count - historyLimit)
        }
        peakNetworkRate = max(peakNetworkRate, next.network.peakRate)
    }
}
