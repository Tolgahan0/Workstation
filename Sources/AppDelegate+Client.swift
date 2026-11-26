import AppKit

// İstemci (MacBook) ve studio (Mac mini) rolleri. Kullanıcı hiçbir komut yazmaz:
//  - Mac mini: kendini Bonjour'da duyurur (ev adı, Tailscale adı, SSH kullanıcısı, MAC).
//  - MacBook: evdeyken Mac mini'yi bulur ve ~/.config/workstation/config'i kendisi yazar/günceller;
//    "Bağlan" → (dışarıdaysa Tailscale'i açar) → Mac mini'yi bu Mac'in tam ekran alanında Remote'a alır →
//    Ekran Paylaşımı'nı yanıt veren adresle açar → pencere/tam ekran değişince sanal ekranı yeniden uydurur.

final class ClientModel: ObservableObject {
    @Published var isClient = false
    @Published var studioName: String?
    @Published var homeHost: String?
    @Published var awayHost: String?
    @Published var busy = false
    @Published var note: String?
    @Published var tailscaleInstalled = false
    @Published var tailscaleConnected = false
    @Published var fitted: String?

    var onConnect: () -> Void = {}
    var onStartTailscale: () -> Void = {}
}

extension AppDelegate {
    func startRoles() {
        if ClientEnvironment.hasBuiltInDisplay {
            startClientRole()
        } else {
            startStudioRole()
        }
    }

    // MARK: Studio (Mac mini)

    private func startStudioRole() {
        // Remote'tan klavyeyle de çıkabilmek için Giriş İzleme izni: hiç sorulmadıysa açılışta bir kez sistem penceresi.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self, self.currentMode != .remote else { return }
            LocalInputWatcher.ensureAccessRequested(openSettingsIfDenied: false)
            self.panelModel.keyboardInputAccess = LocalInputWatcher.keyboardAccessGranted
        }
        let publish: () -> Void = { [weak self] in
            DispatchQueue.global(qos: .utility).async {
                guard let info = NetworkInfo.fetch() else { return }
                let txt = StudioBeacon.txt(info: info, user: NSUserName(), version: self?.currentAppVersion ?? "")
                DispatchQueue.main.async { self?.advertiser.publish(txt: txt) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: publish)
        // 5 dk'da bir oku, yalnızca değiştiyse yeniden duyur (ör. Tailscale adı değişince MacBook hemen öğrenir).
        let t = Timer(timeInterval: 300, repeats: true) { _ in publish() }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        studioBeaconTimer = t
    }

    // MARK: İstemci (MacBook)

    private func startClientRole() {
        let c = panelModel.client
        c.onConnect = { [weak self] in self?.connectToStudio() }
        c.onStartTailscale = { ClientEnvironment.launchTailscale() }
        c.isClient = true
        loadClientConfig()
        if c.homeHost == nil { c.note = L("Mac mini ev ağında aranıyor: evdeyken Workstation açıkken kendiliğinden bulunur.") }
        browser.onFound = { [weak self] txt in self?.studioFound(txt) }
        browser.start()
        refreshTailscaleState()
        // Workstation oturum açılışında başlar: Tailscale kurulu ama kapalıysa arka planda aç (dışarıda hazır olsun).
        if c.isClient, ClientEnvironment.tailscaleAppURL != nil, !ClientEnvironment.tailscaleRunning {
            ClientEnvironment.launchTailscale()
        }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.refreshTailscaleState()
            self?.adoptScreenSharingSession()
        }
        t.tolerance = 15
        RunLoop.main.add(t, forMode: .common)
        clientStateTimer = t
    }

    private func refreshTailscaleState() {
        let c = panelModel.client
        let installed = ClientEnvironment.tailscaleAppURL != nil
        let connected = ClientEnvironment.tailscaleConnected
        if c.tailscaleInstalled != installed { c.tailscaleInstalled = installed }
        if c.tailscaleConnected != connected { c.tailscaleConnected = connected }
    }

    /// Ekran Paylaşımı uygulamadan değil doğrudan açıldıysa da uydurmayı başlat.
    private func adoptScreenSharingSession() {
        guard fitTimer == nil, !panelModel.client.busy,
              ClientEnvironment.screenSharingWindow() != nil,
              let text = try? String(contentsOfFile: ClientConfig.path, encoding: .utf8) else { return }
        let cfg = ClientConfig.parse(text)
        guard let home = cfg.values["HOST"] else { return }
        let user = cfg.values["SSH_USER"], alt = cfg.values["ALT_HOST"], fitted = panelModel.client.fitted
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let host = ClientEnvironment.tcpReachable(home, port: 22, timeout: 2) ? home : (alt ?? home)
            DispatchQueue.main.async {
                guard let self = self, self.fitTimer == nil else { return }
                Log.info("İstemci: açık Ekran Paylaşımı oturumu bulundu, ekran uydurma izleniyor (\(host))")
                self.startFitWatcher(host: host, user: user, initial: fitted)
            }
        }
    }

    private func loadClientConfig() {
        let c = panelModel.client
        guard let text = try? String(contentsOfFile: ClientConfig.path, encoding: .utf8) else { return }
        let cfg = ClientConfig.parse(text)
        if let h = cfg.values["HOST"] {
            c.isClient = true
            c.homeHost = h
            c.awayHost = cfg.values["ALT_HOST"]
        }
    }

    private func studioFound(_ txt: [String: String]) {
        guard let found = StudioBeacon.config(fromTXT: txt) else { return }
        let path = ClientConfig.path
        var cfg = ClientConfig.parse((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
        let changed = cfg.merge(found, overwrite: ["ALT_HOST", "MAC", "BROADCAST", "SSH_USER"])
        if changed {
            do {
                try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try cfg.serialized(header: "Workstation uygulaması yazdı (Mac mini'nin ev ağı duyurusundan, \(Date()))")
                    .write(toFile: path, atomically: true, encoding: .utf8)
                Log.info("İstemci: Mac mini bulundu ve kaydedildi (ev \(found["HOST"] ?? "?"), dışarıdan \(found["ALT_HOST"] ?? "Tailscale yok"))")
            } catch {
                Log.warn("İstemci yapılandırması yazılamadı: \(error.localizedDescription)")
            }
        }
        let c = panelModel.client
        c.isClient = true
        if c.homeHost == nil { c.note = nil }
        c.studioName = txt["host"]
        c.homeHost = cfg.values["HOST"]
        c.awayHost = cfg.values["ALT_HOST"]
    }

    // MARK: Bağlan

    func connectToStudio() {
        let c = panelModel.client
        guard !c.busy else { return }
        c.busy = true
        c.note = L("Bağlanılıyor…")
        let script = Bundle.main.bundlePath + "/Contents/Resources/bin/workstation-connect"
        let geo = ClientEnvironment.screenGeometry()
        let res = ClientGeometry.fullscreenTarget(screenWidth: geo.w, screenHeight: geo.h, safeTop: geo.safeTop)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = (try? String(contentsOfFile: ClientConfig.path, encoding: .utf8)) ?? ""
            let cfg = ClientConfig.parse(text)
            let home = cfg.values["HOST"] ?? "studio"
            var target = home
            if !ClientEnvironment.tcpReachable(home, port: 22, timeout: 2) {
                // Evde değiliz: Tailscale gerekli.
                if !ClientEnvironment.tailscaleConnected {
                    DispatchQueue.main.async { c.note = L("Dışarıdasın: Tailscale açılıyor…"); ClientEnvironment.launchTailscale() }
                    _ = pollUntil(timeout: 25, interval: 1) { ClientEnvironment.tailscaleConnected }
                }
                if let alt = cfg.values["ALT_HOST"] { target = alt }
            }
            Log.info("İstemci: bağlanılıyor (\(target), görüntü alanı \(res))")
            let r = Shell.run("/bin/zsh", [script, "--res", res], timeout: 180)
            let ok = r.succeeded
            if !ok { Log.warn("workstation-connect: \(r.stderr.isEmpty ? r.stdout : r.stderr)") }
            DispatchQueue.main.async {
                guard let self = self else { return }
                c.busy = false
                self.refreshTailscaleState()
                if ok {
                    c.note = L("Bağlandı. Pencere ya da tam ekran değişince ekran kendiliğinden uyar.")
                    c.fitted = res
                    self.startFitWatcher(host: target, user: cfg.values["SSH_USER"], initial: res)
                } else {
                    let last = (r.stderr.isEmpty ? r.stdout : r.stderr).split(separator: "\n").last.map(String.init) ?? ""
                    c.note = L("Bağlanılamadı: %@", last.isEmpty ? L("ayrıntı günlükte") : last)
                    if !ClientEnvironment.tailscaleConnected && c.tailscaleInstalled {
                        c.note = (c.note ?? "") + " " + L("Tailscale bağlı değil.")
                    }
                }
            }
        }
    }

    /// Ekran Paylaşımı penceresini izler (2 sn; yalnızca uygulama açıkken). Tam ekran ya da ekranı dolduran pencerede
    /// görüntü alanı değişip 2 ölçüm boyunca sabit kalırsa Mac mini'ye `workstation://fit` gönderilir.
    private func startFitWatcher(host: String, user: String?, initial: String?) {
        fitTimer?.invalidate()
        var last: String? = initial
        var candidate: String?
        var stableTicks = 0
        var missing = 0
        var inFlight = false
        var lastSent = Date.distantPast
        let sshTarget = (user.map { host.contains("@") ? host : "\($0)@\(host)" }) ?? host
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            guard let win = ClientEnvironment.screenSharingWindow() else {
                missing += 1
                if missing > 30 { timer.invalidate(); self.fitTimer = nil; Log.info("İstemci: Ekran Paylaşımı kapandı, uydurma durdu") }
                return
            }
            missing = 0
            let geo = ClientEnvironment.screenGeometry(containing: win)
            // Pencere kipinde de uydurulur (yan bantlar pencere oranı ≠ uzak ekran oranı yüzünden). Döngü olmasın diye:
            // ölçü 2 kez sabit kalmalı, oran belirgin değişmeli ve en fazla 4 sn'de bir istek gider.
            guard win.w >= 600, Date().timeIntervalSince(lastSent) >= 4,
                  let want = ClientGeometry.target(window: win, screen: (geo.w, geo.h), safeTop: geo.safeTop) else { return }
            if want == candidate { stableTicks += 1 } else { candidate = want; stableTicks = 0 }
            guard stableTicks >= 1, !inFlight, ClientGeometry.differsEnough(last, want) else { return }
            inFlight = true
            lastSent = Date()
            last = want
            Log.info("İstemci: Ekran Paylaşımı alanı \(want) → Mac mini sanal ekranı uyduruluyor")
            DispatchQueue.global(qos: .utility).async {
                let r = Shell.run("/usr/bin/ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", sshTarget,
                                                   "/usr/bin/open -g 'workstation://fit?res=\(want)'"], timeout: 15)
                DispatchQueue.main.async {
                    inFlight = false
                    if r.succeeded { self.panelModel.client.fitted = want } else { Log.warn("Uydurma isteği gönderilemedi: \(r.stderr)") }
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        fitTimer = t
    }

    /// İstemci rolünde güncelleme kendiliğinden kurulur: kullanıcı 5 dk'dır boştayken ve Ekran Paylaşımı açık değilken.
    func clientAutoInstallAllowed() -> Bool {
        guard panelModel.client.isClient else { return false }
        let busy = !NSRunningApplication.runningApplications(withBundleIdentifier: ClientEnvironment.screenSharingBundleID).isEmpty
        return !busy && ClientEnvironment.idleSeconds >= 300
    }
}
