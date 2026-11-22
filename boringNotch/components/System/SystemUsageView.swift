//
//  SystemUsageView.swift
//  zzz.notch
//

import AppKit
import Defaults
import SwiftUI

struct SystemUsageView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var coordinator = BoringViewCoordinator.shared
    @ObservedObject private var monitor = SystemUsageMonitor.shared
    @Default(.systemShowSparkline) private var showSparkline
    @State private var consumerID = UUID()
    @State private var hoveringActivityMonitor = false

    private var isMonitoringActive: Bool {
        vm.notchState == .open && coordinator.currentView == .system
    }

    var body: some View {
        let snap = monitor.snapshot

        VStack(spacing: 6) {
            HStack(spacing: 8) {
                cpuCard(snap.cpu, hasDelta: snap.hasDeltaSample)
                memoryCard(snap.memory)
                networkCard(snap.network, hasDelta: snap.hasDeltaSample)
            }
            .frame(maxHeight: .infinity)

            footerStrip(disk: snap.disk, thermal: snap.thermal, battery: snap.battery)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: isMonitoringActive) {
            guard isMonitoringActive else { return }
            monitor.acquire(consumerID)
            defer { monitor.release(consumerID) }
            try? await Task.sleep(for: .seconds(86_400 * 365))
        }
    }

    // MARK: - CPU Card

    private func cpuCard(_ cpu: CPUUsage, hasDelta: Bool) -> some View {
        let total = cpu.totalPercent
        let accent = cpuColor(for: total)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                cardLabel("CPU")
                Spacer(minLength: 4)
                Text(hasDelta ? "\(Int(total.rounded()))%" : "—")
                    .font(.system(size: 16, weight: .bold).monospacedDigit())
                    .foregroundStyle(hasDelta ? accent : .secondary)
            }

            if showSparkline {
                CPUSparklineView(values: monitor.cpuHistory, color: accent)
                    .frame(minHeight: 16, maxHeight: 20)
            } else {
                Spacer(minLength: 0)
            }

            stackedCPUBar(userFraction: cpu.userFraction, systemFraction: cpu.systemFraction)

            HStack(spacing: 4) {
                Text("U \(Int(cpu.userPercent.rounded()))% · S \(Int(cpu.systemPercent.rounded()))%")
                    .lineLimit(1)
                Spacer(minLength: 2)
                if let load = cpu.loadAverage1m {
                    Text(String(format: "%.1f", load))
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func stackedCPUBar(userFraction: Double, systemFraction: Double) -> some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let userW = max(userFraction > 0 ? 2 : 0, w * userFraction)
            let sysW = max(systemFraction > 0 ? 2 : 0, w * systemFraction)

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                HStack(spacing: 0) {
                    if userW > 0 {
                        Rectangle()
                            .fill(.white.opacity(0.75))
                            .frame(width: min(userW, w))
                    }
                    if sysW > 0 {
                        Rectangle()
                            .fill(Color.orange.opacity(0.9))
                            .frame(width: min(sysW, max(0, w - userW)))
                    }
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 3.5)
    }

    private func cpuColor(for percent: Double) -> Color {
        if percent >= 90 { return .red }
        if percent >= 70 { return .yellow }
        return .white
    }

    // MARK: - Memory Card

    private func memoryCard(_ memory: MemoryUsage) -> some View {
        let barColor: Color = memory.pressure == .normal ? .white.opacity(0.65) : memory.pressure.color

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                cardLabel("MEMORY")
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    Circle()
                        .fill(memory.pressure.color)
                        .frame(width: 5, height: 5)
                    Text(memory.pressure.label)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(memory.pressure == .normal ? .secondary : memory.pressure.color)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(memory.pressure.color.opacity(0.14), in: Capsule())
            }

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(SystemUsageFormatter.memoryGB(memory.usedBytes))
                    .font(.system(size: 16, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                Text("/ \(SystemUsageFormatter.memoryGB(memory.totalBytes, decimals: 0)) GB")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(memory.usedFraction > 0 ? 4 : 0, proxy.size.width * memory.usedFraction))
                }
            }
            .frame(height: 3.5)

            Text(memoryBreakdownText(memory))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func memoryBreakdownText(_ memory: MemoryUsage) -> String {
        var parts = [
            "App \(SystemUsageFormatter.compactMemory(memory.appBytes))",
            "C \(SystemUsageFormatter.compactMemory(memory.compressedBytes))"
        ]
        if memory.swapUsedBytes >= 10 * 1_048_576 {
            parts.append("Sw \(SystemUsageFormatter.compactMemory(memory.swapUsedBytes))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Network Card

    private func networkCard(_ network: NetworkUsage, hasDelta: Bool) -> some View {
        let downActive = hasDelta && network.downloadBytesPerSecond >= 10
        let upActive = hasDelta && network.uploadBytesPerSecond >= 10

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                cardLabel("NETWORK")
                Spacer(minLength: 4)
                Text(network.activeInterface ?? "Idle")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(downActive ? Color.green : .secondary.opacity(0.5))
                        .frame(width: 11)
                    Text(hasDelta ? SystemUsageFormatter.speed(network.downloadBytesPerSecond) : "—")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(downActive ? .white : .secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 5) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(upActive ? Color.cyan : .secondary.opacity(0.5))
                        .frame(width: 11)
                    Text(hasDelta ? SystemUsageFormatter.speed(network.uploadBytesPerSecond) : "—")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(upActive ? .white : .secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Text(monitor.peakNetworkRate >= 10
                ? "Peak \(SystemUsageFormatter.speed(monitor.peakNetworkRate))"
                : "No traffic")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Footer Strip

    private func footerStrip(
        disk: DiskUsage?,
        thermal: SystemThermalState,
        battery: BatteryUsage?
    ) -> some View {
        HStack(spacing: 12) {
            if let disk {
                let diskColor: Color = disk.availableGB < 15 ? .red : (disk.availableGB < 30 ? .yellow : .secondary)
                HStack(spacing: 4) {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 10))
                        .foregroundStyle(diskColor)
                    Text("\(SystemUsageFormatter.diskFree(disk.availableBytes)) free")
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(diskColor == .secondary ? .secondary : diskColor)
                }
            }

            HStack(spacing: 4) {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 10))
                    .foregroundStyle(thermal.color)
                Text(thermal.label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(thermal.color)
            }

            if let battery {
                let batteryColor: Color = battery.isCharging ? .green : (battery.percentage <= 15 ? .red : .secondary)
                HStack(spacing: 4) {
                    Image(systemName: battery.symbolName)
                        .font(.system(size: 10.5))
                        .foregroundStyle(batteryColor)
                    Text(batteryLabel(battery))
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(battery.percentage <= 15 && !battery.isCharging ? .red : .secondary)
                }
            }

            Spacer(minLength: 4)

            Button(action: openActivityMonitor) {
                HStack(spacing: 3) {
                    Text("Activity Monitor")
                        .font(.system(size: 10.5, weight: .medium))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(hoveringActivityMonitor ? .white : .secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.white.opacity(hoveringActivityMonitor ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .onHover { hoveringActivityMonitor = $0 }
            .help("Open Activity Monitor")
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func batteryLabel(_ battery: BatteryUsage) -> String {
        if let mins = battery.minutesRemaining,
           let duration = SystemUsageFormatter.duration(minutes: mins) {
            return "\(battery.percentage)% · \(duration)"
        }
        return "\(battery.percentage)%"
    }

    private func cardLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
    }

    private func openActivityMonitor() {
        let appURL = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, _ in }
        vm.close()
    }
}

private struct CPUSparklineView: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height

            if values.count >= 2, w > 0, h > 0 {
                let count = values.count
                let step = w / CGFloat(max(count - 1, 1))

                let linePath = Path { path in
                    for (idx, val) in values.enumerated() {
                        let clamped = min(max(val, 0), 100)
                        let x = CGFloat(idx) * step
                        let y = h - (CGFloat(clamped) / 100) * (h - 2) - 1
                        if idx == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }

                let fillPath = Path { path in
                    path.addPath(linePath)
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.addLine(to: CGPoint(x: 0, y: h))
                    path.closeSubpath()
                }

                ZStack {
                    fillPath.fill(
                        LinearGradient(
                            colors: [color.opacity(0.22), color.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    linePath.stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                }
            } else {
                // Subtle baseline while waiting for the second point.
                Path { path in
                    path.move(to: CGPoint(x: 0, y: h - 1))
                    path.addLine(to: CGPoint(x: w, y: h - 1))
                }
                .stroke(.white.opacity(0.12), lineWidth: 1)
            }
        }
    }
}
