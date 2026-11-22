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
    @State private var inspectedCard: SystemProcessKind?
    @State private var hoveringCPU = false
    @State private var hoveringMemory = false
    @State private var hoveringNetwork = false
    @State private var hoveringDisk = false
    @State private var hoveringBattery = false
    @State private var hoveringActivityMonitor = false
    @State private var copiedIP = false
    @State private var copyFeedbackTask: Task<Void, Never>?

    private var isMonitoringActive: Bool {
        vm.notchState == .open && coordinator.currentView == .system
    }

    var body: some View {
        let snap = monitor.snapshot

        VStack(spacing: 6) {
            HStack(spacing: 8) {
                if inspectedCard == .cpu {
                    topProcessesCard(
                        title: "TOP CPU",
                        kind: .cpu,
                        items: monitor.topCPUProcesses
                    )
                } else {
                    cpuCard(snap.cpu, hasDelta: snap.hasDeltaSample)
                }

                if inspectedCard == .memory {
                    topProcessesCard(
                        title: "TOP MEMORY",
                        kind: .memory,
                        items: monitor.topMemoryProcesses
                    )
                } else {
                    memoryCard(snap.memory)
                }

                networkCard(snap.network, hasDelta: snap.hasDeltaSample)
            }
            .frame(maxHeight: .infinity)

            footerStrip(disk: snap.disk, thermal: snap.thermal, battery: snap.battery)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: isMonitoringActive) {
            guard isMonitoringActive else {
                inspectedCard = nil
                return
            }
            monitor.acquire(consumerID)
            defer { monitor.release(consumerID) }
            try? await Task.sleep(for: .seconds(86_400 * 365))
        }
        .onDisappear {
            copyFeedbackTask?.cancel()
            copyFeedbackTask = nil
            inspectedCard = nil
        }
    }

    // MARK: - CPU Card

    private func cpuCard(_ cpu: CPUUsage, hasDelta: Bool) -> some View {
        let total = cpu.displayTotalPercent
        let accent = cpuColor(for: Double(total))

        return Button {
            toggleInspect(.cpu)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    cardLabel("CPU")
                    Spacer(minLength: 4)
                    Text(hasDelta ? "\(total)%" : "—")
                        .font(.system(size: 16, weight: .bold).monospacedDigit())
                        .foregroundStyle(hasDelta ? accent : .secondary)
                }

                if showSparkline {
                    CPUSparklineView(
                        values: monitor.cpuHistory,
                        capacity: monitor.historyCapacity,
                        color: accent
                    )
                    .frame(minHeight: 16, maxHeight: 20)
                } else {
                    Spacer(minLength: 0)
                }

                stackedCPUBar(userFraction: cpu.userFraction, systemFraction: cpu.systemFraction)

                HStack(spacing: 4) {
                    Text("U \(cpu.displayUserPercent)% · S \(cpu.displaySystemPercent)%")
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if let load = cpu.loadAverage1m {
                        Text(String(format: "L %.1f", load))
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .minimumScaleFactor(0.85)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.white.opacity(hoveringCPU ? 0.095 : 0.06), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hoveringCPU = $0 }
        .help(cpuTooltip(cpu))
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

    private func cpuTooltip(_ cpu: CPUUsage) -> String {
        var parts = ["CPU: \(cpu.displayTotalPercent)% (User \(cpu.displayUserPercent)%, System \(cpu.displaySystemPercent)%)"]
        if let l1 = cpu.loadAverage1m {
            if let l5 = cpu.loadAverage5m, let l15 = cpu.loadAverage15m {
                parts.append(String(format: "Load avg: %.2f / %.2f / %.2f (%d cores)", l1, l5, l15, cpu.coreCount))
            } else {
                parts.append(String(format: "Load 1m: %.2f (%d cores)", l1, cpu.coreCount))
            }
        }
        parts.append("Click to inspect top CPU processes")
        return parts.joined(separator: " · ")
    }

    // MARK: - Memory Card

    private func memoryCard(_ memory: MemoryUsage) -> some View {
        let appColor: Color = memory.pressure == .normal ? .white.opacity(0.72) : memory.pressure.color

        return Button {
            toggleInspect(.memory)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
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

                stackedMemoryBar(memory, appColor: appColor)

                memoryBreakdownRow(memory)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.white.opacity(hoveringMemory ? 0.095 : 0.06), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hoveringMemory = $0 }
        .help(memoryTooltip(memory))
    }

    private func stackedMemoryBar(_ memory: MemoryUsage, appColor: Color) -> some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let appW = max(memory.appFraction > 0 ? 2 : 0, w * memory.appFraction)
            let wiredW = max(memory.wiredFraction > 0 ? 2 : 0, w * memory.wiredFraction)
            let compW = max(memory.compressedFraction > 0 ? 2 : 0, w * memory.compressedFraction)

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                HStack(spacing: 0) {
                    if appW > 0 {
                        Rectangle()
                            .fill(appColor)
                            .frame(width: min(appW, w))
                    }
                    if wiredW > 0 {
                        Rectangle()
                            .fill(Color.orange.opacity(0.8))
                            .frame(width: min(wiredW, max(0, w - appW)))
                    }
                    if compW > 0 {
                        Rectangle()
                            .fill(Color.cyan.opacity(0.75))
                            .frame(width: min(compW, max(0, w - appW - wiredW)))
                    }
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 3.5)
    }

    private func memoryBreakdownRow(_ memory: MemoryUsage) -> some View {
        let hasSwap = memory.swapUsedBytes >= 10 * 1_048_576
        return HStack(spacing: 3) {
            Text("App \(SystemUsageFormatter.compactMemory(memory.appBytes))")
            if !hasSwap {
                Text("· W \(SystemUsageFormatter.compactMemory(memory.wiredBytes))")
            }
            Text("· C \(SystemUsageFormatter.compactMemory(memory.compressedBytes))")
            if hasSwap {
                Text("·")
                Text("Sw \(SystemUsageFormatter.compactMemory(memory.swapUsedBytes))")
                    .foregroundStyle(memory.isSwapElevated ? Color.yellow : .secondary)
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private func memoryTooltip(_ memory: MemoryUsage) -> String {
        let parts = [
            "App \(SystemUsageFormatter.memoryGB(memory.appBytes)) GB",
            "Wired \(SystemUsageFormatter.memoryGB(memory.wiredBytes)) GB",
            "Compressed \(SystemUsageFormatter.memoryGB(memory.compressedBytes)) GB",
            "Swap \(SystemUsageFormatter.memoryGB(memory.swapUsedBytes)) GB",
            "Click to inspect top memory processes"
        ]
        return parts.joined(separator: " · ")
    }

    // MARK: - On-Demand Top Processes Card

    private func topProcessesCard(
        title: String,
        kind: SystemProcessKind,
        items: [TopProcessItem]
    ) -> some View {
        let maxValue: Double = {
            switch kind {
            case .cpu: return max(items.first?.cpuPercent ?? 100, 1)
            case .memory: return max(Double(items.first?.memoryBytes ?? 1), 1)
            }
        }()

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                cardLabel(title)
                Spacer(minLength: 4)
                Button {
                    monitor.refreshTopProcesses(for: kind)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Refresh snapshot")

                Button {
                    inspectedCard = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Back to summary")
            }

            if monitor.isLoadingTopProcesses && items.isEmpty {
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Sampling…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                Spacer(minLength: 0)
            } else if items.isEmpty {
                Spacer(minLength: 0)
                Text("No active processes")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer(minLength: 0)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(items) { item in
                        let value = kind == .cpu ? item.cpuPercent : Double(item.memoryBytes)
                        let share = min(max(value / maxValue, 0.08), 1)
                        let metricText = kind == .cpu
                            ? String(format: "%.0f%%", item.cpuPercent)
                            : SystemUsageFormatter.compactMemory(item.memoryBytes)
                        let tint: Color = kind == .cpu ? .orange : .cyan

                        ZStack(alignment: .leading) {
                            GeometryReader { proxy in
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(tint.opacity(0.14))
                                    .frame(width: proxy.size.width * share)
                            }
                            HStack(spacing: 4) {
                                Text(item.name)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.92))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 4)
                                Text(metricText)
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                        }
                        .frame(height: 18)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func toggleInspect(_ kind: SystemProcessKind) {
        if inspectedCard == kind {
            inspectedCard = nil
        } else {
            inspectedCard = kind
            monitor.refreshTopProcesses(for: kind)
        }
    }

    // MARK: - Network Card

    private func networkCard(_ network: NetworkUsage, hasDelta: Bool) -> some View {
        let downActive = hasDelta && network.downloadBytesPerSecond >= 10
        let upActive = hasDelta && network.uploadBytesPerSecond >= 10

        return Button {
            copyLocalIP(network.localIP)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    cardLabel("NETWORK")
                    Spacer(minLength: 4)
                    Text(copiedIP ? "Copied IP" : (network.activeInterface ?? "Idle"))
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(copiedIP ? Color.green : .secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            (copiedIP ? Color.green.opacity(0.16) : .white.opacity(0.08)),
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(downActive ? Color.green : .secondary.opacity(0.5))
                            .frame(width: 11)
                        Text(hasDelta ? SystemUsageFormatter.speed(network.downloadBytesPerSecond) : "—")
                            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(downActive ? .white : .secondary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(upActive ? Color.cyan : .secondary.opacity(0.5))
                            .frame(width: 11)
                        Text(hasDelta ? SystemUsageFormatter.speed(network.uploadBytesPerSecond) : "—")
                            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(upActive ? .white : .secondary)
                            .lineLimit(1)
                    }
                }

                if showSparkline {
                    NetworkSparklineView(
                        samples: monitor.networkHistory,
                        capacity: monitor.historyCapacity
                    )
                    .frame(minHeight: 12, maxHeight: 15)
                } else {
                    Spacer(minLength: 0)
                }

                Text(monitor.peakNetworkRate >= 10
                    ? "Peak \(SystemUsageFormatter.speed(monitor.peakNetworkRate))"
                    : "No traffic")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                .white.opacity(hoveringNetwork && network.localIP != nil ? 0.095 : 0.06),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hoveringNetwork = $0 }
        .help(networkTooltip(network))
    }

    private func networkTooltip(_ network: NetworkUsage) -> String {
        var parts: [String] = []
        if let iface = network.activeInterface {
            parts.append("Interface: \(iface)")
        }
        if let ip = network.localIP {
            parts.append("Local IP: \(ip) (click to copy)")
        }
        if monitor.peakNetworkRate >= 10 {
            parts.append("Session peak: \(SystemUsageFormatter.speed(monitor.peakNetworkRate))")
        }
        return parts.isEmpty ? "Network throughput" : parts.joined(separator: " · ")
    }

    private func copyLocalIP(_ ip: String?) {
        guard let ip, !ip.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ip, forType: .string)
        copiedIP = true
        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copiedIP = false
        }
    }

    // MARK: - Footer Strip

    private func footerStrip(
        disk: DiskUsage?,
        thermal: SystemThermalState,
        battery: BatteryUsage?
    ) -> some View {
        HStack(spacing: 10) {
            if let disk {
                let diskColor: Color = disk.availableGB < 15 ? .red : (disk.availableGB < 30 ? .yellow : .secondary)
                Button(action: openStorageSettings) {
                    HStack(spacing: 4) {
                        Image(systemName: "internaldrive")
                            .font(.system(size: 10))
                            .foregroundStyle(diskColor)
                        Text("\(SystemUsageFormatter.diskFree(disk.availableBytes)) free")
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(diskColor == .secondary ? (hoveringDisk ? .white : .secondary) : diskColor)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.white.opacity(hoveringDisk ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .onHover { hoveringDisk = $0 }
                .help(diskTooltip(disk))
            }

            HStack(spacing: 4) {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 10))
                    .foregroundStyle(thermal.color)
                Text(thermal.label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(thermal.color)
            }
            .help("System thermal state: \(thermal.label)")

            if let battery {
                let batteryColor: Color = battery.isCharging
                    ? .green
                    : (battery.percentage <= 15 && !battery.isPluggedIn ? .red : .secondary)
                Button(action: openBatterySettings) {
                    HStack(spacing: 4) {
                        Image(systemName: battery.symbolName)
                            .font(.system(size: 10.5))
                            .foregroundStyle(batteryColor)
                        Text(batteryLabel(battery))
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(
                                battery.percentage <= 15 && !battery.isCharging && !battery.isPluggedIn
                                    ? .red
                                    : (hoveringBattery ? .white : .secondary)
                            )
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.white.opacity(hoveringBattery ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .onHover { hoveringBattery = $0 }
                .help(batteryTooltip(battery))
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

    private func diskTooltip(_ disk: DiskUsage) -> String {
        "\(SystemUsageFormatter.diskFree(disk.availableBytes)) free of \(SystemUsageFormatter.diskFree(disk.totalBytes)) · Click to open Storage Settings"
    }

    private func batteryLabel(_ battery: BatteryUsage) -> String {
        if let mins = battery.minutesRemaining,
           let duration = SystemUsageFormatter.duration(minutes: mins) {
            return battery.isCharging
                ? "\(battery.percentage)% · \(duration)↑"
                : "\(battery.percentage)% · \(duration)"
        }
        return "\(battery.percentage)%"
    }

    private func batteryTooltip(_ battery: BatteryUsage) -> String {
        let status: String
        if battery.isCharging {
            if let mins = battery.minutesRemaining, let duration = SystemUsageFormatter.duration(minutes: mins) {
                status = "Charging (\(duration) to full)"
            } else {
                status = "Charging"
            }
        } else if battery.isPluggedIn {
            status = "Plugged in (not charging)"
        } else if let mins = battery.minutesRemaining, let duration = SystemUsageFormatter.duration(minutes: mins) {
            status = "On battery (\(duration) remaining)"
        } else {
            status = "On battery"
        }
        return "\(battery.percentage)% · \(status) · Click to open Battery Settings"
    }

    private func cardLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
    }

    private func openStorageSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") {
            NSWorkspace.shared.open(url)
            vm.close()
        }
    }

    private func openBatterySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
            NSWorkspace.shared.open(url)
            vm.close()
        }
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
    let capacity: Int
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height

            if values.count >= 2, w > 0, h > 0 {
                let slots = max(capacity, values.count, 2)
                let step = w / CGFloat(slots - 1)
                let startSlot = slots - values.count
                // Auto-scale Y with a 25% ceiling floor so typical 5–20% dev
                // loads remain readable instead of hugging the bottom edge.
                let ceiling = min(100, max(25, (values.max() ?? 0) * 1.2))
                let firstX = CGFloat(startSlot) * step

                let linePath = Path { path in
                    for (idx, val) in values.enumerated() {
                        let clamped = min(max(val, 0), ceiling)
                        let x = CGFloat(startSlot + idx) * step
                        let y = h - (CGFloat(clamped / ceiling)) * (h - 2) - 1
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
                    path.addLine(to: CGPoint(x: firstX, y: h))
                    path.closeSubpath()
                }

                ZStack {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: h - 1))
                        path.addLine(to: CGPoint(x: w, y: h - 1))
                    }
                    .stroke(.white.opacity(0.08), lineWidth: 1)

                    fillPath.fill(
                        LinearGradient(
                            colors: [color.opacity(0.24), color.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    linePath.stroke(
                        color.opacity(0.88),
                        style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round)
                    )
                }
            } else {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: h - 1))
                    path.addLine(to: CGPoint(x: w, y: h - 1))
                }
                .stroke(.white.opacity(0.12), lineWidth: 1)
            }
        }
    }
}

private struct NetworkSparklineView: View {
    let samples: [NetworkSamplePoint]
    let capacity: Int

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height

            if samples.count >= 2, w > 0, h > 0 {
                let slots = max(capacity, samples.count, 2)
                let step = w / CGFloat(slots - 1)
                let startSlot = slots - samples.count
                let maxSample = samples.reduce(0.0) { acc, item in
                    max(acc, max(item.downloadBytesPerSecond, item.uploadBytesPerSecond))
                }
                let ceiling = max(1_024, maxSample * 1.15)

                let downPath = sparklinePath(
                    values: samples.map(\.downloadBytesPerSecond),
                    startSlot: startSlot,
                    step: step,
                    ceiling: ceiling,
                    height: h
                )
                let upPath = sparklinePath(
                    values: samples.map(\.uploadBytesPerSecond),
                    startSlot: startSlot,
                    step: step,
                    ceiling: ceiling,
                    height: h
                )

                ZStack {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: h - 1))
                        path.addLine(to: CGPoint(x: w, y: h - 1))
                    }
                    .stroke(.white.opacity(0.08), lineWidth: 1)

                    upPath.stroke(
                        Color.cyan.opacity(0.65),
                        style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
                    )
                    downPath.stroke(
                        Color.green.opacity(0.85),
                        style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
                    )
                }
            } else {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: h - 1))
                    path.addLine(to: CGPoint(x: w, y: h - 1))
                }
                .stroke(.white.opacity(0.1), lineWidth: 1)
            }
        }
    }

    private func sparklinePath(
        values: [Double],
        startSlot: Int,
        step: CGFloat,
        ceiling: Double,
        height: CGFloat
    ) -> Path {
        Path { path in
            for (idx, val) in values.enumerated() {
                let clamped = min(max(val, 0), ceiling)
                let x = CGFloat(startSlot + idx) * step
                let y = height - CGFloat(clamped / ceiling) * (height - 2) - 1
                if idx == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
        }
    }
}
