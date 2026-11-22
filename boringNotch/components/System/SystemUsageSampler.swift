//
//  SystemUsageSampler.swift
//  zzz.notch
//

import Darwin
import Foundation
import IOKit.ps

struct CPUTicks: Equatable, Sendable {
    let user: UInt64
    let nice: UInt64
    let system: UInt64
    let idle: UInt64

    static func deltaUsage(from previous: CPUTicks, to current: CPUTicks, loadAverage1m: Double?) -> CPUUsage {
        let dUser = current.user >= previous.user ? current.user - previous.user : 0
        let dNice = current.nice >= previous.nice ? current.nice - previous.nice : 0
        let dSystem = current.system >= previous.system ? current.system - previous.system : 0
        let dIdle = current.idle >= previous.idle ? current.idle - previous.idle : 0

        let total = dUser + dNice + dSystem + dIdle
        guard total > 0 else {
            return CPUUsage(userPercent: 0, systemPercent: 0, loadAverage1m: loadAverage1m)
        }

        let totalDouble = Double(total)
        let userPct = min(max(Double(dUser + dNice) / totalDouble * 100, 0), 100)
        let systemPct = min(max(Double(dSystem) / totalDouble * 100, 0), max(0, 100 - userPct))
        return CPUUsage(userPercent: userPct, systemPercent: systemPct, loadAverage1m: loadAverage1m)
    }
}

struct InterfaceByteCounters: Equatable, Sendable {
    let inBytes: UInt64
    let outBytes: UInt64
}

struct NetworkCounterSnapshot: Equatable, Sendable {
    let interfaces: [String: InterfaceByteCounters]
    let uptime: TimeInterval

    static func deltaUsage(
        from previous: NetworkCounterSnapshot,
        to current: NetworkCounterSnapshot
    ) -> NetworkUsage {
        let elapsed = current.uptime - previous.uptime
        guard elapsed > 0.05 else {
            return NetworkUsage(
                downloadBytesPerSecond: 0,
                uploadBytesPerSecond: 0,
                activeInterface: current.primaryInterfaceName
            )
        }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        var busiestInterface: String?
        var busiestDelta: UInt64 = 0

        for (name, now) in current.interfaces {
            guard let prev = previous.interfaces[name] else { continue }
            // if_data counters are UInt32 and wrap around every ~4 GiB; clamp
            // wraparounds or interface resets to 0 instead of reporting spikes.
            let dIn = now.inBytes >= prev.inBytes ? now.inBytes - prev.inBytes : 0
            let dOut = now.outBytes >= prev.outBytes ? now.outBytes - prev.outBytes : 0
            totalIn += dIn
            totalOut += dOut

            let combined = dIn + dOut
            if combined > busiestDelta {
                busiestDelta = combined
                busiestInterface = name
            }
        }

        return NetworkUsage(
            downloadBytesPerSecond: Double(totalIn) / elapsed,
            uploadBytesPerSecond: Double(totalOut) / elapsed,
            activeInterface: busiestInterface ?? current.primaryInterfaceName
        )
    }

    var primaryInterfaceName: String? {
        if interfaces["en0"] != nil { return "en0" }
        return interfaces.keys.sorted().first
    }
}

/// Pure Darwin/Mach/IOKit system sampler. Keeps only the previous CPU/network
/// baselines needed for delta calculation; owns no timers.
actor SystemUsageSampler {
    private var previousCPU: CPUTicks?
    private var previousNetwork: NetworkCounterSnapshot?
    private var cachedDisk: DiskUsage?
    private var lastDiskCheckUptime: TimeInterval = 0
    private let diskRefreshInterval: TimeInterval = 15

    func resetBaselines() {
        previousCPU = nil
        previousNetwork = nil
        lastDiskCheckUptime = 0
    }

    func sample() -> SystemUsageSnapshot {
        let nowUptime = ProcessInfo.processInfo.systemUptime
        let cpuTicks = Self.readCPUTicks()
        let loadAvg = Self.readLoadAverage1m()

        let cpu: CPUUsage
        let hasCPUDelta: Bool
        if let prev = previousCPU, let curr = cpuTicks {
            cpu = CPUTicks.deltaUsage(from: prev, to: curr, loadAverage1m: loadAvg)
            hasCPUDelta = true
        } else {
            cpu = CPUUsage(userPercent: 0, systemPercent: 0, loadAverage1m: loadAvg)
            hasCPUDelta = false
        }
        if let curr = cpuTicks {
            previousCPU = curr
        }

        let memory = Self.readMemoryUsage()

        let netCounters = Self.readNetworkCounters(uptime: nowUptime)
        let network: NetworkUsage
        let hasNetDelta: Bool
        if let prev = previousNetwork, let curr = netCounters {
            network = NetworkCounterSnapshot.deltaUsage(from: prev, to: curr)
            hasNetDelta = true
        } else {
            network = NetworkUsage(
                downloadBytesPerSecond: 0,
                uploadBytesPerSecond: 0,
                activeInterface: netCounters?.primaryInterfaceName
            )
            hasNetDelta = false
        }
        if let curr = netCounters {
            previousNetwork = curr
        }

        if cachedDisk == nil || (nowUptime - lastDiskCheckUptime) >= diskRefreshInterval {
            cachedDisk = Self.readDiskUsage()
            lastDiskCheckUptime = nowUptime
        }

        let thermal = SystemThermalState(ProcessInfo.processInfo.thermalState)
        let battery = Self.readBatteryUsage()

        return SystemUsageSnapshot(
            cpu: cpu,
            memory: memory,
            network: network,
            disk: cachedDisk,
            thermal: thermal,
            battery: battery,
            hasDeltaSample: hasCPUDelta || hasNetDelta
        )
    }

    // MARK: - Native Readers

    static func readCPUTicks() -> CPUTicks? {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0

        let kr = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUs,
            &cpuInfo,
            &numCPUInfo
        )
        guard kr == KERN_SUCCESS, let info = cpuInfo else { return nil }
        defer {
            let size = vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }

        var user: UInt64 = 0
        var nice: UInt64 = 0
        var system: UInt64 = 0
        var idle: UInt64 = 0

        let stride = Int(CPU_STATE_MAX)
        for cpu in 0..<Int(numCPUs) {
            let base = cpu * stride
            user += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            nice += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            system += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            idle += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
        }

        return CPUTicks(user: user, nice: nice, system: system, idle: idle)
    }

    static func readLoadAverage1m() -> Double? {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) > 0 else { return nil }
        return loads[0]
    }

    static func readMemoryUsage() -> MemoryUsage {
        let totalBytes = ProcessInfo.processInfo.physicalMemory

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = UInt64(pageSize > 0 ? pageSize : 4096)

        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }

        let appBytes: UInt64
        let wiredBytes: UInt64
        let compressedBytes: UInt64
        let usedBytes: UInt64

        if kr == KERN_SUCCESS {
            let internalPages = UInt64(vmStats.internal_page_count)
            let purgeablePages = UInt64(vmStats.purgeable_count)
            let appPages = internalPages >= purgeablePages ? (internalPages - purgeablePages) : 0
            appBytes = appPages * page
            wiredBytes = UInt64(vmStats.wire_count) * page
            compressedBytes = UInt64(vmStats.compressor_page_count) * page
            usedBytes = min(appBytes + wiredBytes + compressedBytes, totalBytes)
        } else {
            appBytes = 0
            wiredBytes = 0
            compressedBytes = 0
            usedBytes = 0
        }

        let swapUsedBytes = readSwapUsedBytes()
        let pressure = readMemoryPressure()

        return MemoryUsage(
            usedBytes: usedBytes,
            totalBytes: totalBytes,
            appBytes: appBytes,
            wiredBytes: wiredBytes,
            compressedBytes: compressedBytes,
            swapUsedBytes: swapUsedBytes,
            pressure: pressure
        )
    }

    static func readSwapUsedBytes() -> UInt64 {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 else { return 0 }
        return swap.xsu_used
    }

    static func readMemoryPressure() -> MemoryPressureLevel {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return .normal
        }
        return MemoryPressureLevel(rawLevel: level)
    }

    static func readNetworkCounters(uptime: TimeInterval) -> NetworkCounterSnapshot? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(first) }

        var interfaces: [String: InterfaceByteCounters] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first

        while let ptr = cursor {
            let iface = ptr.pointee
            cursor = iface.ifa_next

            let flags = Int32(iface.ifa_flags)
            let isActive = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0 && (flags & IFF_LOOPBACK) == 0
            guard isActive,
                  let addr = iface.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK),
                  let dataPtr = iface.ifa_data else {
                continue
            }

            let name = String(cString: iface.ifa_name)
            // Track physical Ethernet/Wi-Fi interfaces (`en*`) to avoid double-counting
            // VPN tunnels (`utun*`) that ride on top of them.
            guard name.hasPrefix("en") else { continue }

            let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
            interfaces[name] = InterfaceByteCounters(
                inBytes: UInt64(data.ifi_ibytes),
                outBytes: UInt64(data.ifi_obytes)
            )
        }

        return NetworkCounterSnapshot(interfaces: interfaces, uptime: uptime)
    }

    static func readDiskUsage() -> DiskUsage? {
        let rootURL = URL(fileURLWithPath: "/")
        guard let values = try? rootURL.resourceValues(
            forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey,
                .volumeTotalCapacityKey
            ]
        ) else {
            return nil
        }

        let important = values.volumeAvailableCapacityForImportantUsage ?? 0
        let regular = Int64(values.volumeAvailableCapacity ?? 0)
        let available = important > 0 ? important : regular
        guard available >= 0 else { return nil }
        let total = max(0, values.volumeTotalCapacity ?? 0)
        return DiskUsage(availableBytes: UInt64(available), totalBytes: UInt64(total))
    }

    static func readBatteryUsage() -> BatteryUsage? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }

        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let type = desc[kIOPSTypeKey] as? String,
                  type == kIOPSInternalBatteryType else {
                continue
            }

            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maxCap = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            let pct = maxCap > 0 ? min(max(Int((Double(current) / Double(maxCap) * 100).rounded()), 0), 100) : 0
            let isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let powerSource = desc[kIOPSPowerSourceStateKey] as? String
            let isPluggedIn = powerSource == kIOPSACPowerValue

            let rawMinutes: Int?
            if isCharging {
                rawMinutes = desc[kIOPSTimeToFullChargeKey] as? Int
            } else if !isPluggedIn {
                rawMinutes = desc[kIOPSTimeToEmptyKey] as? Int
            } else {
                rawMinutes = nil
            }
            let minutesRemaining = rawMinutes.flatMap { $0 > 0 ? $0 : nil }

            return BatteryUsage(
                percentage: pct,
                isCharging: isCharging,
                isPluggedIn: isPluggedIn,
                minutesRemaining: minutesRemaining
            )
        }

        return nil
    }
}
