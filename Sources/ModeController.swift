import Foundation

/// Ekran ve güç işlerini seri bir arka plan kuyruğunda yürütür. AppDelegate (ana iş parçacığı)
/// yalnızca bu sınıfın metotlarını çağırır; tamamlanma blokları ana kuyrukta çalışır.
/// (Yalnızca Foundation; Linux'ta da derlenir.)
final class ModeController {
    let display = DisplayManager()
    let power = PowerManager()
    let installer = BetterDisplayInstaller()
    /// Tüm ekran/güç geçişleri sırayla bu kuyrukta çalışır (menü donmaz, geçişler çakışmaz).
    private let queue = DispatchQueue(label: "com.tolgahanayaz.workstationmode.work", qos: .userInitiated)
    /// Parlaklık yazmaları: birleştirilmiş, hız sınırlı, tek seri kuyrukta.
    private(set) var brightness: BrightnessCoalescer!

    init() {
        let monitors = display.monitors
        brightness = BrightnessCoalescer(
            interval: { key in
                monitors.method(for: key) == .ddc ? BrightnessCoalescer.ddcInterval : BrightnessCoalescer.softwareInterval
            },
            apply: { key, value in monitors.setBrightness(key: key, percent: value) })
    }

    /// Açılış hazırlığı. BetterDisplay kuruluysa başlatılır ve CLI doğrulanır; kurulu değilse dokunulmaz
    /// (Remote ilk kez başlatıldığında otomatik kurulur). Sanal ekran burada oluşturulmaz.
    func prepare(completion: @escaping (_ bdInstalled: Bool, _ cliAvailable: Bool) -> Void) {
        queue.async {
            let installed = BetterDisplayInstaller.isInstalled
            var cliOK = false
            if installed {
                self.display.ensureBetterDisplayRunning()
                cliOK = self.display.isCLIAvailable()
                if cliOK && !self.display.usesNativePhysicalControl { self.display.refreshPhysicalDisplays() }
            } else {
                Log.info("BetterDisplay kurulu değil; Remote başlatıldığında otomatik kurulacak.")
            }
            self.display.configureBackend()
            Log.info("Fiziksel ekran yöntemi: \(self.display.methodDescription)")
            let ok = cliOK
            DispatchQueue.main.async { completion(installed, ok) }
        }
    }

    /// pmset (sudo) çağrıları ekran işlerini beklemesin diye ayrı seri kuyrukta, paralel yürür.
    private let powerQueue = DispatchQueue(label: "com.tolgahanayaz.workstationmode.power", qos: .userInitiated)

    /// Remote geri sayımı başlarken: sanal ekranı şimdiden hazırla (bağla + çözünürlük) ki geri sayım
    /// bitince fiziksel monitörler HEMEN kesilebilsin. Fiziksel monitörlere dokunmaz.
    func prepareRemote(resolution: String?) {
        queue.async {
            guard BetterDisplayInstaller.isInstalled else { return }
            let sw = Stopwatch("remote hazırlık (geri sayım)")
            DisplayManager.resolutionOverride = resolution.flatMap(RemotePreset.normalize)
            if let e = self.display.prepareRemote(sw) { Log.warn("Remote hazırlığı: \(e)") }
            DisplayManager.resolutionOverride = nil
            sw.lap("bitti")
        }
    }

    /// Remote'ta sanal ekranı istemcinin görüntü alanına uydur (bkz. `workstation fit`).
    func refit(_ res: String, completion: @escaping (Bool) -> Void) {
        queue.async {
            let sw = Stopwatch("uydur \(res)")
            let ok = self.display.refitVirtual(res)
            sw.lap(ok ? "tamam" : "olmadı")
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// Remote geri sayımı iptal edildi: hazırlıkta açılan sanal ekranı kapat.
    func cancelRemotePreparation() {
        queue.async { self.display.cancelRemotePreparation() }
    }

    /// Modu uygular. `resolution`: Remote için istemciden gelen çözünürlük (nil = seçili ön ayar).
    /// Sıra: ÖNCE ekranlar (kullanıcının gördüğü), pmset ise paralel; doğrulama sonradan.
    /// completion: hata açıklaması veya nil.
    func apply(_ mode: WorkMode, resolution: String? = nil, completion: @escaping (String?) -> Void) {
        let power = self.power
        let pm = DispatchGroup()
        pm.enter()
        powerQueue.async {
            let sw = Stopwatch("pmset \(mode.rawValue)")
            switch mode {
            case .desktop: power.applyDesktopProfile()
            case .sleep: power.applySleepProfile()
            case .remote: power.applyRemoteProfile()   // Mac uzaktan erişim için her durumda uyanık kalsın.
            }
            sw.lap("uygulandı")
            pm.leave()
        }
        queue.async {
            let sw = Stopwatch("mod \(mode.rawValue)")
            var error: String?
            switch mode {
            case .desktop:
                error = self.display.applyDesktopLayout()
            case .sleep:
                // Sanal ekran kapanır (Remote'tan gelindiyse); monitörler KESİLMEZ ve hemen ekran uykusuna alınır.
                error = self.display.applySleepLayout()
                self.power.displaySleepNow()
                sw.lap("ekranlar uyutuldu")
            case .remote:
                if !BetterDisplayInstaller.isInstalled, let e = self.installer.installSync() {
                    error = L("BetterDisplay kurulamadı: %@", e)
                } else {
                    if let r = resolution.flatMap(RemotePreset.normalize) {
                        RemoteResolution.lastClientResolution = r
                    }
                    DisplayManager.resolutionOverride = resolution.flatMap(RemotePreset.normalize)
                    error = self.display.applyRemoteLayout()
                    DisplayManager.resolutionOverride = nil
                }
            }
            sw.lap("ekran düzeni")
            _ = pm.wait(timeout: .now() + 20)
            sw.lap("pmset ile birlikte tamam")
            if let e = error { Log.error("\(mode.rawValue): \(e)") }
            let result = error
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// BetterDisplay'i kullanıcı isteğiyle (Ayarlar / Remote sekmesi) kurar.
    func installBetterDisplay(completion: @escaping (String?) -> Void) {
        queue.async {
            let err = BetterDisplayInstaller.isInstalled ? nil : self.installer.installSync()
            if err == nil { self.display.ensureBetterDisplayRunning() }
            DispatchQueue.main.async { completion(err) }
        }
    }

    /// İstenen monitör durumunu yeniden uygular (uyanma / ekran yeniden yapılandırması / açılış).
    /// Remote/Uyku'da fiziksel monitörleri ASLA açmaz; Masaüstü'nde yalnızca istenen durumu "açık" olanları açar.
    func reconcile(mode: WorkMode, applyBrightness: Bool, reason: String, completion: @escaping ([String]) -> Void) {
        queue.async {
            let notes = self.display.reconcileMonitors(mode: mode, applyBrightness: applyBrightness)
            if !notes.isEmpty { Log.info("Uzlaştırma (\(reason)): \(notes.joined(separator: "; "))") }
            DispatchQueue.main.async { completion(notes) }
        }
    }

    func adoptScreenSharingDisplay() {
        queue.async { _ = self.display.adoptScreenSharingDisplay() }
    }

    /// Monitör kartları için anlık görüntü.
    func monitorSnapshot(completion: @escaping ([MonitorSnapshot]) -> Void) {
        queue.async {
            let list = self.display.monitorSnapshot()
            DispatchQueue.main.async { completion(list) }
        }
    }

    func setMonitorEnabled(key: String, enabled: Bool, mode: WorkMode, completion: @escaping (String?) -> Void) {
        queue.async {
            let note = self.display.setMonitorEnabled(key: key, enabled: enabled, mode: mode)
            DispatchQueue.main.async { completion(note) }
        }
    }

    /// Profil uygular: monitör aç/kapa (istenen durum olarak kaydedilir; Remote/Uyku'da fiziksel monitör
    /// AÇILMAZ, yalnızca kaydedilir) + parlaklık (Masaüstü'nde hemen, diğer modlarda kaydedilir).
    func applyProfile(_ profile: WorkspaceProfile, mode: WorkMode, completion: @escaping ([String]) -> Void) {
        queue.async {
            var notes: [String] = []
            let store = self.display.monitors.store
            for (key, st) in profile.monitors.sorted(by: { $0.key < $1.key }) {
                if store.state(for: key)?.enabled != st.enabled {
                    if let n = self.display.setMonitorEnabled(key: key, enabled: st.enabled, mode: mode) { notes.append(n) }
                }
                if let b = st.brightness {
                    if mode == .desktop && st.enabled {
                        // Kaydırıcıyla aynı yol (birleştirici seri kuyruğu; DDC yazmaları çakışmaz).
                        self.brightness.submit(key: key, value: b, final: true)
                    } else {
                        store.update(key) { $0.brightness = b }
                    }
                }
            }
            Log.info("Profil uygulandı: \(profile.name)\(notes.isEmpty ? "" : " (\(notes.joined(separator: "; ")))")")
            let result = notes
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Kaydırıcıdan: sürüklerken final=false (hız sınırlı), bırakınca final=true.
    func submitBrightness(key: String, value: Double, final: Bool) {
        brightness.submit(key: key, value: value, final: final)
    }

    func setForceSoftware(key: String, _ force: Bool, completion: @escaping () -> Void) {
        queue.async {
            self.display.monitors.setForceSoftware(key: key, force)
            self.brightness.reset(key: key)
            DispatchQueue.main.async { completion() }
        }
    }

    /// Ayarlar > Ekran kontrolü yöntemini değiştirir.
    func setPhysicalMethod(_ m: PhysicalMethod, completion: @escaping () -> Void) {
        queue.async {
            self.display.setMethodPreference(m)
            DispatchQueue.main.async { completion() }
        }
    }

    /// Ayarlar bilgi ızgarası (arka planda toplanır).
    func settingsInfo(completion: @escaping (SettingsInfo) -> Void) {
        queue.async {
            var info = SettingsInfo()
            info.method = self.display.methodDescription
            if BetterDisplayInstaller.isInstalled {
                let version = BetterDisplayInstaller.installedVersion.map { "v\($0)" } ?? L("kurulu")
                let running = self.display.isBetterDisplayRunning()
                info.betterDisplay = running ? L("Hazır (%@)", version) : L("Kurulu, kapalı (%@)", version)
                if running {
                    info.virtualScreen = self.display.isVirtualActive()
                        ? L("Açık")
                        : L("Kapalı")
                } else {
                    info.virtualScreen = L("Kapalı")
                }
            } else {
                info.betterDisplay = L("Kurulu değil")
                info.virtualScreen = L("Sanal ekran aracı gerekli")
            }
            let list = self.display.monitorSnapshot()
            let on = list.filter { $0.isActive }.count
            info.monitors = list.isEmpty ? L("Bağlı monitör yok")
                : L("%@ monitör (%@ açık) · ", list.count, on) + list.map { $0.name }.joined(separator: ", ")
            let pm = Shell.run("/usr/bin/pmset", ["-g"], timeout: 5)
            info.power = pm.succeeded ? PmsetSummary.parse(pm.stdout) : "—"
            let result = info
            DispatchQueue.main.async { completion(result) }
        }
    }

    func repairVirtualScreen() {
        queue.async {
            guard BetterDisplayInstaller.isInstalled else {
                Log.warn("Sanal ekran onarımı: BetterDisplay kurulu değil.")
                return
            }
            self.display.ensureBetterDisplayRunning()
            self.display.ensureVirtualScreen()
            self.display.applyVirtualAspect()
            self.display.configureVirtualScreen()
        }
    }
}
