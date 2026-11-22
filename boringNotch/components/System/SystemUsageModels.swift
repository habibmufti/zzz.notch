//
//  SystemUsageModels.swift
//  zzz.notch
//

import Foundation
import SwiftUI

enum MemoryPressureLevel: Int32, Equatable, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4

    init(rawLevel: Int32) {
        switch rawLevel {
        case 4...:
            self = .critical
        case 2...3:
            self = .warning
        default:
            self = .normal
        }
    }

    var label: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Warn"
        case .critical: "Crit"
        }
    }

    var color: Color {
        switch self {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
        }
    }
}

enum SystemThermalState: Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }

    var label: String {
        switch self {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        }
    }

    var color: Color {
        switch self {
        case .nominal: .secondary
        case .fair: .yellow
        case .serious: .orange
        case .critical: .red
        }
    }
}

struct CPUUsage: Equatable, Sendable {
    let userPercent: Double
    let systemPercent: Double
    let loadAverage1m: Double?

    var totalPercent: Double {
        min(max(userPercent + systemPercent, 0), 100)
    }

    var userFraction: Double {
        min(max(userPercent / 100, 0), 1)
    }

    var systemFraction: Double {
        min(max(systemPercent / 100, 0), max(0, 1 - userFraction))
    }

    static let zero = CPUUsage(userPercent: 0, systemPercent: 0, loadAverage1m: nil)
}

struct MemoryUsage: Equatable, Sendable {
    let usedBytes: UInt64
    let totalBytes: UInt64
    let appBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64
    let swapUsedBytes: UInt64
    let pressure: MemoryPressureLevel

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }

    static let zero = MemoryUsage(
        usedBytes: 0,
        totalBytes: 0,
        appBytes: 0,
        wiredBytes: 0,
        compressedBytes: 0,
        swapUsedBytes: 0,
        pressure: .normal
    )
}

struct NetworkUsage: Equatable, Sendable {
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double
    let activeInterface: String?

    var peakRate: Double {
        max(downloadBytesPerSecond, uploadBytesPerSecond)
    }

    static let zero = NetworkUsage(
        downloadBytesPerSecond: 0,
        uploadBytesPerSecond: 0,
        activeInterface: nil
    )
}

struct DiskUsage: Equatable, Sendable {
    let availableBytes: UInt64
    let totalBytes: UInt64

    var availableGB: Double {
        Double(availableBytes) / 1_000_000_000
    }
}

struct BatteryUsage: Equatable, Sendable {
    let percentage: Int
    let isCharging: Bool
    let isPluggedIn: Bool
    let minutesRemaining: Int?

    var symbolName: String {
        if isCharging {
            return "battery.100percent.bolt"
        }
        switch percentage {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

struct SystemUsageSnapshot: Equatable, Sendable {
    let cpu: CPUUsage
    let memory: MemoryUsage
    let network: NetworkUsage
    let disk: DiskUsage?
    let thermal: SystemThermalState
    let battery: BatteryUsage?
    let hasDeltaSample: Bool

    static let initial = SystemUsageSnapshot(
        cpu: .zero,
        memory: .zero,
        network: .zero,
        disk: nil,
        thermal: .nominal,
        battery: nil,
        hasDeltaSample: false
    )
}

enum SystemUsageFormatter {
    private static let gib: Double = 1_073_741_824
    private static let mib: Double = 1_048_576
    private static let kib: Double = 1_024
    private static let gbDecimal: Double = 1_000_000_000

    /// Formats RAM figures in binary GiB matching Activity Monitor (e.g. "16.2", "24").
    static func memoryGB(_ bytes: UInt64, decimals: Int = 1) -> String {
        let value = Double(bytes) / gib
        if decimals == 0 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.\(decimals)f", value)
    }

    /// Compact memory figure for secondary breakdown labels (e.g. "11.2G", "420M").
    static func compactMemory(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if value >= gib {
            let g = value / gib
            return g >= 10 ? String(format: "%.0fG", g) : String(format: "%.1fG", g)
        }
        let m = value / mib
        return String(format: "%.0fM", m)
    }

    /// Formats disk free space in decimal GB/TB matching macOS Finder / Storage settings.
    static func diskFree(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / gbDecimal
        if gb >= 1_000 {
            return String(format: "%.1f TB", gb / 1_000)
        }
        if gb >= 100 {
            return String(format: "%.0f GB", gb)
        }
        return String(format: "%.1f GB", gb)
    }

    /// Formats network throughput (e.g. "0 B/s", "512 KB/s", "12.4 MB/s").
    static func speed(_ bytesPerSecond: Double) -> String {
        let rate = max(0, bytesPerSecond)
        if rate < 10 {
            return "0 B/s"
        }
        if rate < kib {
            return String(format: "%.0f B/s", rate)
        }
        if rate < mib {
            let kb = rate / kib
            return kb >= 100 ? String(format: "%.0f KB/s", kb) : String(format: "%.1f KB/s", kb)
        }
        if rate < gib {
            let mb = rate / mib
            return mb >= 100 ? String(format: "%.0f MB/s", mb) : String(format: "%.1f MB/s", mb)
        }
        return String(format: "%.2f GB/s", rate / gib)
    }

    static func duration(minutes: Int) -> String? {
        guard minutes > 0, minutes < 60 * 48 else { return nil }
        let hours = minutes / 60
        let mins = minutes % 60
        if hours > 0 {
            return "\(hours)h \(mins)m"
        }
        return "\(mins)m"
    }
}
