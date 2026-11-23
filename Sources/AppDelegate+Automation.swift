import Cocoa

// Otomasyon: uzak oturumla otomatik mod geçişi (1.7.0).
extension AppDelegate {

    func configureAutoSwitch() {
        autoSwitchTimer?.invalidate()
        autoSwitchTimer = nil
        autoEngine.reset()
        guard autoSettings.enabled else {
            panelModel.autoSwitchStatus = "Kapalı"
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
        parts.append(screenSharing ? "Ekran Paylaşımı: bağlı" : "Ekran Paylaşımı: yok")
        if autoSettings.includeSSH { parts.append(ssh ? "SSH: bağlı" : "SSH: yok") }
        if let e = autoEngine.endedAt, currentMode == .remote, autoSettings.after != .none {
            let left = max(0, Double(autoSettings.idleMinutes) * 60 - Date().timeIntervalSince(e))
            parts.append("\(Int(ceil(left / 60))) dk sonra \(autoSettings.after.title)")
        }
        let status = "Şu an: " + parts.joined(separator: " · ")
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
            requestMode(.remote, source: "otomatik (\(reason))")
        case .leaveRemote(let mode):
            Log.info("Otomatik: uzak oturum \(autoSettings.idleMinutes) dk önce bitti → \(mode.rawValue)")
            requestMode(mode, source: "otomatik (oturum bitti)")
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
            panelModel.scheduleNext = rules.isEmpty ? "" : "Etkin kural yok"
            return
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = "EEE HH:mm"
        panelModel.scheduleNext = "Sonraki: \(f.string(from: next.date)) → \(next.rule.mode == .desktop ? "Masaüstü" : (next.rule.mode == .sleep ? "Uyku" : "Remote"))"
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
        requestMode(rule.mode, source: "zamanlama \(rule.timeText)")
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
