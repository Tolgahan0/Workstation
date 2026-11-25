import Cocoa

// Otomasyon: uzak oturumla otomatik mod geçişi (1.7.0).
extension AppDelegate {

    func configureAutoSwitch() {
        autoSwitchTimer?.invalidate()
        autoSwitchTimer = nil
        autoEngine.reset()
        guard autoSettings.enabled else {
            panelModel.autoSwitchStatus = L("Kapalı")
            return
        }
        Log.info("Otomatik mod geçişi açık (SSH: \(autoSettings.includeSSH ? "evet" : "hayır"), sonra: \(autoSettings.after.title), \(autoSettings.idleMinutes) dk)")
        let t = Timer(timeInterval: AutoSwitchSettings.checkInterval, repeats: true) { [weak self] _ in
            self?.autoSwitchTick()
        }
        t.tolerance = 3
        RunLoop.main.add(t, forMode: .common)
        autoSwitchTimer = t
        autoSwitchTick()
    }

    func autoSwitchTick() {
        guard didFinishLaunching else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let probe = RemoteSessionProbe.current()
            DispatchQueue.main.async { self?.handleSessionProbe(screenSharing: probe.screenSharing, ssh: probe.ssh) }
        }
    }

    private func handleSessionProbe(screenSharing: Bool, ssh: Bool) {
        guard autoSettings.enabled else { return }
        var parts: [String] = []
        parts.append(screenSharing ? L("Ekran Paylaşımı: bağlı") : L("Ekran Paylaşımı: yok"))
        if autoSettings.includeSSH { parts.append(ssh ? L("SSH: bağlı") : L("SSH: yok")) }
        if let e = autoEngine.endedAt, currentMode == .remote, autoSettings.after != .none {
            let left = max(0, Double(autoSettings.idleMinutes) * 60 - Date().timeIntervalSince(e))
            parts.append(L("%@ dk sonra %@", Int(ceil(left / 60)), autoSettings.after.title))
        }
        let status = L("Şu an: ") + parts.joined(separator: " · ")
        if panelModel.autoSwitchStatus != status { panelModel.autoSwitchStatus = status }

        // Geçiş sürerken karar verme (bir sonraki taramada yeniden değerlendirilir).
        guard !isTransitioning, !countdownActive else { return }
        let action = autoEngine.update(screenSharing: screenSharing, ssh: ssh, now: Date(),
                                       currentMode: currentMode, settings: autoSettings)
        switch action {
        case .none:
            break
        case .enterRemote(let reason):
            Log.info("Otomatik: \(reason) algılandı → Remote")
            requestMode(.remote, source: L("otomatik (%@)", reason))
        case .leaveRemote(let mode):
            Log.info("Otomatik: uzak oturum \(autoSettings.idleMinutes) dk önce bitti → \(mode.rawValue)")
            requestMode(mode, source: L("otomatik (oturum bitti)"))
        }
    }
}

// MARK: - Zamanlanmış modlar
extension AppDelegate {

    /// Bir sonraki kural için tek atımlık zamanlayıcı kurar. catchUp: son kontrolden bu yana kaçırılanı çalıştır.
    func rescheduleModes(catchUp: Bool) {
        scheduleTimer?.invalidate()
        scheduleTimer = nil
        let now = Date()
        let rules = scheduleSettings.rules
        if catchUp, didFinishLaunching {
            let due = ScheduleEngine.due(from: lastScheduleCheck, to: now, rules: rules)
            if let last = due.last { runScheduled(last.rule) }
        }
        lastScheduleCheck = now
        guard let next = ScheduleEngine.nextFire(after: now, rules: rules) else {
            panelModel.scheduleNext = rules.isEmpty ? "" : (rules.contains { $0.enabled } ? L("Etkin kural yok") : L("Tüm kurallar kapalı"))
            return
        }
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateFormat = "EEE HH:mm"
        panelModel.scheduleNext = L("Sonraki: %@ → %@", f.string(from: next.date), next.rule.mode == .desktop ? L("Masaüstü") : (next.rule.mode == .sleep ? L("Uyku") : "Remote"))
        let t = Timer(fire: next.date, interval: 0, repeats: false) { [weak self] _ in
            self?.rescheduleModes(catchUp: true)
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        scheduleTimer = t
    }

    private func runScheduled(_ rule: ScheduleRule) {
        guard rule.mode != currentMode || isTransitioning else {
            Log.info("Zamanlama \(rule.timeText): zaten \(rule.mode.rawValue) modunda, atlandı")
            return
        }
        Log.info("Zamanlama \(rule.timeText) (\(rule.daysText)) → \(rule.mode.rawValue)")
        requestMode(rule.mode, source: L("zamanlama %@", rule.timeText))
    }

    /// pmset repeat wakeorpoweron: yalnızca bu ayar açıkken yazılır; kapatılınca (yalnızca bizim
    /// kurduğumuz) tekrar eden uyanma iptal edilir.
    func applyScheduledWake() {
        let settings = scheduleSettings
        let ownedKey = "pmsetRepeatOwned"
        let defaults = UserDefaults.standard
        let power = controller.power
        DispatchQueue.global(qos: .utility).async {
            if settings.wakeEnabled {
                let args = ScheduleEngine.pmsetRepeatArgs(rules: settings.rules)
                if power.setRepeatWake(args) { defaults.set(args != nil, forKey: ownedKey) }
            } else if defaults.bool(forKey: ownedKey) {
                if power.setRepeatWake(nil) { defaults.set(false, forKey: ownedKey) }
            }
        }
    }
}

// MARK: - Profiller
extension AppDelegate {

    func saveProfile(named name: String) {
        let desired = controller.display.monitors.store.all()
        let p = WorkspaceProfile.make(name: name, desired: desired, fanMode: fans.preferredMode)
        let list = ProfileStore.upsert(p, into: ProfileStore.load())
        ProfileStore.save(list)
        panelModel.profiles = list
        panelModel.profileNote = L("“%@” kaydedildi", name)
        Log.info("Profil kaydedildi: \(name) (\(p.summary))")
    }

    /// Profili uygular (panel, URL, CLI). Remote/Uyku'da monitör durumları yalnızca kaydedilir.
    func applyProfile(_ p: WorkspaceProfile, source: String) {
        Log.info("Profil uygulanıyor: \(p.name) (kaynak: \(source), mod: \(currentMode.rawValue))")
        panelModel.profileNote = L("“%@” uygulanıyor…", p.name)
        beginOwnChangeForFeature()
        controller.applyProfile(p, mode: currentMode) { [weak self] notes in
            guard let self = self else { return }
            self.endOwnChangeForFeature()
            self.panelModel.profileNote = notes.isEmpty ? L("“%@” uygulandı", p.name) : notes.joined(separator: "; ")
            self.refreshMonitors()
        }
        if let f = p.fanMode, f != fans.preferredMode {
            panelModel.fanMode = f
            fans.apply(f, reason: L("profil %@", p.name)) { [weak self] err in
                if let e = err { self?.panelModel.fanNote = "Profildeki fan ayarı uygulanamadı."; Log.warn("Profil fan: \(e)") }
            }
        }
    }
}

// MARK: - Tools → sistem istatistikleri
extension AppDelegate {
    /// Fan okumasıyla aynı zamanlayıcıdan (yalnızca panel açık + Tools görünürken) çağrılır.
    func refreshSystemStats() {
        let sampler = statsSampler
        statsQueue.async { [weak self] in
            let s = sampler.sample()
            DispatchQueue.main.async {
                guard let self = self, self.popover != nil else { return }
                if self.panelModel.stats != s { self.panelModel.stats = s }
                self.statsObserved(s)
            }
        }
    }

    /// Tools görünürken her örnekte: disk uyarısı (bildirim hız sınırlıdır).
    func statsObserved(_ s: SystemStatsSnapshot) {
        if NotificationPolicy.isLowDisk(free: s.diskFree, total: s.diskTotal) { notifyLowDisk(free: s.diskFree, total: s.diskTotal) }
    }
}

// MARK: - Bildirimler
extension AppDelegate {
    /// Açılışta ve uyanınca bir kez (yoklama yok).
    func checkDiskSpace() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let d = SystemStatsSampler.disk()
            DispatchQueue.main.async {
                if NotificationPolicy.isLowDisk(free: d.0, total: d.1) { self?.notifyLowDisk(free: d.0, total: d.1) }
            }
        }
    }

    func notifyLowDisk(free: Int64?, total: Int64?) {
        guard notifySettings.lowDisk, let f = free, let t = total, t > 0 else { return }
        let pct = Int((Double(f) / Double(t) * 100).rounded())
        notifier.notify(kind: "lowDisk", title: L("Disk alanı azaldı"),
                        body: L("Diskte sadece %@ (%%@) boş yer kaldı. Tools › Disk'ten temizleyebilirsin.", StatsFormat.bytes(Double(f)), pct))
    }

    func notifyOverheat(_ temp: Double, extra: String?) {
        guard notifySettings.overheat else { return }
        notifier.notify(kind: "overheat", title: L("Mac mini çok ısındı: %@ °C", Int(temp)),
                        body: L("Mac çok ısındı. Havalandırmasının açık olduğundan emin ol.") + (extra.map { " " + $0 } ?? ""))
    }

    /// `kill`/`pkill` (SIGTERM) gelince de temiz kapan: fanlar otomatiğe, temiz çıkış bayrağı yazılır.
    func installTerminationSignalHandler() {
        signal(SIGTERM, SIG_IGN)
        // Ana kuyruk modal bir pencere (NSAlert) açıkken işlenmez; sinyal arka kuyrukta yakalanır ve
        // kapanış ana run loop'un "common" modlarına (modal mod dahil) gönderilir.
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInitiated))
        src.setEventHandler {
            Log.info("SIGTERM alındı → temiz kapanış")
            let main = CFRunLoopGetMain()
            CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) {
                if NSApp.modalWindow != nil { NSApp.abortModal() }
                NSApp.terminate(nil)
            }
            CFRunLoopWakeUp(main)
        }
        src.resume()
        sigtermSource = src
    }
}
