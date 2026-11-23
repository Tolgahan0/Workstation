import Cocoa
import SwiftUI
import Darwin

// MARK: - Ekran yeniden yapılandırma geri çağrısı (C)

/// CGDisplayRegisterReconfigurationCallback için bağlam yakalamayan C geri çağrısı.
private func displayReconfigurationCallback(_ display: CGDirectDisplayID,
                                            _ flags: CGDisplayChangeSummaryFlags,
                                            _ userInfo: UnsafeMutableRawPointer?) {
    if flags.contains(.beginConfigurationFlag) { return }
    DispatchQueue.main.async {
        (NSApp.delegate as? AppDelegate)?.displaysReconfigured(display: display, flags: flags)
    }
}

// MARK: - Uygulama

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    /// Popover ve içeriği yalnızca açıkken var olur (RAM için).
    var popover: NSPopover?
    let panelModel = PanelModel()
    private let logWindow = LogWindowController()
    /// Simge üzerindeki renkli mod noktası (simgenin kendisi şablon/tek renk kalır).
    private var badgeView: StatusBadgeView?

    let controller = ModeController()
    /// Uyku / Remote öncesi geri sayım (HUD). Yalnızca sayarken zamanlayıcı vardır.
    let countdown = Countdown()
    /// Araçlar → fan denetimi. Okuma yalnızca panel açık + Araçlar sekmesi görünürken.
    let fans = FanController()
    private var fanPollTimer: Timer?
    /// Otomatik mod geçişi: yalnızca ayar açıkken 10 sn'lik hafif süreç taraması.
    var autoSwitchTimer: Timer?
    var autoEngine = AutoSwitchEngine()
    var autoSettings = AutoSwitchSettings.load()
    /// Zamanlanmış modlar: tek bir zamanlayıcı, bir sonraki tetiklenme anına kurulur (yoklama yok).
    var scheduleTimer: Timer?
    /// Remote'ta ses kapatma (Ayarlar, varsayılan kapalı).
    let audio = AudioControl()
    /// Tools → sistem istatistikleri (yalnızca Tools görünürken örneklenir) ve "Uyanık tut".
    let statsSampler = SystemStatsSampler()
    let statsQueue = DispatchQueue(label: "com.tolgahanayaz.workstationmode.stats", qos: .utility)
    let keepAwake = KeepAwake()
    /// Yerel bildirimler (aşırı ısınma, disk, beklenmedik kapanma).
    let notifier = Notifier()
    var notifySettings = NotificationSettings.load()
    var sigtermSource: DispatchSourceSignal?
    // Geliştirici Temizleyici
    var cleanerCancel: CancelToken?
    var cleanerTimer: Timer?
    var cleanerSpaceTimer: Timer?
    let cleanerQueue = DispatchQueue(label: "com.tolgahanayaz.workstationmode.cleaner", qos: .utility)
    var scheduleSettings = ScheduleSettings.load()
    var lastScheduleCheck = Date()

    private(set) var currentMode: WorkMode = .desktop
    var isTransitioning = false
    var countdownActive = false
    private var sleepModeEnteredAt = Date.distantPast
    private var pendingLaunch: (WorkMode, String?)?
    var pendingRoutes: [URLRoute] = []
    var didFinishLaunching = false
    private var lastError: String?
    /// Uyku modunda fare/klavye girdisini yakalayıp Masaüstü'ne dönmek için global izleyici (yalnızca Uyku'da).
    private var sleepInputMonitor: Any?

    /// Uzlaştırma zamanlaması (uyanma / yeniden yapılandırma sonrası 1-3-6 sn yeniden deneme). Olay güdümlü;
    /// boştayken hiçbir zamanlayıcı çalışmaz.
    private var reconcileItems: [DispatchWorkItem] = []
    /// Kendi yaptığımız ekran değişiklikleri sürerken / bittikten sonraki 3 sn boyunca macOS'un
    /// yeniden yapılandırma geri çağrıları yok sayılır (aksi hâlde flaş anındaki geçici durumu
    /// "düzeltmeye" çalışıp ikinci bir flaşa yol açarız).
    private var ownChangeInProgress = 0
    private var suppressCallbacksUntil = Date.distantPast
    /// Her kullanıcı değişikliğinde artar; eski zamanlanmış uzlaştırmalar kendini iptal eder.
    private var changeGeneration = 0
    private static let callbackQuietPeriod: TimeInterval = 3
    private var pendingBrightnessReapply = false

    // MARK: Yaşam döngüsü

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("WorkstationMode başlatıldı (pid \(ProcessInfo.processInfo.processIdentifier)).")
        let unexpectedExit = CleanExit.checkAndArm()
        installTerminationSignalHandler()
        currentMode = WorkMode(rawValue: UserDefaults.standard.string(forKey: currentModeKey) ?? "") ?? .desktop

        setupStatusItem()
        wirePanelModel()
        wireCleaner()
        registerObservers()
        updateUI()

        controller.installer.onProgress = { [weak self] progress in
            guard let self = self else { return }
            self.panelModel.installProgress = progress
            if progress == .done { self.panelModel.bdInstalled = true }
        }

        // Fan: önceki oturum manuel modda çöktüyse reset; Uyku modunda değilsek tercih edilen modu uygula.
        fans.onWatchdog = { [weak self] temp in
            guard let self = self else { return }
            self.panelModel.fanNote = "Mac çok ısındı (\(Int(temp)) °C), fanlar güvenlik için tam hıza alındı."
            self.notifyOverheat(temp, extra: "Fanlar tam hıza alındı.")
            self.refreshFanStatus()
        }
        fans.launchRecovery(reapply: currentMode != .sleep)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self = self else { return }
            if unexpectedExit && self.notifySettings.unexpectedExit {
                Log.warn("Önceki oturum beklenmedik şekilde bitti (temiz çıkış bayrağı yok)")
                self.notifier.notify(kind: "unexpectedExit", title: "Workstation beklenmedik şekilde kapanmıştı",
                                     body: "Uygulama ya da Mac düzgün kapanmamış (elektrik kesintisi olabilir). Her şey normale döndürüldü.")
            }
            self.checkDiskSpace()
            self.configureCleanerAuto()
            self.cleanerSpaceCheck(reason: "açılış")
        }
        panelModel.fanMode = fans.preferredMode

        controller.prepare { [weak self] installed, cliOK in
            guard let self = self else { return }
            self.panelModel.bdInstalled = installed
            if installed && !cliOK { self.showCLIWarning() }
            self.didFinishLaunching = true
            self.configureAutoSwitch()
            let queued = self.pendingRoutes
            self.pendingRoutes = []
            for r in queued { self.dispatchRoute(r, source: "açılış URL'si") }
            self.lastScheduleCheck = Date()
            self.rescheduleModes(catchUp: false)
            if let pending = self.pendingLaunch {
                self.pendingLaunch = nil
                self.requestMode(pending.0, source: "açılış URL'si", resolution: pending.1)
            } else {
                self.restoreModeAtLaunch()
            }
        }
    }

    /// Remote: yeniden uygulanır · Uyku: Masaüstü'ne dönülür · Masaüstü: monitör başına istenen durum uygulanır.
    private func restoreModeAtLaunch() {
        switch currentMode {
        case .remote: setMode(.remote, source: "açılışta geri yükleme")
        case .sleep: setMode(.desktop, source: "açılış (uyku modundan dönüş)")
        case .desktop: scheduleReconcile(reason: "açılış", applyBrightness: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info("WorkstationMode kapanıyor (mod: \(currentMode.rawValue)). Ekran durumu değiştirilmedi.")
        // Güvenlik: fanlar asla manuel modda bırakılmaz (tercih saklı kalır, açılışta yeniden uygulanır).
        fans.resetSync(reason: "uygulama kapanıyor")
        CleanExit.markClean()
    }

    // MARK: Menü çubuğu + popover

    private func setupStatusItem() {
        // Şablon (tek renk) Mac mini: menü çubuğu kalınlığına göre en büyük boy, minimum kenar boşluğu.
        let thickness = NSStatusBar.system.thickness
        let image = IconRenderer.menuBarImage(thickness: thickness)
        statusItem = NSStatusBar.system.statusItem(withLength: ceil(image.size.width) + 4)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imageScaling = .scaleNone
            button.imagePosition = .imageOnly
            button.image = image
            let dot: CGFloat = 8
            // Sağ alt köşe (düğme koordinatları ters çevrilmiş olabilir).
            let barHeight = max(button.bounds.height, thickness)
            let y: CGFloat = button.isFlipped ? barHeight - dot - 1.5 : 1.5
            let badge = StatusBadgeView(frame: NSRect(x: ceil(image.size.width) + 4 - dot - 0.5, y: y, width: dot, height: dot))
            badge.color = nil
            button.addSubview(badge)
            badgeView = badge
        }
    }

    private func wirePanelModel() {
        let m = panelModel
        m.onStart = { [weak self] mode in
            guard let self = self else { return }
            if mode != .desktop { self.popover?.performClose(nil) }
            self.requestMode(mode, source: "panel")
        }
        m.onToggleMonitor = { [weak self] key, on in self?.toggleMonitor(key: key, enabled: on) }
        m.onBrightness = { [weak self] key, value, final in
            self?.controller.submitBrightness(key: key, value: value, final: final)
        }
        m.onForceSoftware = { [weak self] key, force in
            self?.controller.setForceSoftware(key: key, force) { [weak self] in self?.refreshMonitors() }
        }
        m.onRescan = { [weak self] in self?.refreshMonitors() }
        m.onRepairVirtual = { [weak self] in self?.controller.repairVirtualScreen() }
        m.onOpenLog = { [weak self] in
            self?.popover?.performClose(nil)
            self?.logWindow.show()
        }
        m.onInstallBD = { [weak self] in
            self?.controller.installBetterDisplay { [weak self] err in
                guard let self = self else { return }
                self.panelModel.bdInstalled = BetterDisplayInstaller.isInstalled
                if let e = err { self.panelModel.statusNote = "Sanal ekran aracı kurulamadı. Ayrıntı günlükte."; Log.warn("BetterDisplay: \(e)") }
            }
        }
        m.onQuit = { NSApp.terminate(nil) }
        m.onSelectMethod = { [weak self] method in
            guard let self = self else { return }
            self.panelModel.methodPreference = method
            self.controller.setPhysicalMethod(method) { [weak self] in self?.refreshSettingsInfo() }
        }
        m.onToolsVisible = { [weak self] visible in
            guard let self = self else { return }
            if visible { self.startFanPolling(); self.refreshCleanerDisk() } else { self.stopFanPolling() }
        }
        m.onRemoteShown = { [weak self] in self?.refreshNetInfo() }
        m.onApplyProfile = { [weak self] id in
            guard let self = self, let p = self.panelModel.profiles.first(where: { $0.id == id }) else { return }
            self.applyProfile(p, source: "panel")
        }
        m.onSaveProfile = { [weak self] name in self?.saveProfile(named: name) }
        m.onKeepAwake = { [weak self] on, duration in
            guard let self = self else { return }
            self.panelModel.keepAwakeDuration = duration
            if on { self.keepAwake.enable(seconds: duration.seconds) } else { self.keepAwake.disable() }
        }
        keepAwake.onChange = { [weak self] in
            guard let self = self else { return }
            self.panelModel.keepAwakeOn = self.keepAwake.isOn
            self.panelModel.keepAwakeUntil = self.keepAwake.until
        }
        m.onNotifySettings = { [weak self] settings in
            guard let self = self else { return }
            self.notifySettings = settings
            self.panelModel.notifySettings = settings
            settings.save()
        }
        m.onMuteInRemote = { [weak self] on in
            guard let self = self else { return }
            AudioControl.enabled = on
            self.panelModel.muteInRemote = on
            if on && self.currentMode == .remote { self.audio.muteForRemote() }
            if !on { self.audio.restoreIfNeeded() }
        }
        m.onDeleteProfile = { [weak self] id in
            guard let self = self else { return }
            var list = self.panelModel.profiles
            list.removeAll { $0.id == id }
            ProfileStore.save(list)
            self.panelModel.profiles = list
        }
        m.onSchedule = { [weak self] settings in
            guard let self = self else { return }
            let wakeChanged = settings.wakeEnabled != self.scheduleSettings.wakeEnabled
                || (settings.wakeEnabled && ScheduleEngine.pmsetRepeatArgs(rules: settings.rules)
                    != ScheduleEngine.pmsetRepeatArgs(rules: self.scheduleSettings.rules))
            self.panelModel.schedule = settings
            self.scheduleSettings = settings
            settings.save()
            self.rescheduleModes(catchUp: false)
            if wakeChanged { self.applyScheduledWake() }
        }
        m.onAutoSwitch = { [weak self] settings in
            guard let self = self else { return }
            self.panelModel.autoSwitch = settings
            self.autoSettings = settings
            settings.save()
            self.configureAutoSwitch()
        }
        m.onFanMode = { [weak self] mode in
            guard let self = self else { return }
            self.panelModel.fanMode = mode
            self.panelModel.fanApplying = true
            self.panelModel.fanNote = nil
            self.fans.apply(mode, reason: "kullanıcı") { [weak self] err in
                guard let self = self else { return }
                self.panelModel.fanApplying = false
                if let e = err {
                    self.panelModel.fanNote = "Fan ayarı yapılamadı, Mac'in kendi ayarına dönüldü."; Log.warn("Fan: \(e)")
                }
                self.refreshFanStatus()
            }
        }
        m.onSettingsShown = { [weak self] visible in
            guard let self = self else { return }
            if visible {
                self.refreshSettingsInfo()
                self.startMemoryUpdates()
            } else {
                self.stopMemoryUpdates()
            }
        }

        // Kaydırıcı sonucu (yalnızca yöntem değiştiyse UI'ı güncelle → gereksiz yeniden çizim yok)
        controller.brightness.onResult = { [weak self] key, method in
            guard let self = self, let i = self.panelModel.monitors.firstIndex(where: { $0.key == key }) else { return }
            if self.panelModel.monitors[i].brightnessMethod != method, method != .unknown {
                self.refreshMonitors()
            }
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if let p = popover, p.isShown {
            p.performClose(sender)
            return
        }
        showPopover(relativeTo: sender)
    }

    private func showPopover(relativeTo button: NSStatusBarButton) {
        let p = NSPopover()
        p.behavior = .transient
        p.animates = false
        p.appearance = NSAppearance(named: .darkAqua)
        p.delegate = self
        let host = NSHostingController(rootView: PanelView(model: panelModel))
        host.sizingOptions = [.preferredContentSize]
        p.contentViewController = host
        popover = p

        panelModel.page = .main
        panelModel.countdownSeconds = CountdownSettings.seconds
        if panelModel.selectedTab != .tools { panelModel.selectedTab = PanelTab(currentMode) }
        panelModel.panelOpen = true
        panelModel.fanMode = fans.preferredMode
        panelModel.fanHelperInstalled = FanController.helperInstalled
        panelModel.presetID = RemoteResolution.selectedPresetID
        panelModel.bdInstalled = BetterDisplayInstaller.isInstalled
        panelModel.methodPreference = PhysicalMethod.preference
        updateUI()
        refreshMonitors()

        NSApp.activate(ignoringOtherApps: true)
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        p.contentViewController?.view.window?.makeKey()
        if panelModel.toolsVisible { startFanPolling() }
        if panelModel.selectedTab == .remote { refreshNetInfo() }
    }

    /// Wake-on-LAN bilgisi: Remote sekmesi açılınca okunur, 5 dk önbelleklenir (boşta okuma yok).
    private var netInfoFetchedAt = Date.distantPast
    private func refreshNetInfo() {
        guard Date().timeIntervalSince(netInfoFetchedAt) > 300 || panelModel.netInfo == nil else { return }
        netInfoFetchedAt = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let info = NetworkInfo.fetch()
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let i = info {
                    self.panelModel.netInfo = i
                } else {
                    // Okunamadı: boş bilgi göster ("—"), bir sonraki açılışta yeniden dene.
                    self.panelModel.netInfo = NetworkInfo()
                    self.netInfoFetchedAt = .distantPast
                }
            }
        }
    }

    /// Popover kapanınca SwiftUI hiyerarşisini serbest bırak.
    func popoverDidClose(_ notification: Notification) {
        stopMemoryUpdates()
        stopFanPolling()
        panelModel.panelOpen = false
        popover?.contentViewController = nil
        popover?.delegate = nil
        popover = nil
        panelModel.monitors = []
        panelModel.page = .main
    }

    // MARK: Araçlar → fan okuma (yalnızca görünürken)

    private func startFanPolling() {
        guard popover != nil, fanPollTimer == nil else { return }
        refreshFanStatus()
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.refreshFanStatus() }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        fanPollTimer = t
    }

    private func stopFanPolling() {
        fanPollTimer?.invalidate()
        fanPollTimer = nil
    }

    private func refreshFanStatus() {
        guard popover != nil else { return }
        refreshSystemStats()
        fans.readStatus { [weak self] status in
            guard let self = self, self.popover != nil else { return }
            if self.panelModel.fanStatus != status { self.panelModel.fanStatus = status }
            if let t = NotificationPolicy.isOverheat(cpu: status.cpuTemp, gpu: status.gpuTemp) { self.notifyOverheat(t, extra: nil) }
        }
    }

    // MARK: Ayarlar bilgi ızgarası

    /// Bellek (phys_footprint) yalnızca Ayarlar sayfası açıkken 2 sn'de bir güncellenir.
    private var memoryTimer: Timer?

    private func refreshSettingsInfo() {
        guard popover != nil else { return }
        controller.settingsInfo { [weak self] info in
            guard let self = self, self.popover != nil else { return }
            if self.panelModel.settingsInfo != info { self.panelModel.settingsInfo = info }
        }
    }

    private func startMemoryUpdates() {
        stopMemoryUpdates()
        panelModel.memoryText = MemoryFootprint.text
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let text = MemoryFootprint.text
            if self.panelModel.memoryText != text { self.panelModel.memoryText = text }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        memoryTimer = t
    }

    private func stopMemoryUpdates() {
        memoryTimer?.invalidate()
        memoryTimer = nil
    }

    func refreshMonitors() {
        guard popover != nil else { return }
        panelModel.loadingMonitors = true
        controller.monitorSnapshot { [weak self] list in
            guard let self = self else { return }
            if self.panelModel.monitors != list { self.panelModel.monitors = list }
            self.panelModel.loadingMonitors = false
        }
    }

    /// Uzantı dosyalarından (profil uygulama) kendi değişikliğimizi işaretlemek için.
    func beginOwnChangeForFeature() { beginOwnChange() }
    func endOwnChangeForFeature() { endOwnChange() }

    private func beginOwnChange() {
        ownChangeInProgress += 1
        changeGeneration += 1
        cancelScheduledReconcile()
    }

    private func endOwnChange() {
        ownChangeInProgress = max(0, ownChangeInProgress - 1)
        suppressCallbacksUntil = Date().addingTimeInterval(Self.callbackQuietPeriod)
    }

    private func toggleMonitor(key: String, enabled: Bool) {
        if let i = panelModel.monitors.firstIndex(where: { $0.key == key }) {
            panelModel.monitors[i].desiredEnabled = enabled
        }
        beginOwnChange()
        controller.setMonitorEnabled(key: key, enabled: enabled, mode: currentMode) { [weak self] note in
            guard let self = self else { return }
            self.endOwnChange()
            self.panelModel.statusNote = note
            if let n = note { Log.info("Monitör aç/kapa: \(n)") }
            self.refreshMonitors()
        }
    }

    private func updateUI() {
        if let button = statusItem?.button {
            badgeView?.color = IconRenderer.badgeColor(mode: currentMode, busy: isTransitioning || countdownActive)
            button.toolTip = "WorkstationMode: \(currentMode.title)\(lastError.map { " – ⚠︎ \($0)" } ?? "")"
        }
        if panelModel.mode != currentMode { panelModel.mode = currentMode }
        if panelModel.transitioning != isTransitioning { panelModel.transitioning = isTransitioning }
        if let err = lastError, panelModel.statusNote != err { panelModel.statusNote = err }
    }

    // MARK: Mod geçişi

    /// Mod isteği giriş noktası (panel, URL, CLI). Uyku ve Remote'dan önce geri sayım gösterilir
    /// (Ayarlar > Geri sayım, varsayılan 3 sn, 0 = kapalı); Masaüstü hemen uygulanır.
    func requestMode(_ mode: WorkMode, source: String, resolution: String? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        if countdown.isRunning {
            Log.info("Süren geri sayım yeni istek nedeniyle iptal edildi (\(source)).")
            countdown.cancel()
        }
        let seconds = CountdownSettings.seconds
        guard mode != .desktop, seconds > 0 else {
            setMode(mode, source: source, resolution: resolution)
            return
        }
        Log.info("Geri sayım başladı: \(mode.rawValue) (\(seconds) sn, kaynak: \(source))")
        popover?.performClose(nil)
        countdownActive = true
        updateUI()
        countdown.start(mode: mode, seconds: seconds, interactive: source == "panel") { [weak self] proceed in
            guard let self = self else { return }
            self.countdownActive = false
            if proceed {
                self.setMode(mode, source: source, resolution: resolution)
            } else {
                Log.info("Geri sayım iptal edildi: \(mode.rawValue)")
                self.updateUI()
            }
        }
    }

    private func setMode(_ mode: WorkMode, source: String, resolution: String? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        Log.info("Mod uygulanıyor: \(mode.rawValue)\(resolution.map { " (\($0))" } ?? "") (kaynak: \(source), önceki: \(currentMode.rawValue))")
        beginOwnChange()
        let previous = currentMode
        currentMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: currentModeKey)
        // Fan güvenliği: Uyku'ya geçerken otomatiğe dön; Uyku'dan çıkınca tercih edilen modu geri yükle.
        if mode == .sleep {
            fans.resetSync(reason: "Uyku moduna geçiş")
        } else if previous == .sleep {
            fans.reapplyPreferred(reason: "Uyku modundan çıkış")
        }
        // Ses: Remote'ta (ayar açıksa) sessize al; Masaüstü'nde yalnızca bizim kapattığımızı geri aç.
        if mode == .remote && AudioControl.enabled {
            audio.muteForRemote()
        } else if mode == .desktop {
            audio.restoreIfNeeded()
        }
        isTransitioning = true
        lastError = nil
        panelModel.statusNote = nil
        stopSleepInputMonitor()
        updateUI()

        controller.apply(mode, resolution: resolution) { [weak self] error in
            guard let self = self else { return }
            self.endOwnChange()
            if mode == .sleep {
                self.sleepModeEnteredAt = Date()
                self.startSleepInputMonitor()
            }
            if self.currentMode == mode {
                self.isTransitioning = false
                self.lastError = error
                if mode != .sleep {
                    self.scheduleReconcile(reason: "\(mode.rawValue) sonrası doğrulama", applyBrightness: mode == .desktop,
                                           delays: [Self.callbackQuietPeriod + 0.5, 8])
                }
            }
            self.panelModel.bdInstalled = BetterDisplayInstaller.isInstalled
            self.updateUI()
            self.refreshMonitors()
            Log.info("Mod uygulandı: \(mode.rawValue)\(error.map { " (uyarı: \($0))" } ?? "")")
        }
    }

    // MARK: İstenen monitör durumunu yeniden uygulama (kalıcılık)

    func scheduleReconcile(reason: String, applyBrightness: Bool, delays: [Double] = [1, 3, 6]) {
        guard didFinishLaunching else { return }
        pendingBrightnessReapply = pendingBrightnessReapply || applyBrightness
        cancelScheduledReconcile(keepBrightnessFlag: true)
        let generation = changeGeneration
        for (i, d) in delays.enumerated() {
            let isLast = i == delays.count - 1
            let item = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                guard generation == self.changeGeneration, self.ownChangeInProgress == 0 else {
                    Log.info("Zamanlanmış uzlaştırma atlandı (yeni kullanıcı değişikliği var): \(reason)")
                    return
                }
                self.runReconcile(reason: reason, isLast: isLast)
            }
            reconcileItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: item)
        }
    }

    private func cancelScheduledReconcile(keepBrightnessFlag: Bool = false) {
        reconcileItems.forEach { $0.cancel() }
        reconcileItems.removeAll()
        if !keepBrightnessFlag { pendingBrightnessReapply = false }
    }

    private func runReconcile(reason: String, isLast: Bool) {
        guard !isTransitioning else { return }
        let brightness = pendingBrightnessReapply
        if isLast {
            pendingBrightnessReapply = false
            reconcileItems.removeAll()
        }
        controller.reconcile(mode: currentMode, applyBrightness: brightness, reason: reason) { [weak self] notes in
            guard let self = self else { return }
            if !notes.isEmpty { self.panelModel.statusNote = notes.joined(separator: " · ") }
            self.refreshMonitors()
        }
    }

    func displaysReconfigured(display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        if ownChangeInProgress > 0 || isTransitioning || Date() < suppressCallbacksUntil {
            // Kendi değişikliğimizin yan etkisi: dokunma (ikinci flaşı önler).
            return
        }
        let added = flags.contains(.addFlag) || flags.contains(.enabledFlag)
        Log.info("Ekran yapılandırması değişti (displayID \(display), bayraklar 0x\(String(flags.rawValue, radix: 16))) → 3,5 sn sonra denetlenecek")
        scheduleReconcile(reason: "ekran yapılandırması değişti (\(display))", applyBrightness: added,
                          delays: [Self.callbackQuietPeriod + 0.5, 8])
    }

    // MARK: Uyanma / ekran olayları

    private func startSleepInputMonitor() {
        stopSleepInputMonitor()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self, self.currentMode == .sleep, self.sleepInputMonitor == nil else { return }
            self.sleepInputMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]
            ) { [weak self] _ in
                self?.handleWake(kind: "fare/klavye girdisi")
            }
        }
    }

    private func stopSleepInputMonitor() {
        if let m = sleepInputMonitor {
            NSEvent.removeMonitor(m)
            sleepInputMonitor = nil
        }
    }

    private func registerObservers() {
        let wsnc = NSWorkspace.shared.notificationCenter
        wsnc.addObserver(self, selector: #selector(systemDidWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        wsnc.addObserver(self, selector: #selector(screensDidWake(_:)), name: NSWorkspace.screensDidWakeNotification, object: nil)
        wsnc.addObserver(self, selector: #selector(systemWillSleep(_:)), name: NSWorkspace.willSleepNotification, object: nil)
        // Zamanlama: saat / saat dilimi değişince yeniden kur.
        NotificationCenter.default.addObserver(self, selector: #selector(clockChanged(_:)), name: .NSSystemClockDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(clockChanged(_:)), name: .NSSystemTimeZoneDidChange, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(distributedSetMode(_:)),
                                                            name: setModeNotification, object: nil,
                                                            suspensionBehavior: .deliverImmediately)
        let err = CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, nil)
        if err != .success { Log.error("CGDisplayRegisterReconfigurationCallback → \(err.rawValue)") }
    }

    @objc private func systemWillSleep(_ note: Notification) {
        Log.info("NSWorkspace.willSleepNotification → fanlar otomatiğe")
        fans.resetSync(reason: "sistem uykuya geçiyor")
    }

    @objc private func clockChanged(_ note: Notification) {
        Log.info("Sistem saati/saat dilimi değişti → zamanlama yeniden kuruluyor")
        lastScheduleCheck = Date()
        rescheduleModes(catchUp: false)
    }

    @objc private func systemDidWake(_ note: Notification) {
        Log.info("NSWorkspace.didWakeNotification (mod: \(currentMode.rawValue))")
        // Uykuda kaçırılan zamanlamalar: yalnızca son 2 dk içindekiler (ör. pmset ile planlı uyanma) çalıştırılır.
        lastScheduleCheck = max(lastScheduleCheck, Date().addingTimeInterval(-120))
        rescheduleModes(catchUp: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.checkDiskSpace()
            self?.configureCleanerAuto()
            self?.cleanerSpaceCheck(reason: "uyanma")
        }
        if currentMode != .sleep {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self = self, self.currentMode != .sleep else { return }
                self.fans.reapplyPreferred(reason: "uyanma")
            }
        }
        handleWake(kind: "sistem")
    }

    @objc private func screensDidWake(_ note: Notification) {
        Log.info("NSWorkspace.screensDidWakeNotification (mod: \(currentMode.rawValue))")
        handleWake(kind: "ekran")
    }

    private func handleWake(kind: String) {
        switch currentMode {
        case .sleep:
            guard !isTransitioning, Date().timeIntervalSince(sleepModeEnteredAt) > 5 else { return }
            setMode(.desktop, source: "\(kind) uyanması")
        case .remote, .desktop:
            scheduleReconcile(reason: "\(kind) uyanması", applyBrightness: true)
        }
    }

    // MARK: URL scheme ve dağıtık bildirim

    /// URL / dağıtık bildirim → URLRoute (bkz. URLRoute.swift).
    @objc func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let str = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }
        guard let route = URLRoute.parse(str, scheme: urlScheme) else {
            Log.error("Bilinmeyen URL: \(str)")
            return
        }
        Log.info("URL alındı: \(str)")
        dispatchRoute(route, source: "URL")
    }

    @objc private func distributedSetMode(_ note: Notification) {
        guard let raw = note.object as? String, let route = URLRoute.parse(raw, scheme: urlScheme) else { return }
        DispatchQueue.main.async { [weak self] in self?.dispatchRoute(route, source: "dağıtık bildirim") }
    }

    /// Açılış bitmeden gelen istekler sıraya alınır.
    func dispatchRoute(_ route: URLRoute, source: String) {
        guard didFinishLaunching else {
            if case .mode(let m, let r) = route { pendingLaunch = (m, r) } else { pendingRoutes.append(route) }
            return
        }
        switch route {
        case .mode(let mode, let res):
            requestMode(mode, source: source, resolution: res)
        case .profile(let name):
            if let p = ProfileStore.find(name, in: ProfileStore.load()) {
                applyProfile(p, source: source)
            } else {
                Log.error("Profil bulunamadı: \(name)")
                panelModel.profileNote = "Profil yok: \(name)"
            }
        case .fan(let mode):
            panelModel.fanMode = mode
            fans.apply(mode, reason: source) { [weak self] err in
                if let e = err { self?.panelModel.fanNote = "Fan ayarı yapılamadı."; Log.warn("Fan: \(e)") }
            }
        case .keepAwake(let on, let seconds):
            if on { keepAwake.enable(seconds: seconds) } else { keepAwake.disable() }
        case .clean(let action):
            switch action {
            case .scan: startCleanerScan(trigger: .url)
            case .auto: runAutoClean(trigger: .url)
            }
        }
    }

    // MARK: Uyarılar

    private func showCLIWarning() {
        let alert = NSAlert()
        alert.messageText = "Sanal ekran aracına bir izin vermen gerekiyor"
        alert.informativeText = """
        Remote'taki sanal ekranı BetterDisplay açıyor. Bir kerelik olarak BetterDisplay'i aç, \
        Ayarlar › Application › Integration bölümünde "CLI" seçeneğini işaretle.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Tamam")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: - Bellek ayak izi (Etkinlik Monitörü'ndeki "Bellek" ile aynı ölçü: phys_footprint)

enum MemoryFootprint {
    static var bytes: UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : nil
    }

    static var text: String {
        guard let b = bytes else { return "—" }
        let mb = Double(b) / 1_048_576
        return String(format: "%.1f MB", mb)
    }
}
