import Foundation
#if os(macOS)
import Darwin
import IOKit
#endif

// Tools › Kaynaklar: bellek baskısı, bellek dökümü, CPU/GPU, uygulamaya göre gruplanmış tüketiciler ve
// "boştakileri kapat" adayları. Saf kurallar (gruplama, boşta kararı) Linux'ta da derlenir ve test edilir.

// MARK: - Gruplama (saf)

enum ProcessGrouping {
    enum Kind: String, Equatable { case app, simulator, agent, system, other }

    struct Group: Equatable {
        var key: String
        var title: String
        var kind: Kind
    }

    static let simulatorTitle = "iOS Simülatörü"

    /// Süreci ait olduğu uygulamaya bağlar: yardımcı süreçler (ör. "Google Chrome Helper (Renderer)") en dıştaki
    /// .app paketine, simülatör süreçleri "iOS Simülatörü"ne, Claude/Cursor/Codex CLI ajanları kendi adına toplanır.
    /// - Parameters:
    ///   - name: süreç adı (proc_name)
    ///   - path: çalıştırılabilir dosyanın tam yolu (proc_pidpath; boş olabilir)
    ///   - args: (yalnızca node/bun/python gibi yorumlayıcılar için) argv; ajan betiğini tanımak için
    static func classify(name: String, path: String, args: [String] = []) -> Group {
        let lowerPath = path.lowercased()
        let lowerName = name.lowercased()
        // 1) Simülatör (CoreSimulator çalışma zamanı, launchd_sim, Simulator.app)
        if lowerName == "launchd_sim" || lowerPath.contains("coresimulator") || lowerPath.contains("/simulator.app/")
            || lowerPath.contains("iphonesimulator.platform") || lowerPath.contains("/simruntime/") || lowerName == "simulator" {
            return Group(key: "sim", title: simulatorTitle, kind: .simulator)
        }
        // 2) CLI ajanları (yorumlayıcının argümanları dahil)
        let joined = ([lowerName, lowerPath] + args.prefix(4).map { $0.lowercased() }).joined(separator: " ")
        if !lowerPath.contains(".app/") {
            if joined.contains("claude-code") || lowerName == "claude" || lowerName.hasPrefix("claude.") || lowerPath.hasSuffix("/claude") || joined.contains("/.claude/local/") {
                return Group(key: "agent.claude", title: "Claude Code", kind: .agent)
            }
            if joined.contains("cursor-agent") { return Group(key: "agent.cursor", title: "Cursor Agent", kind: .agent) }
            if joined.contains("codex") { return Group(key: "agent.codex", title: "Codex", kind: .agent) }
            if joined.contains("gemini-cli") || lowerName == "gemini" { return Group(key: "agent.gemini", title: "Gemini CLI", kind: .agent) }
        }
        // 3) Uygulama paketi: en dıştaki ".app"
        if let app = outermostApp(path) {
            if app == "Simulator" { return Group(key: "sim", title: simulatorTitle, kind: .simulator) }
            let system = path.hasPrefix("/System/") || path.hasPrefix("/Library/Apple/")
            return Group(key: "app." + app, title: app, kind: system ? .system : .app)
        }
        // 4) Yorumlayıcılar / araçlar (ajan değilse)
        if ["node", "bun", "deno"].contains(lowerName) { return Group(key: "agent.node", title: "Node.js", kind: .agent) }
        // 5) macOS bileşenleri
        if isSystemPath(path) || path.isEmpty && ["kernel_task", "launchd", "windowserver"].contains(lowerName) {
            return Group(key: "system", title: "macOS", kind: .system)
        }
        return Group(key: "proc." + name, title: name, kind: .other)
    }

    static func isSystemPath(_ path: String) -> Bool {
        for p in ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/bin/", "/usr/bin/", "/Library/Apple/"] where path.hasPrefix(p) {
            return true
        }
        return false
    }

    /// "/Applications/Google Chrome.app/Contents/Frameworks/…/Google Chrome Helper.app/…" → "Google Chrome"
    static func outermostApp(_ path: String) -> String? {
        for comp in path.split(separator: "/") where comp.hasSuffix(".app") {
            return String(comp.dropLast(4))
        }
        return nil
    }
}

// MARK: - Anlık görüntü

struct AppUsage: Equatable, Identifiable {
    var id: String { key }
    var key: String
    var title: String
    var kind: ProcessGrouping.Kind
    var footprint: UInt64
    var cpuPercent: Double
    var processCount: Int
}

struct MemoryBreakdown: Equatable {
    var total: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    /// Dosya önbelleği + boşaltılabilir: gerektiğinde hemen geri alınır.
    var cached: UInt64 = 0
    var swapUsed: UInt64 = 0
    var used: UInt64 { app + wired + compressed }
}

struct ResourceSnapshot: Equatable {
    /// kern.memorystatus_vm_pressure_level: 1 normal, 2 uyarı, 4 kritik (0 = bilinmiyor)
    var pressure: Int = 0
    var memory = MemoryBreakdown()
    var cpuPercent: Double?
    var gpuPercent: Double?
    var top: [AppUsage] = []
}

/// "Boştakileri kapat" adayı.
struct IdleItem: Equatable, Identifiable {
    enum Kind: String, Equatable { case simulators, agent, docker }
    var id: String
    var kind: Kind
    var title: String
    var detail: String
    var footprint: UInt64
    /// agent: kapatılacak süreçler (pid, başlangıç zamanı) — yeniden kullanılan pid'e dokunmamak için
    var pids: [ProcessRef] = []
}

struct ProcessRef: Equatable {
    var pid: Int32
    var start: UInt64
}

// MARK: - Boşta kararı (saf)

enum IdlePolicy {
    static var idleMinutes: Int {
        let v = UserDefaults.standard.integer(forKey: "idleMinutes")
        return v > 0 ? v : 15
    }

    /// CPU süresi örneklerinden (zaman, toplam CPU sn) son `minutes` dakikada boşta mı?
    /// Yeterince eski örnek yoksa (süreç yeni ya da izleme yeni başladı) false.
    static func isIdle(history: [(Date, Double)], now: Date, minutes: Int, maxAverageCPU: Double = 0.5) -> Bool {
        guard let last = history.last else { return false }
        let window = Double(minutes) * 60
        guard let base = history.last(where: { now.timeIntervalSince($0.0) >= window }) else { return false }
        let wall = last.0.timeIntervalSince(base.0)
        guard wall > 0 else { return false }
        let cpu = max(0, last.1 - base.1)
        return cpu / wall * 100 <= maxAverageCPU
    }

    /// Bellek baskısı bildirimi: yalnızca seviye yükselince (normal → uyarı → kritik).
    static func shouldNotify(level: Int, previous: Int) -> Bool { level >= 2 && level > previous }
}

// MARK: - Örnekleyici (macOS)

/// Tek bir seri kuyrukta kullanılmalı. Panel kapalıyken yalnızca `pressureOnly` (sysctl) + ajan CPU geçmişi.
final class ResourceSampler {
    private var lastCPUTicks: [UInt64]?
    private var lastProcCPU: [Int32: (UInt64, Double)] = [:]   // pid → (başlangıç, CPU sn)
    private var lastSampleTime: Date?
    private var pathCache: [Int32: (UInt64, String, [String])] = [:]   // pid → (başlangıç, yol, argv)
    /// Ajan adayı süreçlerin CPU geçmişi (boşta kararı için).
    private(set) var agentHistory: [Int32: [(Date, Double)]] = [:]
    private var agentStart: [Int32: UInt64] = [:]

    init() {}

    static func pressureLevel() -> Int {
        #if os(macOS)
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return 0 }
        return Int(level)
        #else
        return 0
        #endif
    }

    /// full: panel açık (2 sn'de bir) — tüm süreçler gruplanır. Değilse yalnızca ajan geçmişi tutulur.
    func sample(full: Bool, now: Date = Date()) -> ResourceSnapshot {
        var s = ResourceSnapshot()
        s.pressure = Self.pressureLevel()
        #if os(macOS)
        let procs = processes(now: now, full: full)
        if full {
            s.memory = memory()
            s.cpuPercent = cpu()
            s.gpuPercent = Self.gpuUtilization()
            s.top = procs
        }
        #endif
        lastSampleTime = now
        return s
    }

    #if os(macOS)
    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    struct ProcInfo {
        var pid: Int32
        var ppid: Int32
        var uid: UInt32
        var start: UInt64
        var hasTTY: Bool
        var name: String
        var path: String
        var args: [String]
        var footprint: UInt64
        var cpuSeconds: Double
        var group: ProcessGrouping.Group
    }

    private(set) var lastProcs: [Int32: ProcInfo] = [:]

    static func listPIDs() -> [Int32] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard got > 0 else { return [] }
        return Array(pids.prefix(Int(got))).filter { $0 > 0 }
    }

    static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    /// Denetim terminali var mı (NODEV = -1).
    static func hasTTY(_ b: proc_bsdinfo) -> Bool {
        let d = Int64(truncatingIfNeeded: b.e_tdev)
        return d != 0 && d != -1 && d != 0xFFFF_FFFF
    }

    static func path(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : ""
    }

    static func cwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let p = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return p.isEmpty ? nil : p
    }

    /// argv (KERN_PROCARGS2); yalnızca yorumlayıcılar için çağrılır.
    static func args(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }        // exec yolu
        while i < size && buf[i] == 0 { i += 1 }        // dolgu
        var out: [String] = []
        while i < size && out.count < Int(argc) && out.count < 6 {
            var j = i
            while j < size && buf[j] != 0 { j += 1 }
            out.append(String(decoding: buf[i..<j], as: UTF8.self))
            i = j + 1
        }
        return out
    }

    private func processes(now: Date, full: Bool) -> [AppUsage] {
        let me = getuid()
        var procs: [Int32: ProcInfo] = [:]
        var newCPU: [Int32: (UInt64, Double)] = [:]
        var newPaths: [Int32: (UInt64, String, [String])] = [:]
        let dt = lastSampleTime.map { now.timeIntervalSince($0) } ?? 0
        var groups: [String: AppUsage] = [:]
        for pid in Self.listPIDs() {
            guard let bsd = Self.bsdInfo(pid) else { continue }
            let start = UInt64(bsd.pbi_start_tvsec) * 1_000_000 + UInt64(bsd.pbi_start_tvusec)
            let name = withUnsafePointer(to: bsd.pbi_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
            }
            let interp = ["node", "bun", "deno", "python3", "python"].contains(name.lowercased())
            // Panel kapalıyken yalnızca kendi ajan adaylarımız (yorumlayıcılar + bilinen ajan adları).
            if !full && !(bsd.pbi_uid == me && (interp || ["claude", "claude.exe", "cursor-agent", "codex", "gemini"].contains(name.lowercased()))) {
                continue
            }
            var ri = rusage_info_v2()
            let rr = withUnsafeMutablePointer(to: &ri) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard rr == 0 else { continue }   // başka kullanıcının süreci (root) — okunamaz
            let cpuSec = Double(ri.ri_user_time + ri.ri_system_time) * Self.timebase / 1e9
            let path: String, args: [String]
            if let c = pathCache[pid], c.0 == start { path = c.1; args = c.2 } else {
                path = Self.path(pid)
                args = interp ? Self.args(pid) : []
            }
            newPaths[pid] = (start, path, args)
            let g = ProcessGrouping.classify(name: name, path: path, args: args)
            var pcpu = 0.0
            if let old = lastProcCPU[pid], old.0 == start, dt > 0.2 { pcpu = max(0, cpuSec - old.1) / dt * 100 }
            newCPU[pid] = (start, cpuSec)
            let info = ProcInfo(pid: pid, ppid: Int32(bitPattern: bsd.pbi_ppid), uid: bsd.pbi_uid, start: start,
                                hasTTY: Self.hasTTY(bsd), name: name, path: path, args: args,
                                footprint: ri.ri_phys_footprint, cpuSeconds: cpuSec, group: g)
            procs[pid] = info
            if g.kind == .agent && bsd.pbi_uid == me {
                var h = agentHistory[pid] ?? []
                if agentStart[pid] != start { h = [] }
                agentStart[pid] = start
                h.append((now, cpuSec))
                let keep = Double(IdlePolicy.idleMinutes + 5) * 60
                h.removeAll { now.timeIntervalSince($0.0) > keep }
                // Panel açıkken 2 sn'de bir örnek gelir: geçmişi seyrelt (dakikada ~1 örnek yeter).
                if h.count >= 3, h[h.count - 2].0.timeIntervalSince(h[h.count - 3].0) < 50 { h.remove(at: h.count - 2) }
                agentHistory[pid] = h
            }
            if full {
                var u = groups[g.key] ?? AppUsage(key: g.key, title: g.title, kind: g.kind, footprint: 0, cpuPercent: 0, processCount: 0)
                u.footprint += ri.ri_phys_footprint
                u.cpuPercent += pcpu
                u.processCount += 1
                groups[g.key] = u
            }
        }
        // Bitmiş süreçlerin geçmişi atılır.
        for pid in agentHistory.keys where procs[pid] == nil { agentHistory[pid] = nil; agentStart[pid] = nil }
        if full {
            lastProcCPU = newCPU
            pathCache = newPaths
        } else {
            for (k, v) in newCPU { lastProcCPU[k] = v }
            for (k, v) in newPaths { pathCache[k] = v }
        }
        lastProcs = procs
        return groups.values.sorted { $0.footprint > $1.footprint }.prefix(8).map { $0 }
    }

    private func memory() -> MemoryBreakdown {
        var m = MemoryBreakdown()
        m.total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let internalPages = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            m.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
            m.wired = UInt64(stats.wire_count) * page
            m.compressed = UInt64(stats.compressor_page_count) * page
            m.cached = (UInt64(stats.external_page_count) + purgeable) * page
        }
        var sw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &sw, &size, nil, 0) == 0 { m.swapUsed = sw.xsu_used }
        return m
    }

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
        let ticks: [UInt64] = [UInt64(t.0), UInt64(t.1), UInt64(t.2), UInt64(t.3)]
        defer { lastCPUTicks = ticks }
        guard let old = lastCPUTicks else { return nil }
        let d = zip(ticks, old).map { StatsFormat.counterDelta(old: $1, new: $0) }
        let total = d.reduce(0, +)
        guard total > 0 else { return nil }
        return Double(d[0] + d[1] + d[3]) / Double(total) * 100
    }

    /// IOAccelerator › PerformanceStatistics › "Device Utilization %" (yetki gerekmez).
    static func gpuUtilization() -> Double? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var best: Double?
        while case let s = IOIteratorNext(it), s != 0 {
            defer { IOObjectRelease(s) }
            guard let cf = IORegistryEntryCreateCFProperty(s, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            if let v = (cf["Device Utilization %"] as? NSNumber)?.doubleValue { best = max(best ?? 0, v) }
        }
        return best
    }

    // MARK: Boştakiler

    /// Boştaki ağır öğeler: açık simülatörler, terminale bağlı olmayan ve N dk'dır boşta duran CLI ajanları,
    /// Docker Desktop. `frontmostPID`: öndeki uygulama (asla listelenmez). `activeProject`: cwd → etkin proje mi.
    func idleItems(now: Date = Date(), frontmostPID: Int32?, frontmostBundle: String?, dockerRunning: Bool,
                   bootedSimulators: [String], activeProject: (String) -> Bool) -> [IdleItem] {
        var items: [IdleItem] = []
        let procs = lastProcs
        let me = getuid()
        let minutes = IdlePolicy.idleMinutes
        // Simülatörler
        if !bootedSimulators.isEmpty && frontmostBundle != "com.apple.iphonesimulator" {
            let mem = procs.values.filter { $0.group.kind == .simulator }.reduce(UInt64(0)) { $0 + $1.footprint }
            items.append(IdleItem(id: "sim", kind: .simulators, title: ProcessGrouping.simulatorTitle,
                                  detail: bootedSimulators.joined(separator: ", "), footprint: mem))
        }
        // CLI ajanları: gruba göre
        func attachedToUserSession(_ p: ProcInfo) -> Bool {
            var cur: ProcInfo? = p
            var hops = 0
            while let c = cur, c.pid > 1, hops < 32 {
                if c.hasTTY { return true }                         // bir terminale bağlı
                if c.pid != p.pid && c.path.contains(".app/") { return true }   // bir uygulamanın (IDE) alt süreci
                cur = procs[c.ppid] ?? Self.bsdInfo(c.ppid).map { b in
                    ProcInfo(pid: c.ppid, ppid: Int32(bitPattern: b.pbi_ppid), uid: b.pbi_uid, start: 0, hasTTY: Self.hasTTY(b),
                             name: "", path: Self.path(c.ppid), args: [], footprint: 0, cpuSeconds: 0,
                             group: ProcessGrouping.Group(key: "", title: "", kind: .other))
                }
                hops += 1
            }
            return false
        }
        var byGroup: [String: IdleItem] = [:]
        for p in procs.values where p.group.kind == .agent && p.uid == me && p.pid != frontmostPID {
            guard !attachedToUserSession(p) else { continue }
            guard IdlePolicy.isIdle(history: agentHistory[p.pid] ?? [], now: now, minutes: minutes) else { continue }
            if let dir = Self.cwd(p.pid), activeProject(dir) { continue }
            var it = byGroup[p.group.key] ?? IdleItem(id: p.group.key, kind: .agent, title: p.group.title, detail: "", footprint: 0)
            it.footprint += p.footprint
            it.pids.append(ProcessRef(pid: p.pid, start: p.start))
            byGroup[p.group.key] = it
        }
        for var it in byGroup.values.sorted(by: { $0.footprint > $1.footprint }) {
            it.detail = L("%@ süreç · %@ dk'dır boşta, terminale bağlı değil", it.pids.count, minutes)
            items.append(it)
        }
        // Docker Desktop
        if dockerRunning && frontmostBundle != "com.docker.docker" {
            let mem = procs.values.filter { $0.group.key == "app.Docker" }.reduce(UInt64(0)) { $0 + $1.footprint }
            items.append(IdleItem(id: "docker", kind: .docker, title: "Docker Desktop", detail: L("Uygulama düzgünce kapatılır"), footprint: mem))
        }
        return items
    }

    /// Bir süreç hâlâ aynı süreç mi (pid yeniden kullanılmadı mı)?
    static func stillSame(_ r: ProcessRef) -> Bool {
        guard let b = bsdInfo(r.pid) else { return false }
        let start = UInt64(b.pbi_start_tvsec) * 1_000_000 + UInt64(b.pbi_start_tvusec)
        return start == r.start && b.pbi_uid == getuid()
    }
    #endif
}
