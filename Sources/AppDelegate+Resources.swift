import AppKit

// Tools › Kaynaklar: örnekleme zamanlayıcıları, bellek baskısı bildirimi ve "Boştakileri kapat".
// Maliyet: panel kapalıyken 60 sn'de bir yalnızca sysctl + birkaç ajan sürecinin CPU süresi;
// Tools görünürken 2 sn'de bir tam örnek (süreç listesi + IOKit GPU).

extension AppDelegate {
    func wireResources() {
        let r = panelModel.resources
        r.onQuit = { [weak self] items in self?.quitIdle(items, automatic: false) }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.resourceTick(full: false) }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        resourceBackgroundTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.resourceTick(full: false) }
    }

    func startResourcePolling() {
        guard resourceForegroundTimer == nil else { return }
        resourceTick(full: true)
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.resourceTick(full: true) }
        t.tolerance = 0.4
        RunLoop.main.add(t, forMode: .common)
        resourceForegroundTimer = t
    }

    func stopResourcePolling() {
        resourceForegroundTimer?.invalidate()
        resourceForegroundTimer = nil
    }

    private struct FrontInfo {
        var pid: Int32?
        var bundle: String?
        var docker: Bool
    }

    private func frontInfo() -> FrontInfo {
        let f = NSWorkspace.shared.frontmostApplication
        let docker = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.docker.docker").isEmpty
        return FrontInfo(pid: f?.processIdentifier, bundle: f?.bundleIdentifier, docker: docker)
    }

    func resourceTick(full: Bool) {
        let front = full ? frontInfo() : FrontInfo(pid: nil, bundle: nil, docker: false)
        let sampler = resourceSampler
        resourceQueue.async { [weak self] in
            let snap = sampler.sample(full: full)
            var idle: [IdleItem]?
            if full {
                let sims = Self.bootedSimulators(hasSimProcess: snap.top.contains { $0.kind == .simulator })
                idle = sampler.idleItems(frontmostPID: front.pid, frontmostBundle: front.bundle, dockerRunning: front.docker,
                                         bootedSimulators: sims, activeProject: Self.isActiveProject)
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                let r = self.panelModel.resources
                if full && self.resourceForegroundTimer != nil {
                    if r.snapshot != snap { r.snapshot = snap }
                    if let i = idle, r.idle != i { r.idle = i }
                }
                self.pressureObserved(snap.pressure, top: full ? snap.top : nil)
            }
        }
    }

    /// Yalnızca simülatör süreçleri varken (ucuz kontrol) simctl çağrılır.
    static func bootedSimulators(hasSimProcess: Bool) -> [String] {
        guard hasSimProcess else { return [] }
        let r = Shell.run("/usr/bin/xcrun", ["simctl", "list", "-j", "devices", "booted"], timeout: 5)
        guard r.succeeded, let data = r.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = obj["devices"] as? [String: Any] else { return [] }
        var names: [String] = []
        for case let list as [[String: Any]] in devices.values {
            for d in list where (d["state"] as? String) == "Booted" { if let n = d["name"] as? String { names.append(n) } }
        }
        return names.sorted()
    }

    /// Ajanın çalışma klasörü (git kökü) son N dakikada değiştiyse etkin proje sayılır (temizleyicinin mantığı).
    static func isActiveProject(_ cwd: String) -> Bool {
        let home = NSHomeDirectory()
        guard cwd != "/" && cwd != home else { return false }
        var dir = cwd
        let fm = FileManager.default
        while dir.count > home.count {
            if fm.fileExists(atPath: dir + "/.git") { break }
            dir = (dir as NSString).deletingLastPathComponent
        }
        if dir.count <= home.count { dir = cwd }
        guard let d = DiskUsage.newestActivity(project: dir, excluding: CleanerScanner.artifactNames, maxDepth: 3, budget: 1500) else {
            return false
        }
        return Date().timeIntervalSince(d) < Double(IdlePolicy.idleMinutes) * 60
    }

    // MARK: Bellek baskısı bildirimi

    private func pressureObserved(_ level: Int, top: [AppUsage]?) {
        guard level > 0 else { return }
        let previous = lastPressureLevel
        lastPressureLevel = level
        guard IdlePolicy.shouldNotify(level: level, previous: previous), notifySettings.memoryPressure else { return }
        let send: ([AppUsage]) -> Void = { [weak self] list in
            guard let self = self else { return }
            let app = list.first { $0.kind != .system }
            let title = level >= 4 ? L("Bellek baskısı yüksek") : L("Bellek baskısı arttı")
            let body = app.map { L("En çok kullanan: %@ (%@). Tools › Kaynaklar'dan boştakileri kapatabilirsin.",
                                   $0.title, StatsFormat.bytes(Double($0.footprint))) }
                ?? L("Tools › Kaynaklar'dan boştakileri kapatabilirsin.")
            self.notifier.notify(kind: level >= 4 ? "memoryCritical" : "memoryPressure", title: title, body: body)
        }
        if let t = top { send(t); return }
        // Panel kapalı: en çok kullananı bulmak için tek seferlik tam örnek.
        let sampler = resourceSampler
        resourceQueue.async {
            let s = sampler.sample(full: true)
            DispatchQueue.main.async { send(s.top) }
        }
    }

    // MARK: Boştakileri kapat

    /// Remote/Uyku'ya geçerken (ayar açıksa): simülatörler ve boştaki CLI ajanları. Docker'a dokunulmaz.
    func closeIdleForModeSwitch(_ mode: WorkMode) {
        guard mode != .desktop, ResourceModel.autoOnSwitchSaved else { return }
        let front = frontInfo()
        let sampler = resourceSampler
        resourceQueue.async { [weak self] in
            let snap = sampler.sample(full: true)
            let sims = Self.bootedSimulators(hasSimProcess: snap.top.contains { $0.kind == .simulator })
            let items = sampler.idleItems(frontmostPID: front.pid, frontmostBundle: front.bundle, dockerRunning: false,
                                          bootedSimulators: sims, activeProject: Self.isActiveProject)
                .filter { $0.kind != .docker }
            guard !items.isEmpty else { return }
            DispatchQueue.main.async { self?.quitIdle(items, automatic: true) }
        }
    }

    func quitIdle(_ items: [IdleItem], automatic: Bool) {
        guard !items.isEmpty else { return }
        let r = panelModel.resources
        r.busy = true
        r.note = nil
        let front = NSWorkspace.shared.frontmostApplication
        let frontPID = front?.processIdentifier
        let freed = items.reduce(UInt64(0)) { $0 + $1.footprint }
        Log.info("Boştakiler kapatılıyor\(automatic ? " (otomatik)" : ""): \(items.map { $0.title }.joined(separator: ", "))")
        for it in items where it.kind == .docker {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.docker.docker") where app != front {
                app.terminate()
            }
        }
        resourceQueue.async { [weak self] in
            var closed: [String] = []
            for it in items {
                switch it.kind {
                case .simulators:
                    let res = Shell.run("/usr/bin/xcrun", ["simctl", "shutdown", "all"], timeout: 30)
                    if res.succeeded { closed.append(it.title) } else { Log.warn("simctl shutdown: \(res.stderr)") }
                    DispatchQueue.main.async {
                        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.iphonesimulator")
                        where app.processIdentifier != NSWorkspace.shared.frontmostApplication?.processIdentifier {
                            app.terminate()
                        }
                    }
                case .agent:
                    var n = 0
                    for p in it.pids where p.pid != frontPID && p.pid > 1 && ResourceSampler.stillSame(p) {
                        if kill(p.pid, SIGTERM) == 0 { n += 1 }   // yalnızca SIGTERM: süreç düzgünce kapanır
                    }
                    if n > 0 { closed.append(it.title) }
                    Log.info("\(it.title): \(n) sürece SIGTERM gönderildi")
                case .docker:
                    closed.append(it.title)
                }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                r.busy = false
                r.note = closed.isEmpty ? L("Kapatılacak bir şey kalmamıştı.")
                    : L("Kapatıldı: %@ · yaklaşık %@ boşalacak", closed.joined(separator: ", "), StatsFormat.bytes(Double(freed)))
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { if r.note != nil && !r.busy { r.note = nil } }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    if self?.resourceForegroundTimer != nil { self?.resourceTick(full: true) }
                }
            }
        }
    }
}
