import Cocoa

// Otomatik disk temizliği: günlük tek atımlık zamanlayıcı + 6 saatte bir ucuz boş alan kontrolü (statfs).
extension AppDelegate {

    // MARK: Otomatik mod

    func configureCleanerAuto() {
        cleanerTimer?.invalidate()
        cleanerTimer = nil
        cleanerSpaceTimer?.invalidate()
        cleanerSpaceTimer = nil
        let s = panelModel.cleaner.settings
        guard s.autoEnabled else { return }
        if let next = CleanerAutoPolicy.nextDaily(after: Date(), settings: s) {
            let t = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
                self?.runAutoClean(trigger: .daily)
                self?.configureCleanerAuto()
            }
            t.tolerance = 60
            RunLoop.main.add(t, forMode: .common)
            cleanerTimer = t
            Log.info("Otomatik temizlik: sonraki \(next)")
        }
        if s.autoLowSpace {
            let t = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.cleanerSpaceCheck(reason: L("6 saatlik kontrol")) }
            t.tolerance = 600
            RunLoop.main.add(t, forMode: .common)
            cleanerSpaceTimer = t
        }
    }

    /// Ucuz boş alan kontrolü (açılışta, uyanınca, 6 saatte bir).
    func cleanerSpaceCheck(reason: String) {
        let s = panelModel.cleaner.settings
        guard s.autoEnabled, s.autoLowSpace else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let d = SystemStatsSampler.disk(path: FileManager.default.homeDirectoryForCurrentUser.path)
            DispatchQueue.main.async {
                guard let self = self else { return }
                let last = UserDefaults.standard.object(forKey: "cleanerLastAuto") as? Date
                if CleanerAutoPolicy.shouldRunLowSpace(free: d.0, total: d.1, settings: s, lastRun: last, now: Date()) {
                    Log.info("Otomatik temizlik: boş alan az (\(reason))")
                    self.runAutoClean(trigger: .lowSpace)
                }
            }
        }
    }

    func runAutoClean(trigger: CleanerAutoPolicy.Trigger) {
        let s = panelModel.cleaner.settings
        guard s.autoEnabled || trigger == .url else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let batt = Shell.run("/usr/bin/pmset", ["-g", "batt"], timeout: 5)
            let blocker = CleanerAutoPolicy.blocker(battery: CleanerRules.battery(batt.stdout),
                                                    cpuPercent: CleanerAutoPolicy.cpuBusyPercent(), settings: s)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let b = blocker, trigger != .url {
                    Log.info("Otomatik temizlik ertelendi: \(b)")
                    // 1 saat sonra bir kez daha dene (boş alan tetikleyicisi zaten 6 saatte bir bakar).
                    if trigger == .daily {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3600) { [weak self] in self?.runAutoClean(trigger: .lowSpace) }
                    }
                    return
                }
                UserDefaults.standard.set(Date(), forKey: "cleanerLastAuto")
                self.startCleanerScan(trigger: trigger, autoClean: true)
            }
        }
    }
}
