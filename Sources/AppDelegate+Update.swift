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
        u.onUpdateHelpers = { [weak self] in self?.updateHelpers() }
        notifier.onClick = { [weak self] kind in
            if kind == "update" || kind == "helpers" { self?.openPanel() }
        }
        refreshHelperState(afterLaunch: true)
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

    /// Tek seferlik zamanlayıcı; her kontrolden sonra 6 saat sonrasına yeniden kurulur.
    func scheduleUpdateCheck(after delay: TimeInterval) {
        updateTimer?.invalidate()
        let t = Timer(timeInterval: max(5, delay), repeats: false) { [weak self] _ in
            self?.checkForUpdates(manual: false)
        }
        t.tolerance = min(600, delay * 0.1 + 5)
        RunLoop.main.add(t, forMode: .common)
        updateTimer = t
    }

    /// Uykudan uyanınca: son kontrol 6 saatten eskiyse kısa süre sonra kontrol et.
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
                    u.candidate = c
                    u.phase = .available
                    u.progress = nil
                    self.setUpdateIcon(true)
                    Log.info("Güncelleme bulundu: \(c.version)")
                    let notifiedKey = "updateNotifiedVersion"
                    let firstTime = UpdatePolicy.shouldNotify(version: c.version,
                                                              lastNotified: UserDefaults.standard.string(forKey: notifiedKey))
                    if u.settings.autoInstall && self.currentMode != .remote && !self.isTransitioning {
                        self.installUpdate(automatic: true)
                    } else if firstTime {
                        UserDefaults.standard.set(c.version, forKey: notifiedKey)
                        self.notifier.notify(kind: "update", title: L("Workstation %@ hazır — güncellemek için tıkla", c.version),
                                             body: L("Tek tıkla indirir, doğrular, kurar ve yeniden açar."))
                    }
                case .success(nil):
                    u.candidate = nil
                    u.phase = manual ? .upToDate : .idle
                    self.setUpdateIcon(false)
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
        u.progress = nil
        let engine = Updater(bundleID: Bundle.main.bundleIdentifier ?? "com.tolgahanayaz.workstationmode",
                             currentVersion: currentAppVersion, settings: u.settings)
        let dest = Bundle.main.bundlePath
        Log.info("Güncelleme başlıyor: \(currentAppVersion) → \(c.version) (\(automatic ? "otomatik" : "elle"))")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let app = try engine.prepare(c, progress: { s in DispatchQueue.main.async { u.phase = .working(s) } },
                                             fraction: { f in DispatchQueue.main.async { u.progress = f } })
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

    // MARK: Yardımcılar (fan yardımcısı + workstation komutu)

    /// Kurulu yardımcılar eskiyse panelde "Yardımcıları güncelle" gösterir; güncellemeden sonraki ilk açılışta bir kez sorar.
    func refreshHelperState(afterLaunch: Bool) {
        let u = panelModel.updater
        let app = URL(fileURLWithPath: Bundle.main.bundlePath)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let outdated = Bundle.main.bundlePath.hasSuffix(".app") && Updater.helpersOutdated(app: app)
            DispatchQueue.main.async {
                guard let self = self else { return }
                u.helpersOutdated = outdated
                guard afterLaunch else { return }
                let key = "lastLaunchedVersion"
                let previous = UserDefaults.standard.string(forKey: key)
                UserDefaults.standard.set(self.currentAppVersion, forKey: key)
                if outdated && previous != nil && previous != self.currentAppVersion {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.askToUpdateHelpers() }
                }
            }
        }
    }

    /// Güncellemeden sonra tek tıklık soru: macOS'un standart yönetici parolası penceresi (Terminal gerekmez).
    func askToUpdateHelpers() {
        let a = NSAlert()
        a.messageText = L("Yardımcıları güncelle")
        a.informativeText = L("Workstation %@ sürümüne güncellendi. Fan kontrolü, parolasız mod geçişi ve workstation komutu da güncellenmeli. macOS yönetici parolanı bir kez soracak.", currentAppVersion)
        a.addButton(withTitle: L("Yardımcıları güncelle"))
        a.addButton(withTitle: L("Sonra"))
        // Modal DEĞİL: runModal ana iş parçacığını kilitler; kullanıcı uzaktayken (SSH/URL ile mod değişimi,
        // zamanlamalar, kapanış) pencere kapanana dek her şey beklerdi. Panelde aynı düğme zaten var.
        a.buttons[0].target = self
        a.buttons[0].action = #selector(helperAlertUpdate(_:))
        a.buttons[1].target = self
        a.buttons[1].action = #selector(helperAlertLater(_:))
        helperAlert?.window.orderOut(nil)
        helperAlert = a
        a.window.level = .floating
        a.window.center()
        NSApp.activate(ignoringOtherApps: true)
        a.window.makeKeyAndOrderFront(nil)
    }

    @objc func helperAlertUpdate(_ sender: Any?) {
        helperAlert?.window.orderOut(nil)
        helperAlert = nil
        updateHelpers()
    }

    @objc func helperAlertLater(_ sender: Any?) {
        helperAlert?.window.orderOut(nil)
        helperAlert = nil
    }

    func updateHelpers() {
        let u = panelModel.updater
        guard !u.helpersBusy else { return }
        helperAlert?.window.orderOut(nil)
        helperAlert = nil
        u.helpersBusy = true
        u.helpersNote = nil
        let script = Updater.helperInstallAppleScript(app: Bundle.main.bundlePath, user: NSUserName())
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = Shell.run("/usr/bin/osascript", ["-e", script], timeout: 300)
            DispatchQueue.main.async {
                u.helpersBusy = false
                if r.succeeded {
                    Log.info("Yardımcılar güncellendi")
                    u.helpersNote = L("Yardımcılar güncellendi")
                } else if r.stderr.contains("-128") {
                    u.helpersNote = L("İptal edildi")
                } else {
                    Log.warn("Yardımcılar güncellenemedi: \(r.stderr)")
                    u.helpersNote = L("Güncellenemedi: %@", r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                self?.refreshHelperState(afterLaunch: false)
            }
        }
    }
}
