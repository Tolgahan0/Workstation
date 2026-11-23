import Cocoa

// Güncelleyici bağlantısı: açılıştan kısa süre sonra ve günde bir kez kontrol; boşta yoklama yok (tek zamanlayıcı).
extension AppDelegate {

    var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    func wireUpdater() {
        let u = panelModel.updater
        u.hasToken = UpdateToken.read() != nil
        u.onCheck = { [weak self] in self?.checkForUpdates(manual: true) }
        u.onInstall = { [weak self] in self?.installUpdate(automatic: false) }
        u.onOpenSettings = { [weak self] in self?.panelModel.page = .settings }
        u.onSettings = { [weak self] s in
            let betaChanged = s.beta != u.settings.beta
            s.save()
            u.settings = s
            if betaChanged { u.candidate = nil; u.phase = .idle; self?.checkForUpdates(manual: true) }
        }
        u.onSaveToken = { t in
            let ok = UpdateToken.save(t)
            u.hasToken = UpdateToken.read() != nil
            u.showToken = false
            u.tokenDraft = ""
            if !ok { u.phase = .failed(L("Anahtar kaydedilemedi")) }
        }
        scheduleUpdateCheck(after: 20)
    }

    /// Tek seferlik zamanlayıcı; her kontrolden sonra 24 saat sonrasına yeniden kurulur.
    func scheduleUpdateCheck(after delay: TimeInterval) {
        updateTimer?.invalidate()
        let t = Timer(timeInterval: max(5, delay), repeats: false) { [weak self] _ in
            self?.checkForUpdates(manual: false)
        }
        t.tolerance = min(600, delay * 0.1 + 5)
        RunLoop.main.add(t, forMode: .common)
        updateTimer = t
    }

    /// Uykudan uyanınca: son kontrol 24 saatten eskiyse kısa süre sonra kontrol et.
    func updateCheckAfterWake() {
        let last = panelModel.updater.lastChecked ?? .distantPast
        if Date().timeIntervalSince(last) > UpdatePolicy.checkInterval { scheduleUpdateCheck(after: 60) }
    }

    func checkForUpdates(manual: Bool) {
        let u = panelModel.updater
        guard !u.busy else { return }
        if u.phase != .available { u.phase = .checking }
        let engine = Updater(bundleID: Bundle.main.bundleIdentifier ?? "com.tolgahanayaz.workstationmode",
                             currentVersion: currentAppVersion, settings: u.settings)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try engine.check() }
            DispatchQueue.main.async {
                guard let self = self else { return }
                let now = Date()
                u.lastChecked = now
                UserDefaults.standard.set(now, forKey: "updateLastChecked")
                self.scheduleUpdateCheck(after: UpdatePolicy.checkInterval)
                switch result {
                case .success(let c?):
                    let isNew = u.candidate?.version != c.version
                    u.candidate = c
                    u.phase = .available
                    Log.info("Güncelleme bulundu: \(c.version)")
                    if u.settings.autoInstall && self.currentMode != .remote && !self.isTransitioning {
                        self.installUpdate(automatic: true)
                    } else if isNew && !manual {
                        self.notifier.notify(kind: "update", title: L("Workstation %@ hazır", c.version),
                                             body: L("Güncellemek için menü çubuğundaki simgeye tıkla."))
                    }
                case .success(nil):
                    u.candidate = nil
                    u.phase = manual ? .upToDate : .idle
                case .failure(let e):
                    Log.warn("Güncelleme kontrolü başarısız: \(e.localizedDescription)")
                    if manual || u.phase == .checking {
                        u.phase = manual ? .failed(L("Kontrol edilemedi: %@", e.localizedDescription)) : (u.candidate != nil ? .available : .idle)
                    }
                }
            }
        }
    }

    func installUpdate(automatic: Bool) {
        let u = panelModel.updater
        guard let c = u.candidate, !u.busy else { return }
        guard Bundle.main.bundlePath.hasSuffix(".app") else {
            u.phase = .failed(L("Uygulama paketinden çalışmıyor; güncelleme atlandı"))
            return
        }
        u.phase = .working(L("İndiriliyor…"))
        let engine = Updater(bundleID: Bundle.main.bundleIdentifier ?? "com.tolgahanayaz.workstationmode",
                             currentVersion: currentAppVersion, settings: u.settings)
        let dest = Bundle.main.bundlePath
        Log.info("Güncelleme başlıyor: \(currentAppVersion) → \(c.version) (\(automatic ? "otomatik" : "elle"))")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let app = try engine.prepare(c) { s in DispatchQueue.main.async { u.phase = .working(s) } }
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    // Kurulumdan hemen önce yeniden kontrol: bu arada Remote'a geçildiyse otomatik kurulum ertelenir.
                    if automatic && (self.currentMode == .remote || self.isTransitioning) {
                        u.phase = .available
                        return
                    }
                    do {
                        u.phase = .working(L("Yeniden başlatılıyor…"))
                        try engine.launchSwap(newApp: app, destination: dest)
                        Log.info("Güncelleme hazır, uygulama yeniden başlatılıyor")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
                    } catch {
                        u.phase = .failed(L("Güncelleme başlatılamadı: %@", error.localizedDescription))
                    }
                }
            } catch {
                Log.warn("Güncelleme başarısız: \(error.localizedDescription)")
                DispatchQueue.main.async { u.phase = .failed(error.localizedDescription) }
            }
        }
    }
}
