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

    static func deltaUsage(
        from previous: CPUTicks,
        to current: CPUTicks,
        loadAverage1m: Double?,
        loadAverage5m: Double? = nil,
        loadAverage15m: Double? = nil
    ) -> CPUUsage {
        let dUser = current.user >= previous.user ? current.user - previous.user : 0
        let dNice = current.nice >= previous.nice ? current.nice - previous.nice : 0
        let dSystem = current.system >= previous.system ? current.system - previous.system : 0
        let dIdle = current.idle >= previous.idle ? current.idle - previous.idle : 0

        let total = dUser + dNice + dSystem + dIdle
        guard total > 0 else {
            return CPUUsage(
                userPercent: 0,
                systemPercent: 0,
                loadAverage1m: loadAverage1m,
                loadAverage5m: loadAverage5m,
                loadAverage15m: loadAverage15m
            )
        }

        let totalDouble = Double(total)
        let userPct = min(max(Double(dUser + dNice) / totalDouble * 100, 0), 100)
        let systemPct = min(max(Double(dSystem) / totalDouble * 100, 0), max(0, 100 - userPct))
        return CPUUsage(
            userPercent: userPct,
            systemPercent: systemPct,
            loadAverage1m: loadAverage1m,
            loadAverage5m: loadAverage5m,
            loadAverage15m: loadAverage15m
        )
    }
}

struct InterfaceByteCounters: Equatable, Sendable {
    let inBytes: UInt64
    let outBytes: UInt64
}

struct NetworkCounterSnapshot: Equatable, Sendable {
    let interfaces: [String: InterfaceByteCounters]
    let uptime: TimeInterval
    let localIPs: [String: String]

    init(
        interfaces: [String: InterfaceByteCounters],
        uptime: TimeInterval,
        localIPs: [String: String] = [:]
    ) {
        self.interfaces = interfaces
        self.uptime = uptime
        self.localIPs = localIPs
    }

    static func deltaUsage(
        from previous: NetworkCounterSnapshot,
        to current: NetworkCounterSnapshot
    ) -> NetworkUsage {
        let elapsed = current.uptime - previous.uptime
        guard elapsed > 0.05 else {
            let iface = current.primaryInterfaceName
            return NetworkUsage(
                downloadBytesPerSecond: 0,
                uploadBytesPerSecond: 0,
                activeInterface: iface,
                localIP: iface.flatMap { current.localIPs[$0] }
            )
        }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        var busiestInterface: String?
        var busiestDelta: UInt64 = 0

        for (name, now) in current.interfaces {
            guard let prev = previous.interfaces[name] else { continue }
            // Guard against counter resets / interface renegotiations instead of underflowing.
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

        let activeInterface = busiestInterface ?? current.primaryInterfaceName
        return NetworkUsage(
            downloadBytesPerSecond: Double(totalIn) / elapsed,
            uploadBytesPerSecond: Double(totalOut) / elapsed,
            activeInterface: activeInterface,
            localIP: activeInterface.flatMap { current.localIPs[$0] }
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
        let loads = Self.readLoadAverages()

        let cpu: CPUUsage
        let hasCPUDelta: Bool
        if let prev = previousCPU, let curr = cpuTicks {
            cpu = CPUTicks.deltaUsage(
                from: prev,
                to: curr,
                loadAverage1m: loads?.0,
                loadAverage5m: loads?.1,
                loadAverage15m: loads?.2
            )
            hasCPUDelta = true
        } else {
            cpu = CPUUsage(
                userPercent: 0,
                systemPercent: 0,
                loadAverage1m: loads?.0,
                loadAverage5m: loads?.1,
                loadAverage15m: loads?.2
            )
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
            let iface = netCounters?.primaryInterfaceName
            network = NetworkUsage(
                downloadBytesPerSecond: 0,
                uploadBytesPerSecond: 0,
                activeInterface: iface,
                localIP: iface.flatMap { netCounters?.localIPs[$0] }
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

    func sampleTopMemoryProcesses(limit: Int = 3) -> [TopProcessItem] {
        Self.readTopMemoryProcesses(limit: limit)
    }

    func sampleTopCPUProcesses(limit: Int = 3, sampleWindowSeconds: Double = 0.25) async -> [TopProcessItem] {
        let startUptime = ProcessInfo.processInfo.systemUptime
        let first = Self.readProcessCPUTimes()
        try? await Task.sleep(for: .seconds(sampleWindowSeconds))
        guard !Task.isCancelled else { return [] }
        let endUptime = ProcessInfo.processInfo.systemUptime
        let elapsedSeconds = endUptime - startUptime
        guard elapsedSeconds > 0.05 else { return [] }
        let second = Self.readProcessCPUTimes()

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let numer = Double(timebase.numer == 0 ? 1 : timebase.numer)
        let denom = Double(timebase.denom == 0 ? 1 : timebase.denom)
        let elapsedNs = elapsedSeconds * 1_000_000_000

        var results: [TopProcessItem] = []
        results.reserveCapacity(second.count)
        for (pid, after) in second {
            guard let before = first[pid], after.cpuTicks >= before.cpuTicks else { continue }
            let deltaTicks = after.cpuTicks - before.cpuTicks
            guard deltaTicks > 0 else { continue }
            let cpuNs = Double(deltaTicks) * numer / denom
            let cpuPct = (cpuNs / elapsedNs) * 100
            guard cpuPct >= 0.1 else { continue }
            let name = Self.processName(for: pid)
            results.append(
                TopProcessItem(
                    pid: pid,
                    name: name,
                    cpuPercent: cpuPct,
                    memoryBytes: after.memoryBytes
                )
            )
        }

        results.sort { $0.cpuPercent > $1.cpuPercent }
        return Array(results.prefix(max(1, limit)))
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

    static func readLoadAverages() -> (Double, Double, Double)? {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return nil }
        return (loads[0], loads[1], loads[2])
    }

    static func readLoadAverage1m() -> Double? {
        readLoadAverages()?.0
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
        let localIPs = readLocalIPv4Addresses()
        if let counters64 = readNetworkCounters64() {
            return NetworkCounterSnapshot(
                interfaces: counters64,
                uptime: uptime,
                localIPs: localIPs
            )
        }

        // Fallback to getifaddrs if NET_RT_IFLIST2 is unavailable.
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
            guard name.hasPrefix("en") else { continue }

            let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
            interfaces[name] = InterfaceByteCounters(
                inBytes: UInt64(data.ifi_ibytes),
                outBytes: UInt64(data.ifi_obytes)
            )
        }

        return NetworkCounterSnapshot(
            interfaces: interfaces,
            uptime: uptime,
            localIPs: localIPs
        )
    }

    /// Reads 64-bit interface byte counters (`if_data64`) via `NET_RT_IFLIST2`,
    /// avoiding the 32-bit 4 GiB wraparound of `getifaddrs` (`if_data`).
    private static func readNetworkCounters64() -> [String: InterfaceByteCounters]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length: Int = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else {
            return nil
        }

        var interfaces: [String: InterfaceByteCounters] = [:]
        var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))

        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            let headerSize = MemoryLayout<if_msghdr>.size
            let header2Size = MemoryLayout<if_msghdr2>.size

            while offset + headerSize <= length {
                let ifm = base.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let msgLen = Int(ifm.ifm_msglen)
                guard msgLen > 0, offset + msgLen <= length else { break }

                if Int32(ifm.ifm_type) == RTM_IFINFO2, msgLen >= header2Size {
                    let ifm2 = base.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    let flags = ifm2.ifm_flags
                    let isActive = (flags & IFF_UP) != 0
                        && (flags & IFF_RUNNING) != 0
                        && (flags & IFF_LOOPBACK) == 0
                    if isActive,
                       if_indextoname(UInt32(ifm2.ifm_index), &nameBuf) != nil {
                        let name = String(cString: nameBuf)
                        // Track physical Ethernet/Wi-Fi interfaces (`en*`) to avoid
                        // double-counting VPN tunnels (`utun*`) riding on top of them.
                        if name.hasPrefix("en") {
                            interfaces[name] = InterfaceByteCounters(
                                inBytes: ifm2.ifm_data.ifi_ibytes,
                                outBytes: ifm2.ifm_data.ifi_obytes
                            )
                        }
                    }
                }

                offset += msgLen
            }
        }

        return interfaces
    }

    private static func readLocalIPv4Addresses() -> [String: String] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [:] }
        defer { freeifaddrs(first) }

        var addresses: [String: String] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))

        while let ptr = cursor {
            let iface = ptr.pointee
            cursor = iface.ifa_next

            let flags = Int32(iface.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_RUNNING) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  let addr = iface.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            let name = String(cString: iface.ifa_name)
            guard name.hasPrefix("en"), addresses[name] == nil else { continue }

            var sinAddr = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            if inet_ntop(AF_INET, &sinAddr, &ipBuf, socklen_t(INET_ADDRSTRLEN)) != nil {
                addresses[name] = String(cString: ipBuf)
            }
        }

        return addresses
    }

    // MARK: - On-Demand Top Process Readers

    private struct ProcessSample {
        let cpuTicks: UInt64
        let memoryBytes: UInt64
    }

    private static func listAllPIDs() -> [pid_t] {
        let byteCount = proc_listallpids(nil, 0)
        guard byteCount > 0 else { return [] }
        let capacity = Int(byteCount) / MemoryLayout<pid_t>.stride + 32
        var pids = [pid_t](repeating: 0, count: capacity)
        let actualBytes = proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.stride))
        guard actualBytes > 0 else { return [] }
        let count = min(Int(actualBytes) / MemoryLayout<pid_t>.stride, pids.count)
        return pids[0..<count].filter { $0 > 0 }
    }

    private static func readProcessMemoryBytes(pid: pid_t, fallbackRSS: UInt64) -> UInt64 {
        var rusage = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &rusage) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rusagePtr in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rusagePtr) == 0
            }
        }
        if ok, rusage.ri_phys_footprint > 0 {
            return rusage.ri_phys_footprint
        }
        return fallbackRSS
    }

    private static func readProcessCPUTimes() -> [pid_t: ProcessSample] {
        let pids = listAllPIDs()
        var samples: [pid_t: ProcessSample] = [:]
        samples.reserveCapacity(pids.count)

        let expectedSize = Int32(MemoryLayout<proc_taskinfo>.size)
        for pid in pids {
            var info = proc_taskinfo()
            let size = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, expectedSize)
            guard size == expectedSize else { continue }
            let ticks = info.pti_total_user &+ info.pti_total_system
            samples[pid] = ProcessSample(cpuTicks: ticks, memoryBytes: info.pti_resident_size)
        }
        return samples
    }

    static func readTopMemoryProcesses(limit: Int = 3) -> [TopProcessItem] {
        let pids = listAllPIDs()
        let expectedSize = Int32(MemoryLayout<proc_taskinfo>.size)
        var candidates: [(pid: pid_t, bytes: UInt64)] = []
        candidates.reserveCapacity(pids.count)

        for pid in pids {
            var info = proc_taskinfo()
            let size = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, expectedSize)
            let rss = size == expectedSize ? info.pti_resident_size : 0
            let footprint = readProcessMemoryBytes(pid: pid, fallbackRSS: rss)
            guard footprint > 0 else { continue }
            candidates.append((pid, footprint))
        }

        candidates.sort { $0.bytes > $1.bytes }
        return candidates.prefix(max(1, limit)).map { entry in
            TopProcessItem(
                pid: entry.pid,
                name: processName(for: entry.pid),
                cpuPercent: 0,
                memoryBytes: entry.bytes
            )
        }
    }

    private static func processName(for pid: pid_t) -> String {
        var pathBuf = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 {
            let path = String(cString: pathBuf)
            let last = URL(fileURLWithPath: path).lastPathComponent
            if !last.isEmpty {
                return last
            }
        }
        var nameBuf = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0 {
            let name = String(cString: nameBuf)
            if !name.isEmpty {
                return name
            }
        }
        return "PID \(pid)"
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
