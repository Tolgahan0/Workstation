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
