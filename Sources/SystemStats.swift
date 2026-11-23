import Foundation
#if os(macOS)
import Darwin
#endif

/// Tools → Sistem kartı için anlık değerler. Yalnızca Tools sekmesi görünürken örneklenir.
struct SystemStatsSnapshot: Equatable {
    var cpuPercent: Double?
    var memUsed: UInt64 = 0
    var memTotal: UInt64 = 0
    /// kern.memorystatus_vm_pressure_level: 1 normal, 2 uyarı, 4 kritik (0 = bilinmiyor)
    var pressure: Int = 0
    var diskFree: Int64?
    var diskTotal: Int64?
    var netIn: Double?
    var netOut: Double?

    var diskFreeFraction: Double? {
        guard let f = diskFree, let t = diskTotal, t > 0 else { return nil }
        return Double(f) / Double(t)
    }
}

enum StatsFormat {
    static func bytes(_ v: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var x = v
        var i = 0
        while x >= 1000 && i < units.count - 1 { x /= 1000; i += 1 }
        if i == 0 { return "\(Int(x)) B" }
        return String(format: x >= 100 ? "%.0f %@" : "%.1f %@", x, units[i])
    }

    static func rate(_ bytesPerSecond: Double?) -> String {
        guard let r = bytesPerSecond else { return "—" }
        return bytes(r) + "/s"
    }

    static func pressureText(_ level: Int) -> String {
        switch level {
        case 1: return "Normal"
        case 2: return "Uyarı"
        case 4: return "Kritik"
        default: return "—"
        }
    }

    /// 32 bit sayaçlar (if_data) taşınca farkı düzelt.
    static func counterDelta(old: UInt64, new: UInt64, width: UInt64 = 1 << 32) -> UInt64 {
        new >= old ? new - old : (width - old) + new
    }
}

/// CPU / bellek / disk / ağ örnekleyicisi. Tek bir seri kuyrukta kullanılmalı.
final class SystemStatsSampler {
    private var lastCPU: [UInt64]?
    private var lastNet: [String: (UInt64, UInt64)] = [:]
    private var lastNetTime: Date?
    private var lastDisk: (Date, Int64?, Int64?)?

    func sample(now: Date = Date()) -> SystemStatsSnapshot {
        var s = SystemStatsSnapshot()
        s.memTotal = ProcessInfo.processInfo.physicalMemory
        #if os(macOS)
        s.cpuPercent = cpu()
        s.memUsed = memoryUsed()
        s.pressure = pressureLevel()
        let net = network(now: now)
        s.netIn = net.0
        s.netOut = net.1
        #endif
        // Disk değeri yavaş değişir: 30 sn önbellek.
        if let d = lastDisk, now.timeIntervalSince(d.0) < 30 {
            s.diskFree = d.1
            s.diskTotal = d.2
        } else {
            let d = Self.disk()
            s.diskFree = d.0
            s.diskTotal = d.1
            lastDisk = (now, d.0, d.1)
        }
        return s
    }

    static func disk(path: String = "/") -> (Int64?, Int64?) {
        let url = URL(fileURLWithPath: path)
        #if os(macOS)
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        let free: Int64? = v?.volumeAvailableCapacityForImportantUsage
        let total: Int64? = v?.volumeTotalCapacity.map { Int64($0) }
        return (free, total)
        #else
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
        return (v?.volumeAvailableCapacity.map { Int64($0) }, v?.volumeTotalCapacity.map { Int64($0) })
        #endif
    }

    #if os(macOS)
    private func cpu() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        let ticks: [UInt64] = [UInt64(t.0), UInt64(t.1), UInt64(t.2), UInt64(t.3)]  // user, system, idle, nice
        defer { lastCPU = ticks }
        guard let old = lastCPU else { return nil }
        let d = zip(ticks, old).map { StatsFormat.counterDelta(old: $1, new: $0) }
        let total = d.reduce(0, +)
        guard total > 0 else { return nil }
        let busy = d[0] + d[1] + d[3]
        return Double(busy) / Double(total) * 100
    }

    private func memoryUsed() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let page = UInt64(vm_kernel_page_size)
        // Etkinlik Monitörü "Kullanılan bellek" ≈ uygulama (internal − purgeable) + kablolu + sıkıştırılmış
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = internalPages > purgeable ? internalPages - purgeable : 0
        return (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    }

    private func pressureLevel() -> Int {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return 0 }
        return Int(level)
    }

    private func network(now: Date) -> (Double?, Double?) {
        var current: [String: (UInt64, UInt64)] = [:]
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return (nil, nil) }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let ifa = cur.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = ifa.ifa_data {
                let name = String(cString: ifa.ifa_name)
                let flags = Int32(ifa.ifa_flags)
                if (flags & IFF_LOOPBACK) == 0 && (flags & IFF_UP) != 0 {
                    let d = data.assumingMemoryBound(to: if_data.self).pointee
                    current[name] = (UInt64(d.ifi_ibytes), UInt64(d.ifi_obytes))
                }
            }
            p = ifa.ifa_next
        }
        defer { lastNet = current; lastNetTime = now }
        guard let t0 = lastNetTime else { return (nil, nil) }
        let dt = now.timeIntervalSince(t0)
        guard dt > 0.2 else { return (nil, nil) }
        var inSum: UInt64 = 0, outSum: UInt64 = 0
        for (name, v) in current {
            guard let old = lastNet[name] else { continue }
            inSum += StatsFormat.counterDelta(old: old.0, new: v.0)
            outSum += StatsFormat.counterDelta(old: old.1, new: v.1)
        }
        return (Double(inSum) / dt, Double(outSum) / dt)
    }
    #endif
}
