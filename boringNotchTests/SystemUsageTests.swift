//
//  SystemUsageTests.swift
//  zzz.notch
//

import XCTest
@testable import boringNotch

final class SystemUsageTests: XCTestCase {
    func testCPUDeltaCalculatesUserSystemAndClamps() {
        let prev = CPUTicks(user: 100, nice: 10, system: 50, idle: 840)
        let curr = CPUTicks(user: 130, nice: 15, system: 65, idle: 890)
        // Deltas: user+nice = 35, system = 15, idle = 50 -> total = 100
        let usage = CPUTicks.deltaUsage(from: prev, to: curr, loadAverage1m: 2.35)

        XCTAssertEqual(usage.userPercent, 35, accuracy: 0.01)
        XCTAssertEqual(usage.systemPercent, 15, accuracy: 0.01)
        XCTAssertEqual(usage.totalPercent, 50, accuracy: 0.01)
        XCTAssertEqual(usage.loadAverage1m, 2.35)
    }

    func testCPUDeltaHandlesZeroDeltaAndCounterReset() {
        let same = CPUTicks(user: 500, nice: 0, system: 200, idle: 1000)
        let zero = CPUTicks.deltaUsage(from: same, to: same, loadAverage1m: nil)
        XCTAssertEqual(zero.totalPercent, 0)

        let lower = CPUTicks(user: 10, nice: 0, system: 5, idle: 20)
        let reset = CPUTicks.deltaUsage(from: same, to: lower, loadAverage1m: nil)
        XCTAssertEqual(reset.totalPercent, 0)
    }

    func testNetworkDeltaAndWraparoundGuard() {
        let prev = NetworkCounterSnapshot(
            interfaces: [
                "en0": InterfaceByteCounters(inBytes: 1_000, outBytes: 2_000),
                "en1": InterfaceByteCounters(inBytes: 4_000_000_000, outBytes: 500)
            ],
            uptime: 100.0
        )
        let curr = NetworkCounterSnapshot(
            interfaces: [
                "en0": InterfaceByteCounters(inBytes: 2_098_152, outBytes: 526_288),
                // en1 wrapped around (inBytes < prev.inBytes) — must clamp to 0 instead of underflowing
                "en1": InterfaceByteCounters(inBytes: 100, outBytes: 500)
            ],
            uptime: 102.0
        )

        let usage = NetworkCounterSnapshot.deltaUsage(from: prev, to: curr)
        XCTAssertEqual(usage.downloadBytesPerSecond, Double(2_098_152 - 1_000) / 2.0, accuracy: 0.1)
        XCTAssertEqual(usage.uploadBytesPerSecond, Double(526_288 - 2_000) / 2.0, accuracy: 0.1)
        XCTAssertEqual(usage.activeInterface, "en0")
    }

    func testNetworkDeltaIgnoresTinyElapsedInterval() {
        let prev = NetworkCounterSnapshot(
            interfaces: ["en0": InterfaceByteCounters(inBytes: 100, outBytes: 100)],
            uptime: 50.0
        )
        let curr = NetworkCounterSnapshot(
            interfaces: ["en0": InterfaceByteCounters(inBytes: 10_000, outBytes: 10_000)],
            uptime: 50.01
        )
        let usage = NetworkCounterSnapshot.deltaUsage(from: prev, to: curr)
        XCTAssertEqual(usage.downloadBytesPerSecond, 0)
        XCTAssertEqual(usage.uploadBytesPerSecond, 0)
        XCTAssertEqual(usage.activeInterface, "en0")
    }

    func testMemoryPressureRawLevelMapping() {
        XCTAssertEqual(MemoryPressureLevel(rawLevel: 1), .normal)
        XCTAssertEqual(MemoryPressureLevel(rawLevel: 2), .warning)
        XCTAssertEqual(MemoryPressureLevel(rawLevel: 3), .warning)
        XCTAssertEqual(MemoryPressureLevel(rawLevel: 4), .critical)
        XCTAssertEqual(MemoryPressureLevel(rawLevel: 8), .critical)
        XCTAssertEqual(MemoryPressureLevel(rawLevel: 0), .normal)
    }

    func testFormattingHelpers() {
        XCTAssertEqual(SystemUsageFormatter.speed(0), "0 B/s")
        XCTAssertEqual(SystemUsageFormatter.speed(5), "0 B/s")
        XCTAssertEqual(SystemUsageFormatter.speed(512), "512 B/s")
        XCTAssertEqual(SystemUsageFormatter.speed(15 * 1024), "15.0 KB/s")
        XCTAssertEqual(SystemUsageFormatter.speed(512 * 1024), "512 KB/s")
        XCTAssertEqual(SystemUsageFormatter.speed(12.4 * 1_048_576), "12.4 MB/s")
        XCTAssertEqual(SystemUsageFormatter.memoryGB(16 * 1_073_741_824, decimals: 0), "16")
        XCTAssertEqual(SystemUsageFormatter.compactMemory(512 * 1_048_576), "512M")
        XCTAssertEqual(SystemUsageFormatter.compactMemory(3_221_225_472), "3.0G")
        XCTAssertEqual(SystemUsageFormatter.diskFree(142_000_000_000), "142 GB")
        XCTAssertEqual(SystemUsageFormatter.diskFree(24_500_000_000), "24.5 GB")
        XCTAssertEqual(SystemUsageFormatter.duration(minutes: 200), "3h 20m")
        XCTAssertEqual(SystemUsageFormatter.duration(minutes: 45), "45m")
        XCTAssertNil(SystemUsageFormatter.duration(minutes: 0))
    }

    @MainActor
    func testMonitorConsumerRefCountingStartsAndStopsLazily() {
        let monitor = SystemUsageMonitor(
            warmUpDelaySeconds: 10,
            resetCooldownSeconds: 10,
            intervalProvider: { 10 }
        )
        let first = UUID()
        let second = UUID()

        XCTAssertFalse(monitor.isPolling)
        monitor.acquire(first)
        XCTAssertTrue(monitor.isPolling)
        XCTAssertEqual(monitor.activeConsumerCount, 1)

        monitor.acquire(second)
        XCTAssertEqual(monitor.activeConsumerCount, 2)

        monitor.release(first)
        XCTAssertTrue(monitor.isPolling)
        XCTAssertEqual(monitor.activeConsumerCount, 1)

        monitor.release(second)
        XCTAssertFalse(monitor.isPolling)
        XCTAssertEqual(monitor.activeConsumerCount, 0)
    }

    func testLiveSamplerProducesValidHostReadings() async throws {
        let sampler = SystemUsageSampler()
        let first = await sampler.sample()
        XCTAssertGreaterThan(first.memory.totalBytes, 0)
        XCTAssertGreaterThan(first.memory.usedBytes, 0)
        XCTAssertLessThanOrEqual(first.memory.usedBytes, first.memory.totalBytes)
        let disk = try XCTUnwrap(first.disk)
        XCTAssertGreaterThan(disk.totalBytes, 0)
        XCTAssertGreaterThan(disk.availableBytes, 0)
        XCTAssertFalse(first.hasDeltaSample)

        let second = await sampler.sample()
        XCTAssertTrue(second.hasDeltaSample)
        XCTAssertGreaterThanOrEqual(second.cpu.totalPercent, 0)
        XCTAssertLessThanOrEqual(second.cpu.totalPercent, 100)
    }

    func testCPUDisplayPercentagesStayConsistentWhenRounding() {
        // Previously 7.6 + 3.6 = 11.2 rounded to 11% while showing U 8% · S 4%.
        let cpu = CPUUsage(userPercent: 7.6, systemPercent: 3.6, loadAverage1m: 2.4)
        XCTAssertEqual(cpu.displayUserPercent, 8)
        XCTAssertEqual(cpu.displaySystemPercent, 4)
        XCTAssertEqual(cpu.displayTotalPercent, cpu.displayUserPercent + cpu.displaySystemPercent)
    }

    func testMemoryStackedFractionsAndElevatedSwapDetection() {
        let gib: UInt64 = 1_073_741_824
        let memory = MemoryUsage(
            usedBytes: 12 * gib,
            totalBytes: 16 * gib,
            appBytes: 5 * gib,
            wiredBytes: 3 * gib,
            compressedBytes: 4 * gib,
            swapUsedBytes: 8 * gib,
            pressure: .normal
        )

        XCTAssertEqual(memory.appFraction, 5.0 / 16.0, accuracy: 0.001)
        XCTAssertEqual(memory.wiredFraction, 3.0 / 16.0, accuracy: 0.001)
        XCTAssertEqual(memory.compressedFraction, 4.0 / 16.0, accuracy: 0.001)
        XCTAssertTrue(memory.isSwapElevated)

        let lowSwap = MemoryUsage(
            usedBytes: 8 * gib,
            totalBytes: 16 * gib,
            appBytes: 5 * gib,
            wiredBytes: 2 * gib,
            compressedBytes: 1 * gib,
            swapUsedBytes: 512 * 1_048_576,
            pressure: .normal
        )
        XCTAssertFalse(lowSwap.isSwapElevated)
    }

    func testNetworkDeltaSupports64BitCountersAndLocalIP() {
        let prev = NetworkCounterSnapshot(
            interfaces: ["en0": InterfaceByteCounters(inBytes: 5_000_000_000, outBytes: 1_000_000_000)],
            uptime: 100.0,
            localIPs: ["en0": "192.168.1.42"]
        )
        let curr = NetworkCounterSnapshot(
            interfaces: ["en0": InterfaceByteCounters(inBytes: 5_002_000_000, outBytes: 1_000_500_000)],
            uptime: 102.0,
            localIPs: ["en0": "192.168.1.42"]
        )
        let usage = NetworkCounterSnapshot.deltaUsage(from: prev, to: curr)
        XCTAssertEqual(usage.downloadBytesPerSecond, 1_000_000, accuracy: 0.1)
        XCTAssertEqual(usage.uploadBytesPerSecond, 250_000, accuracy: 0.1)
        XCTAssertEqual(usage.localIP, "192.168.1.42")
    }

    func testBatterySymbolDistinguishesPluggedInNotCharging() {
        let pluggedHolding = BatteryUsage(percentage: 80, isCharging: false, isPluggedIn: true, minutesRemaining: nil)
        XCTAssertEqual(pluggedHolding.symbolName, "powerplug.fill")

        let charging = BatteryUsage(percentage: 80, isCharging: true, isPluggedIn: true, minutesRemaining: 30)
        XCTAssertEqual(charging.symbolName, "battery.100percent.bolt")

        let discharging = BatteryUsage(percentage: 53, isCharging: false, isPluggedIn: false, minutesRemaining: 252)
        XCTAssertEqual(discharging.symbolName, "battery.50percent")
    }

    func testOnDemandTopMemoryProcessesReturnsNonEmptyResults() async {
        let sampler = SystemUsageSampler()
        let top = await sampler.sampleTopMemoryProcesses(limit: 3)
        XCTAssertFalse(top.isEmpty)
        XCTAssertLessThanOrEqual(top.count, 3)
        XCTAssertTrue(top.allSatisfy { !$0.name.isEmpty && $0.memoryBytes > 0 })
    }
}
