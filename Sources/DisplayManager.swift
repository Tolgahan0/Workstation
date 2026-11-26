import Foundation

/// BetterDisplay CLI'dan okunan tek bir ekran / sanal ekran / grup kaydı.
struct DisplayInfo: Codable, Equatable {
    var name: String
    var tagID: String?
    var displayID: String?
    var uuid: String?
    var deviceType: String
    var originalName: String?
    var productName: String?

    var isVirtualScreen: Bool {
        let t = deviceType.lowercased()
        return t.contains("virtual")
    }

    var isGroup: Bool { deviceType.lowercased().contains("group") }

    /// BetterDisplay'in ekranı seçmesi için kullanılacak CLI parametresi.
    /// tagID bu BetterDisplay kurulumuna özgü ve kalıcıdır; yoksa UUID, en son isim kullanılır.
    var selectorArgument: String {
        if let tag = tagID, !tag.isEmpty { return "-tagID=\(tag)" }
        if let u = uuid, !u.isEmpty { return "-UUID=\(u)" }
        return "-name=\(name)"
    }

    var label: String { tagID.map { "\(name) (tagID \($0))" } ?? name }
}

/// BetterDisplay CLI üzerinden fiziksel ekranları ve `MacBook14Virtual` sanal ekranını yönetir.
final class DisplayManager {
    static let virtualScreenName = "MacBook14Virtual"

    /// Sanal ekran çözünürlüğü (bağlanan Mac'e göre): Remote sekmesindeki ön ayar / istemci isteği.
    /// Varsayılan 14" MacBook Pro: 1512x982 HiDPI.
    static var virtualResolution: String { RemoteResolution.effective(override: resolutionOverride) }

    /// Bu Remote başlatması için istemciden gelen çözünürlük (workstation-connect / ?res=).
    static var resolutionOverride: String?

    /// Sanal ekranın özel çözünürlük listesi: tüm ön ayarlar + yaygın 16:10 / 16:9 değerler.
    static var virtualResolutionList: [String] {
        var list = baseResolutionList
        for r in [virtualResolution, RemoteResolution.lastClientResolution].compactMap({ $0 }) where !list.contains(r) {
            list.insert(r, at: 0)
        }
        return list
    }

    /// Her zaman listede olan modlar (istemciye göre değişmez → uydurma bunlara yuvarlanır).
    static var baseResolutionList: [String] {
        var list = RemotePreset.all.filter { $0.id != "auto" }.map { $0.resolution }
        list += ["1512x945", "1800x1169", "1352x878", "1680x1050", "1440x900", "1920x1200",
                 "1280x800", "1920x1080", "2560x1440", "1280x832", "1440x932"]
        // Çentikli MacBook'larda tam ekran Ekran Paylaşımı'nın kullandığı alan (çentik altı).
        list += ["1470x918", "1710x1068", "1728x1080", "1512x945"]
        // Pencere kipi: her en-boy oranı için bir mod (uydurma isteği bunlara yuvarlanır, ekran yeniden bağlanmaz).
        list += FitGrid.entries
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    /// Oluşturma sırasında kullanılacak en-boy oranı (seçili çözünürlükten; yoksa 16:10).
    static var createAspect: (Int, Int) { RemotePreset.aspect(of: virtualResolution) ?? (16, 10) }

    private let knownPhysicalKey = "knownPhysicalDisplays"
    private let defaults = UserDefaults.standard

    /// Uygulama içinden sürekli görülebilen, son tespit edilen fiziksel ekranlar.
    private(set) var physicalDisplays: [DisplayInfo] = []

    // MARK: - CLI

    /// BetterDisplay'in uygulama paketi içindeki çalıştırılabilir dosyası (CLI olarak da çalışır).
    static let appExecutable = "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"
    /// İsteğe bağlı yardımcı CLI (brew install waydabber/betterdisplay/betterdisplaycli).
    static let companionCLIs = ["/opt/homebrew/bin/betterdisplaycli", "/usr/local/bin/betterdisplaycli"]

    private var cliPath: String {
        if FileManager.default.isExecutableFile(atPath: Self.appExecutable) { return Self.appExecutable }
        for p in Self.companionCLIs where FileManager.default.isExecutableFile(atPath: p) { return p }
        return Self.appExecutable
    }

    @discardableResult
    private func cli(_ args: [String], timeout: TimeInterval = 8, logFailure: Bool = true) -> CommandResult {
        let result = Shell.run(cliPath, args, timeout: timeout)
        if logFailure && !result.succeeded {
            Log.error("BetterDisplay \(args.joined(separator: " ")) → status \(result.status)\(result.timedOut ? " (zaman aşımı)" : "") \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) \(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result
    }

    /// BetterDisplay CLI isteklerini çalışan BetterDisplay uygulaması işler; çalışmıyorsa arka planda başlat.
    func ensureBetterDisplayRunning() {
        let check = Shell.run("/usr/bin/pgrep", ["-x", "BetterDisplay"], timeout: 5)
        if check.succeeded { return }
        Log.info("BetterDisplay çalışmıyor, başlatılıyor…")
        Shell.run("/usr/bin/open", ["-g", "-a", "BetterDisplay"], timeout: 10)
        // Sabit bekleme yok: CLI yanıt verene dek kısa aralıklarla yokla (en fazla ~10 sn).
        let up = pollUntil(timeout: 10, interval: 0.2) {
            Shell.run("/usr/bin/pgrep", ["-x", "BetterDisplay"], timeout: 2).succeeded
                && cli(["get", "-identifiers"], timeout: 2, logFailure: false).succeeded
        }
        if !up { Log.error("BetterDisplay başlatılamadı.") }
    }

    /// CLI erişiminin çalışıp çalışmadığını döndürür.
    func isCLIAvailable() -> Bool {
        let r = cli(["get", "-identifiers"], timeout: 10, logFailure: false)
        let ok = r.succeeded && r.stdout.contains("{")
        cliOKCache = ok
        return ok
    }

    // MARK: - Tespit

    /// `get -identifiers` çıktısını okur ve kayıt listesine çevirir.
    func listAll() -> [DisplayInfo] {
        let r = cli(["get", "-identifiers"], timeout: 15)
        guard r.succeeded else { return [] }
        return Self.parseIdentifiers(r.stdout)
    }

    /// Bağlı fiziksel ekranları bulur (sanal ekranlar, gruplar ve dahili/dummy ekranlar hariç).
    /// Bulunanlar UserDefaults'ta hatırlanır; böylece kapatıldıktan sonra CLI listesinde
    /// görünmeseler bile tekrar açılabilirler.
    @discardableResult
    func refreshPhysicalDisplays() -> [DisplayInfo] {
        let all = listAll()
        let detected = all.filter(Self.isPhysical)
        var merged = loadKnownPhysical()
        for d in detected {
            if let i = merged.firstIndex(where: { Self.sameDevice($0, d) }) {
                merged[i] = d
            } else {
                merged.append(d)
            }
        }
        physicalDisplays = merged
        saveKnownPhysical(merged)
        Log.info("Fiziksel ekranlar (\(detected.count) şu an listede, \(merged.count) bilinen): \(merged.map { $0.label }.joined(separator: ", "))")
        return merged
    }

    /// Bilinen fiziksel ekran listesini sıfırlar ve yeniden tarar (menüdeki "Ekranları Yeniden Tara").
    @discardableResult
    func resetAndRescan() -> [DisplayInfo] {
        defaults.removeObject(forKey: knownPhysicalKey)
        return refreshPhysicalDisplays()
    }

    static func isPhysical(_ d: DisplayInfo) -> Bool {
        let type = d.deviceType.lowercased()
        guard type == "display" else { return false } // VirtualScreen, DisplayGroup, Dummy vb. hariç
        let names = [d.name, d.originalName ?? "", d.productName ?? ""].map { $0.lowercased() }
        if names.contains(where: { $0.contains("built-in") || $0.contains("dummy") }) { return false }
        if d.name == virtualScreenName || d.originalName == virtualScreenName { return false }
        // Kullanıcı tanımlı hariç tutma listesi:
        // defaults write com.tolgahanayaz.workstationmode excludedDisplays -array "Sidecar" "AirPlay"
        let excluded = (UserDefaults.standard.stringArray(forKey: "excludedDisplays") ?? []).map { $0.lowercased() }
        if names.contains(where: { n in excluded.contains(where: { !$0.isEmpty && n.contains($0) }) }) { return false }
        return true
    }

    private static func sameDevice(_ a: DisplayInfo, _ b: DisplayInfo) -> Bool {
        if let ta = a.tagID, let tb = b.tagID, !ta.isEmpty { return ta == tb }
        if let ua = a.uuid, let ub = b.uuid, !ua.isEmpty { return ua == ub }
        return a.name == b.name
    }

    private func loadKnownPhysical() -> [DisplayInfo] {
        guard let data = defaults.data(forKey: knownPhysicalKey),
              let list = try? JSONDecoder().decode([DisplayInfo].self, from: data) else { return [] }
        return list
    }

    private func saveKnownPhysical(_ list: [DisplayInfo]) {
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: knownPhysicalKey) }
    }

    // MARK: - Ayrıştırma

    /// `get -identifiers` çıktısı genellikle virgülle ayrılmış ardışık JSON nesneleridir
    /// (`{...},{...}`); bazı sürümlerde dizi (`[...]`) olabilir. Her iki biçimi de, iç içe
    /// nesneleri ve dizgi içindeki parantezleri hesaba katarak ayrıştırır.
    static func parseIdentifiers(_ text: String) -> [DisplayInfo] {
        var results: [DisplayInfo] = []
        for objectText in topLevelObjects(in: text) {
            guard let data = objectText.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let info = makeInfo(obj) { results.append(info) }
        }
        return results
    }

    /// Metindeki en üst düzey `{ ... }` bloklarını (dizgi içindeki parantezleri yok sayarak) çıkarır.
    static func topLevelObjects(in text: String) -> [String] {
        var objects: [String] = []
        var depth = 0
        var inString = false
        var escaped = false
        var current = ""
        for ch in text {
            if depth > 0 { current.append(ch) }
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"":
                if depth > 0 { inString = true }
            case "{":
                if depth == 0 { current = "{" }
                depth += 1
            case "}":
                if depth > 0 {
                    depth -= 1
                    if depth == 0 { objects.append(current); current = "" }
                }
            default:
                break
            }
        }
        return objects
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    private static func makeInfo(_ obj: [String: Any]) -> DisplayInfo? {
        // Anahtar adlarını büyük/küçük harf duyarsız eşle.
        var lower: [String: Any] = [:]
        for (k, v) in obj { lower[k.lowercased()] = v }
        guard let name = string(lower["name"]) ?? string(lower["originalname"]) else { return nil }
        let type = string(lower["devicetype"]) ?? string(lower["type"]) ?? "Display"
        return DisplayInfo(
            name: name,
            tagID: string(lower["tagid"]),
            displayID: string(lower["displayid"]),
            uuid: string(lower["uuid"]),
            deviceType: type,
            originalName: string(lower["originalname"]),
            productName: string(lower["productname"])
        )
    }

    // MARK: - Sanal ekran

    func virtualScreenExists() -> Bool {
        listAll().contains { ($0.name == Self.virtualScreenName || $0.originalName == Self.virtualScreenName) && $0.isVirtualScreen }
    }

    /// `MacBook14Virtual` (16:10, HiDPI, 1512x982 içeren) sanal ekranı tanımlı değilse oluşturur.
    func ensureVirtualScreen() {
        if virtualScreenExists() { return }
        Log.info("\(Self.virtualScreenName) sanal ekranı bulunamadı, oluşturuluyor…")
        let list = Self.virtualResolutionList.joined(separator: ",")
        var r = cli([
            "create", "-type=VirtualScreen",
            "-virtualScreenName=\(Self.virtualScreenName)",
            "-aspectWidth=\(Self.createAspect.0)", "-aspectHeight=\(Self.createAspect.1)",
            "-virtualScreenHiDPI=on",
            "-useResolutionList=on", "-resolutionList=\(list)",
            "-connected=off",
        ])
        if !r.succeeded {
            // Eski sürümler create ile birlikte ek parametreleri kabul etmeyebilir: yalın oluştur.
            r = cli(["create", "-type=VirtualScreen", "-virtualScreenName=\(Self.virtualScreenName)",
                     "-aspectWidth=16", "-aspectHeight=10"])
        }
        // Ayarları ayrıca uygula (create ile uygulanmış olsa da zararsızdır).
        configureVirtualScreen()
        if virtualScreenExists() {
            Log.info("\(Self.virtualScreenName) oluşturuldu.")
        } else {
            Log.error("\(Self.virtualScreenName) oluşturulamadı. Sanal ekranlar BetterDisplay Pro gerektirebilir.")
        }
    }

    /// Sanal ekran tanımının HiDPI ve özel çözünürlük listesi ayarlarını uygular.
    func configureVirtualScreen() {
        let list = Self.virtualResolutionList.joined(separator: ",")
        cli(["set", "-name=\(Self.virtualScreenName)", "-virtualScreenHiDPI=on"])
        cli(["set", "-name=\(Self.virtualScreenName)", "-useResolutionList=on", "-resolutionList=\(list)"])
    }

    func setVirtualConnected(_ on: Bool) {
        if !on {
            // Zaten kapalıysa dokunma (gereksiz yeniden yapılandırma olmasın).
            let r = cli(["get", "-name=\(Self.virtualScreenName)", "-connected"], timeout: 5, logFailure: false)
            if r.succeeded && r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "off" { return }
            if !r.succeeded && !virtualScreenExists() { return }
        }
        cli(["set", "-name=\(Self.virtualScreenName)", "-connected=\(on ? "on" : "off")"])
    }

    /// Sanal ekranın en-boy oranını seçilen çözünürlüğe göre ayarlar (yalnızca değiştiyse;
    /// BetterDisplay oran değişince ekranı yeniden oluşturabilir).
    func applyVirtualAspect() {
        let res = Self.virtualResolution
        guard let asp = RemotePreset.aspect(of: res) else { return }
        let w = asp.0, h = asp.1
        let key = "virtualAspectApplied"
        let value = "\(w):\(h)"
        if defaults.string(forKey: key) == value { return }
        let r = cli(["set", "-name=\(Self.virtualScreenName)", "-aspectWidth=\(w)", "-aspectHeight=\(h)"], logFailure: false)
        if r.succeeded {
            defaults.set(value, forKey: key)
            Log.info("\(Self.virtualScreenName) en-boy oranı \(value) (\(res)) olarak ayarlandı.")
        } else {
            Log.warn("En-boy oranı \(value) ayarlanamadı; özel çözünürlük listesi kullanılacak.")
        }
    }

    /// Sanal ekranın şu anki çözünürlüğü (BetterDisplay; "1512x982").
    func currentVirtualResolution() -> String? {
        let r = cli(["get", "-name=\(Self.virtualScreenName)", "-resolution"], timeout: 5, logFailure: false)
        guard r.succeeded else { return nil }
        return RemotePreset.normalize(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Çözünürlüğü ayarlar. BetterDisplay zaten o çözünürlükteyken de "Failed." döner; bu yüzden önce okunur,
    /// her denemeden sonra yeniden okunur ve yalnızca gerçekten tutmazsa hata yazılır.
    @discardableResult
    func setVirtualResolution() -> Bool {
        let res = Self.virtualResolution
        if currentVirtualResolution() == res {
            Log.info("\(Self.virtualScreenName) zaten \(res) HiDPI.")
            return true
        }
        for attempt in 1...3 {
            let r = cli(["set", "-name=\(Self.virtualScreenName)", "-resolution=\(res)", "-hiDPI=on"], timeout: 5, logFailure: false)
            if r.succeeded || pollUntil(timeout: 1.2, interval: 0.1, { currentVirtualResolution() == res }) {
                Log.info("\(Self.virtualScreenName) çözünürlüğü \(res) HiDPI olarak ayarlandı (deneme \(attempt)).")
                return true
            }
            // Liste henüz güncellenmemiş ya da ekran yeni bağlanmış olabilir: yapılandırıp bekle.
            configureVirtualScreen()
            Thread.sleep(forTimeInterval: 0.3)
        }
        Log.error("\(Self.virtualScreenName) çözünürlüğü \(res) yapılamadı (şu an: \(currentVirtualResolution() ?? "?")).")
        return false
    }

    /// Remote sürerken istemcinin Ekran Paylaşımı alanına yeniden uydurma: yalnızca sanal ekranın çözünürlüğü
    /// değişir (fiziksel monitörlere dokunulmaz). Çözünürlük listede yoksa liste güncellenir (bir anlık yeniden bağlanma).
    func refitVirtual(_ res: String) -> Bool {
        let old = Self.resolutionOverride
        Self.resolutionOverride = res
        defer { Self.resolutionOverride = old }
        guard isVirtualActive() else { return false }
        let ok = setVirtualResolution()
        cli(["set", "-name=\(Self.virtualScreenName)", "-main=on"], timeout: 3, logFailure: false)
        return ok
    }

    /// Sanal ekranın macOS tarafından gerçekten bağlandığını bekler (en fazla `timeout` sn).
    @discardableResult
    private func waitForVirtualConnected(timeout: TimeInterval) -> Bool {
        // macOS'ta gerçekten etkin olana dek (yalnızca BetterDisplay'in "on" demesi yetmez) 50 ms aralıkla yokla.
        pollUntil(timeout: timeout, interval: 0.05) { isVirtualActive() }
    }

    // MARK: - Fiziksel ekranlar

    /// Fiziksel ekranları kendi kodumuzla (CoreGraphics özel API) yöneten denetleyici.
    let physical = PhysicalDisplayController()
    /// Monitör başına bağımsız aç/kapa, parlaklık ve kalıcı istenen durum.
    let monitors: MonitorManager

    init() {
        monitors = MonitorManager(physical: physical)
    }

    // MARK: - Ekran kesme arka ucu (Ayarlar > Ekran kontrolü)

    /// Son CLI denetiminin sonucu (nil = henüz denetlenmedi).
    private var cliOKCache: Bool?

    /// Seçili yöntemin çözümlenmiş hâli: BetterDisplay (connected) veya sistem API'si (CGSConfigureDisplayEnabled).
    ///  - Otomatik: BetterDisplay kurulu ve CLI çalışıyorsa BetterDisplay — monitörü tek başına, temiz biçimde
    ///    keser; değilse sistem API'si.
    ///  - BetterDisplay: kuruluysa her zaman; başaramadığı ekranlar için sistem API'sine düşülür.
    ///  - Sistem API: yalnızca CGSConfigureDisplayEnabled (yoksa BetterDisplay).
    var resolvedMethod: PhysicalMethod {
        switch PhysicalMethod.preference {
        case .system:
            return PhysicalDisplayController.isAvailable || !BetterDisplayInstaller.isInstalled ? .system : .betterDisplay
        case .betterDisplay:
            return BetterDisplayInstaller.isInstalled ? .betterDisplay : .system
        case .auto:
            guard BetterDisplayInstaller.isInstalled else { return .system }
            if cliOKCache == nil { cliOKCache = isCLIAvailable() }
            if cliOKCache == true { return .betterDisplay }
            return PhysicalDisplayController.isAvailable ? .system : .betterDisplay
        }
    }

    /// Ayarlar için okunur açıklama.
    var methodDescription: String {
        let pref = PhysicalMethod.preference
        let resolved = resolvedMethod
        let name = resolved == .betterDisplay ? L("BetterDisplay ile") : L("macOS'un kendi yöntemiyle")
        return pref == .auto ? L("%@ (otomatik seçildi)", name) : name
    }

    /// Her ekran işleminden önce arka ucu seçer.
    func configureBackend() {
        if resolvedMethod == .betterDisplay {
            physical.externalSwitch = { [weak self] records, on in
                guard let self = self else { return records }
                return self.switchViaBetterDisplay(records, on: on)
            }
        } else {
            physical.externalSwitch = nil
        }
    }

    /// Kesme yöntemi tercihini değiştirir (Ayarlar).
    func setMethodPreference(_ m: PhysicalMethod) {
        PhysicalMethod.preference = m
        cliOKCache = nil
        configureBackend()
        Log.info("Ekran kontrol yöntemi: \(m.title) → \(methodDescription)")
    }

    /// Kullanılabilir bir kesme yolu var mı (her iki arka uç için de monitör başına denetim kullanılır).
    var usesNativePhysicalControl: Bool {
        PhysicalDisplayController.isAvailable || resolvedMethod == .betterDisplay
    }

    // MARK: BetterDisplay `connected` ile tek monitör

    private let bdTagKey = "betterDisplayTagByHardware"

    private func hardwareKey(_ r: PhysicalDisplayRecord) -> String {
        String(format: "%04X-%04X-%08X", r.vendor, r.model, r.serial)
    }

    /// CG kaydına karşılık gelen BetterDisplay tagID'si: displayID → (hatırlanan donanım eşlemesi) → ad.
    private func betterDisplayTag(for r: PhysicalDisplayRecord, in list: [DisplayInfo]) -> String? {
        var map = (defaults.dictionary(forKey: bdTagKey) as? [String: String]) ?? [:]
        let physicalList = list.filter(Self.isPhysical)
        var found: DisplayInfo? = physicalList.first { $0.displayID == String(r.id) }
        if found == nil, let tag = map[hardwareKey(r)] {
            found = physicalList.first { $0.tagID == tag }
            if found == nil { return tag }  // BetterDisplay listesinde görünmüyor ama tag biliniyor
        }
        if found == nil {
            let lower = r.name.lowercased()
            found = physicalList.first { $0.name.lowercased() == lower || ($0.originalName ?? "").lowercased() == lower || ($0.productName ?? "").lowercased() == lower }
        }
        guard let d = found, let tag = d.tagID, !tag.isEmpty else { return nil }
        if map[hardwareKey(r)] != tag {
            map[hardwareKey(r)] = tag
            defaults.set(map, forKey: bdTagKey)
        }
        return tag
    }

    /// BetterDisplay ile yalnızca verilen monitörleri bağla/kes. Her adım günlüğe yazılır.
    /// - Returns: başarısız olan kayıtlar.
    func switchViaBetterDisplay(_ records: [PhysicalDisplayRecord], on: Bool) -> [PhysicalDisplayRecord] {
        ensureBetterDisplayRunning()
        let list = listAll()
        var failed: [PhysicalDisplayRecord] = []
        var jobs: [(PhysicalDisplayRecord, String)] = []
        for r in records {
            guard let tag = betterDisplayTag(for: r, in: list) else {
                Log.warn("BetterDisplay: \(r.label) için tagID bulunamadı")
                failed.append(r)
                continue
            }
            jobs.append((r, tag))
        }
        // Birden çok monitör aynı anda kesilir/açılır (her biri ~0,1–1 sn; sırayla beklemek toplamı uzatıyordu).
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
            let (r, tag) = jobs[i]
            let sw = Stopwatch("BetterDisplay \(on ? "aç" : "kes") \(r.name)")
            Log.info("BetterDisplay: set -tagID=\(tag) -connected=\(on ? "on" : "off")  (\(r.name))")
            let res = cli(["set", "-tagID=\(tag)", "-connected=\(on ? "on" : "off")"], timeout: on ? 6 : 4)
            var ok = res.succeeded
            if ok {
                // macOS'un yeniden yapılandırmasını 20 ms aralıkla bekle (açmak HDMI/DP el sıkışması nedeniyle daha uzun sürer).
                let reached = pollUntil(timeout: on ? 8 : 3, interval: 0.02) { physical.isActive(r.id) == on }
                Log.info("BetterDisplay: \(r.name) → \(reached ? (on ? "açık" : "kapalı") : "durum doğrulanamadı")")
                if !reached && on { ok = false }
            }
            sw.lap(ok ? "tamam" : "başarısız")
            if !ok { lock.lock(); failed.append(r); lock.unlock() }
        }
        return failed
    }

    /// Fiziksel sayılmaması gereken ekran adları (sanal ekran, dummy ve kullanıcı listesi).
    private var excludedNames: [String] {
        [Self.virtualScreenName, "dummy"] + (defaults.stringArray(forKey: "excludedDisplays") ?? [])
    }

    /// BetterDisplay varsayılan olarak SON fiziksel monitörün bağlantısını kesmeyi reddeder (sanal ekranlar sayılmaz)
    /// ve "Failed." döner. Remote'ta tek monitör de kesilebilsin diye "displayAllowDisconnectAll" açılır.
    /// Ayar BetterDisplay yeniden başlayınca okunur; bu yüzden değiştiyse BetterDisplay bir kez yeniden başlatılır.
    static let betterDisplayDomain = "pro.betterdisplay.BetterDisplay"
    func ensureDisconnectAllAllowed() {
        let read = Shell.run("/usr/bin/defaults", ["read", Self.betterDisplayDomain, "displayAllowDisconnectAll"], timeout: 5)
        if read.succeeded && read.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1" { return }
        Log.info("BetterDisplay: tek/son monitörün de kesilebilmesi için 'displayAllowDisconnectAll' açılıyor")
        Shell.run("/usr/bin/defaults", ["write", Self.betterDisplayDomain, "displayAllowDisconnectAll", "-bool", "true"], timeout: 5)
        guard isBetterDisplayRunning() else { return }
        Log.info("BetterDisplay ayarı okuması için yeniden başlatılıyor…")
        Shell.run("/usr/bin/osascript", ["-e", "quit app \"BetterDisplay\""], timeout: 10)
        for _ in 0..<20 where isBetterDisplayRunning() { Thread.sleep(forTimeInterval: 0.25) }
        if isBetterDisplayRunning() { Shell.run("/usr/bin/pkill", ["-x", "BetterDisplay"], timeout: 5); Thread.sleep(forTimeInterval: 1) }
        ensureBetterDisplayRunning()   // CLI yanıt verene dek yoklar
    }

    func isBetterDisplayRunning() -> Bool {
        Shell.run("/usr/bin/pgrep", ["-x", "BetterDisplay"], timeout: 5).succeeded
    }

    /// BetterDisplay'in bildirdiği sanal/dummy ekranların macOS displayID'leri (çalışıyorsa).
    private func betterDisplayNonPhysicalIDs() -> Set<UInt32> {
        guard isBetterDisplayRunning() else { return [] }
        var ids = Set<UInt32>()
        for d in listAll() where !Self.isPhysical(d) {
            if let s = d.displayID, let v = UInt32(s) { ids.insert(v) }
        }
        return ids
    }

    /// Şu an etkin fiziksel ekranları (CoreGraphics) listeler.
    func activeNativePhysicalDisplays() -> [PhysicalDisplayRecord] {
        physical.physicalDisplays(excludedIDs: betterDisplayNonPhysicalIDs(), excludedNames: excludedNames, activeOnly: true)
    }

    @discardableResult
    func setPhysicalConnected(_ on: Bool) -> Bool {
        configureBackend()
        if usesNativePhysicalControl {
            let excludedIDs = betterDisplayNonPhysicalIDs()
            if on {
                return physical.enableAll(excludedIDs: excludedIDs, excludedNames: excludedNames)
            }
            let targets = physical.physicalDisplays(excludedIDs: excludedIDs, excludedNames: excludedNames, activeOnly: true)
            if targets.isEmpty {
                Log.info("Etkin fiziksel ekran yok; devre dışı bırakılacak bir şey yok.")
                return true
            }
            return physical.disable(targets)
        }
        return setPhysicalConnectedViaBetterDisplay(on)
    }

    /// Yedek yol: BetterDisplay `connected=on/off` (BetterDisplay Pro gerekir).
    @discardableResult
    private func setPhysicalConnectedViaBetterDisplay(_ on: Bool) -> Bool {
        Log.info("Özel API kullanılmıyor/yok; BetterDisplay connected yedek yolu kullanılıyor.")
        ensureBetterDisplayRunning()
        if physicalDisplays.isEmpty { refreshPhysicalDisplays() }
        if physicalDisplays.isEmpty {
            Log.error("Fiziksel ekran bulunamadı; connected=\(on ? "on" : "off") atlanıyor.")
            return false
        }
        var allOK = true
        for d in physicalDisplays {
            var r = cli(["set", d.selectorArgument, "-connected=\(on ? "on" : "off")"])
            if !r.succeeded, d.tagID != nil {
                // tagID değişmiş olabilir: isimle tekrar dene.
                r = cli(["set", "-name=\(d.name)", "-connected=\(on ? "on" : "off")"])
            }
            allOK = allOK && r.succeeded
            Log.info("Fiziksel ekran \(d.label) → connected=\(on ? "on" : "off")")
        }
        return allOK
    }

    /// Şu an macOS'ta etkin fiziksel ekran var mı?
    func anyPhysicalConnected() -> Bool {
        if usesNativePhysicalControl { return !activeNativePhysicalDisplays().isEmpty }
        if physicalDisplays.isEmpty { refreshPhysicalDisplays() }
        for d in physicalDisplays {
            let r = cli(["get", d.selectorArgument, "-connected"], timeout: 5, logFailure: false)
            if r.succeeded && r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "on" { return true }
        }
        return false
    }

    /// Sanal ekran macOS'ta etkin mi?
    func isVirtualActive() -> Bool {
        if physical.isVirtualActive(named: Self.virtualScreenName, ids: betterDisplayNonPhysicalIDs()) { return true }
        let r = cli(["get", "-name=\(Self.virtualScreenName)", "-connected"], timeout: 5, logFailure: false)
        return r.succeeded && r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "on"
    }

    // MARK: - Monitör paneli

    func monitorSnapshot() -> [MonitorSnapshot] {
        configureBackend()
        return monitors.snapshot(excludedIDs: betterDisplayNonPhysicalIDs(), excludedNames: excludedNames)
    }

    /// İstenen durumu yeniden uygular (uyanma, yeniden yapılandırma, açılış sonrası).
    @discardableResult
    func reconcileMonitors(mode: WorkMode, applyBrightness: Bool) -> [String] {
        configureBackend()
        guard usesNativePhysicalControl else {
            // Yedek yol (BetterDisplay connected): yalnızca Remote koruması.
            if mode == .remote, anyPhysicalConnected(), isVirtualActive() { setPhysicalConnected(false) }
            return []
        }
        var virtualActive = false
        if mode == .remote {
            virtualActive = isVirtualActive()
            if !virtualActive && isBetterDisplayRunning() {
                setVirtualConnected(true)
                virtualActive = waitForVirtualConnected(timeout: 3)
            }
        }
        return monitors.reconcile(mode: mode, virtualActive: virtualActive, applyBrightness: applyBrightness,
                                  excludedIDs: betterDisplayNonPhysicalIDs(), excludedNames: excludedNames)
    }

    func setMonitorEnabled(key: String, enabled: Bool, mode: WorkMode) -> String? {
        configureBackend()
        guard usesNativePhysicalControl else { return L("Ekran kesme yöntemi kullanılamıyor (BetterDisplay veya sistem API'si yok)") }
        Log.info("Monitör aç/kapa isteği: \(key) → \(enabled ? "açık" : "kapalı") · yöntem: \(methodDescription)")
        let virtualActive = mode == .desktop ? false : isVirtualActive()
        return monitors.setDesiredEnabled(key: key, enabled: enabled, mode: mode, virtualActive: virtualActive,
                                          excludedIDs: betterDisplayNonPhysicalIDs(), excludedNames: excludedNames)
    }

    // MARK: - Mod dizileri

    /// Remote'a hazırlık (geri sayım sırasında da çağrılır): BetterDisplay + CLI, sanal ekran tanımı, bağlantı
    /// ve çözünürlük. Fiziksel monitörlere DOKUNMAZ. Hazırsa (sanal ekran etkin, doğru çözünürlük) hızlıca döner.
    /// - Returns: hata açıklaması veya nil.
    func prepareRemote(_ sw: Stopwatch) -> String? {
        ensureBetterDisplayRunning()
        if remotePreparedFor == Self.virtualResolution, isVirtualActive() {
            sw.lap("sanal ekran zaten hazır")
            return nil
        }
        guard isCLIAvailable() else {
            return L("BetterDisplay CLI kapalı: BetterDisplay > Settings > Application > Integration > CLI erişimini açın")
        }
        if resolvedMethod == .betterDisplay { ensureDisconnectAllAllowed() }
        Log.info("Remote sanal ekran çözünürlüğü: \(Self.virtualResolution) HiDPI")
        ensureVirtualScreen()
        // En-boy oranı DEĞİŞTİRİLMEZ: özel çözünürlük listesi açıkken modlar orandan bağımsızdır; oran değişimi
        // sanal ekranı yeniden oluşturuyordu (yeni displayID, ara 1920x1080 modu, Ekran Paylaşımı'nda kesinti).
        if !isVirtualActive() {
            configureVirtualScreen()
            setVirtualConnected(true)
            waitForVirtualConnected(timeout: 6)
        }
        sw.lap("sanal ekran bağlandı")
        setVirtualResolution()
        sw.lap("çözünürlük")
        guard isVirtualActive() else {
            Log.error("\(Self.virtualScreenName) etkinleşmedi; güvenlik için fiziksel ekranlar kesilmedi.")
            return L("Sanal ekran açılamadı (BetterDisplay Pro / CLI?) – fiziksel ekranlar açık bırakıldı")
        }
        physical.rememberVirtualHardware(named: Self.virtualScreenName, ids: betterDisplayNonPhysicalIDs())
        remotePreparedFor = Self.virtualResolution
        return nil
    }

    /// Geri sayımda hazırlanan sanal ekran (Remote'a geçilmediyse geri sayım iptalinde kapatılır).
    private(set) var remotePreparedFor: String?

    /// Geri sayım iptal edildi: hazırlıkta açılan sanal ekranı kapat (fiziksel monitörlere dokunulmadı).
    func cancelRemotePreparation() {
        guard remotePreparedFor != nil else { return }
        remotePreparedFor = nil
        if isBetterDisplayRunning() { setVirtualConnected(false) }
        Log.info("Remote hazırlığı geri alındı (sanal ekran kapatıldı).")
    }

    /// Remote: sanal ekran (geri sayımda hazırlanmadıysa şimdi) açılır, ardından fiziksel monitörler HEMEN kesilir.
    /// Sabit bekleme yoktur; doğrulama kısa yoklamalarla yapılır. Sanal ekran etkin değilse Mac'i ekransız
    /// bırakmamak için fiziksel ekranlar KESİLMEZ ve hata döner.
    /// - Returns: Hata açıklaması veya başarıda nil.
    func applyRemoteLayout() -> String? {
        let sw = Stopwatch("remote")
        if let e = prepareRemote(sw) { remotePreparedFor = nil; return e }
        remotePreparedFor = nil
        // 1) Önce kes: kullanıcı geri sayımın bitişiyle ekranların kararmasını bekliyor.
        _ = setPhysicalConnected(false)
        sw.lap("fiziksel monitörler kesildi")
        // 2) Doğrula; gerekirse yeniden dene (kısa yoklama, sabit uyku yok).
        var lit: [PhysicalDisplayRecord] = []
        for attempt in 1...3 {
            var current: [PhysicalDisplayRecord] = []
            let gone = pollUntil(timeout: attempt == 1 ? 0.6 : 1.0, interval: 0.05) {
                current = activeNativePhysicalDisplays()
                return current.isEmpty
            }
            lit = current
            if gone || attempt == 3 { break }
            Log.warn("Remote: hâlâ açık fiziksel ekran var (\(lit.map { $0.label }.joined(separator: ", "))), yeniden deneniyor (\(attempt + 1)/3)")
            _ = setPhysicalConnected(false)
        }
        sw.lap("doğrulandı")
        // 3) Kritik olmayanlar: ana ekran ve çözünürlük (macOS yeniden yerleşim yapabilir).
        cli(["set", "-name=\(Self.virtualScreenName)", "-main=on"], timeout: 3, logFailure: false)
        if currentVirtualResolution() != Self.virtualResolution { setVirtualResolution() }
        sw.lap("ana ekran + çözünürlük denetimi")
        if lit.isEmpty {
            Log.info("Remote: yalnızca \(Self.virtualScreenName) açık (\(Self.virtualResolution) HiDPI).")
            return nil
        }
        Log.error("Remote: şu monitörler kesilemedi: \(lit.map { $0.label }.joined(separator: ", "))")
        return L("Fiziksel ekranlar kesilemedi (günlüğe bakın)")
    }

    /// Desktop: her monitörü KENDİ istenen durumuna döndür (kullanıcının kapattığı kapalı kalır; hepsi tek
    /// yapılandırma işleminde açılır), ardından sanal ekranı kapat. Sıra, sistemin ekransız kalmaması içindir.
    /// Ekran uykusundaki/bekleme modundaki monitörler önce uyandırılır (açmaya çalışmak 10 sn'lik zaman aşımları
    /// ve CGError 1014 üretiyordu). Hiçbir fiziksel monitör görüntü vermiyorsa acil kurtarma çalışır.
    /// İkinci (son) uzlaştırma AppDelegate'te arka planda yapılır.
    func applyDesktopLayout() -> String? {
        let sw = Stopwatch("desktop")
        configureBackend()
        remotePreparedFor = nil
        guard usesNativePhysicalControl else {
            let ok = setPhysicalConnected(true)
            if isBetterDisplayRunning() { setVirtualConnected(false) }
            return ok ? nil : L("Bazı fiziksel ekranlar açılamadı (günlüğe bakın)")
        }
        // Uyuyan ekranları uyandır (beklemeden), bizim kestiklerimizi tek işlemde aç.
        physical.wakeDisplaysIfNeeded(excludedIDs: betterDisplayNonPhysicalIDs(), excludedNames: excludedNames)
        monitors.reconcile(mode: .desktop, virtualActive: false, applyBrightness: true, quick: true,
                           excludedIDs: betterDisplayNonPhysicalIDs(), excludedNames: excludedNames)
        sw.lap("monitörler açıldı")
        // Hâlâ hiç görüntü yoksa monitör bekleme modundan dönüyordur: açmaya zorlamak yerine bağlantıyı bekle.
        if activeNativePhysicalDisplays().isEmpty {
            physical.wakeDisplaysIfNeeded(excludedIDs: betterDisplayNonPhysicalIDs(), excludedNames: excludedNames, wait: true)
            monitors.reconcile(mode: .desktop, virtualActive: false, applyBrightness: true, quick: true,
                               excludedIDs: betterDisplayNonPhysicalIDs(), excludedNames: excludedNames)
        }
        if !pollUntil(timeout: 1.5, interval: 0.05, { !activeNativePhysicalDisplays().isEmpty }) {
            emergencyRestore(reason: "Masaüstü: hiç monitör açılmadı")
        }
        if isBetterDisplayRunning() && isVirtualActive() {
            setVirtualConnected(false)
            sw.lap("sanal ekran kapatıldı")
        }
        // Sanal ekran kapanınca (aynalanan) monitörler kendi moduna döner: kısa yoklama.
        if !pollUntil(timeout: 2, interval: 0.05, { !activeNativePhysicalDisplays().isEmpty }) {
            emergencyRestore(reason: "Masaüstü: sanal ekran kapandıktan sonra monitör yok")
        }
        sw.lap("doğrulandı")
        return !activeNativePhysicalDisplays().isEmpty ? nil : L("Bazı fiziksel ekranlar açılamadı (günlüğe bakın)")
    }

    /// Sleep: monitörlerin bağlantısı KESİLMEZ. Masaüstü düzeni (her monitör kendi istenen durumunda, sanal
    /// ekran kapalı) yalnızca GEREKİRSE (Remote'tan gelindiyse) kurulur; ardından ModeController
    /// `pmset displaysleepnow` ile ekranları HEMEN uyutur. Masaüstü'nden geçişte düzen zaten doğrudur: hiçbir
    /// ekran işlemi beklenmez (eskiden her seferinde ~2 sn sabit bekleme vardı).
    ///
    /// Neden kesilmez: uyuyan monitör zaten DPMS bekleme modundadır (<0,5 W); kesmek uyanmayı kırılgan yapar.
    func applySleepLayout() -> String? {
        let sw = Stopwatch("sleep")
        let needsDesktop = BetterDisplayInstaller.isInstalled && isBetterDisplayRunning() && isVirtualActive()
        sw.lap("düzen denetimi (\(needsDesktop ? "Remote'tan dönüş" : "değişiklik yok"))")
        return needsDesktop ? applyDesktopLayout() : nil
    }

    // MARK: - Acil kurtarma

    /// Hiç fiziksel monitör görüntü vermiyorsa: BetterDisplay ile bilinen tüm monitörleri bağla, ardından
    /// sistem API'siyle hatırlanan / IORegistry'de görülen her displayID'yi etkinleştir.
    /// - Returns: en az bir fiziksel monitör açık mı.
    @discardableResult
    func emergencyRestore(reason: String) -> Bool {
        let excludedIDs = betterDisplayNonPhysicalIDs()
        if physical.anyPhysicalLit(excludedIDs: excludedIDs, excludedNames: excludedNames) { return true }
        Log.warn("Acil kurtarma başladı (\(reason)): hiçbir fiziksel monitör görüntü vermiyor")
        // 1) BetterDisplay: kestiği monitörleri yalnızca kendisi düzgün geri bağlar.
        if BetterDisplayInstaller.isInstalled {
            ensureBetterDisplayRunning()
            var tags = Set(((defaults.dictionary(forKey: bdTagKey) as? [String: String]) ?? [:]).values)
            for d in listAll() where Self.isPhysical(d) && !Self.isGenericPlaceholder(d) {
                if let t = d.tagID, !t.isEmpty { tags.insert(t) }
            }
            for tag in tags.sorted() {
                Log.info("Acil kurtarma: BetterDisplay set -tagID=\(tag) -connected=on")
                cli(["set", "-tagID=\(tag)", "-connected=on"], timeout: 4, logFailure: false)
            }
            pollUntil(timeout: 4, interval: 0.1) { physical.anyPhysicalLit(excludedIDs: excludedIDs, excludedNames: excludedNames) }
        }
        // 2) Sistem API'si: devre dışı bırakılan ekranlar displayID'lerini korur.
        if !physical.anyPhysicalLit(excludedIDs: excludedIDs, excludedNames: excludedNames) {
            physical.forceEnable(extraIDs: monitors.knownDisplayIDs())
            pollUntil(timeout: 1.5, interval: 0.05) { physical.anyPhysicalLit(excludedIDs: excludedIDs, excludedNames: excludedNames) }
        }
        // 3) Son çare: küçük displayID'ler (harici monitörler genellikle 1…8 alır; zaten açık olanlara dokunulmaz).
        if !physical.anyPhysicalLit(excludedIDs: excludedIDs, excludedNames: excludedNames) {
            // Yalnızca macOS'un çevrimiçi gördüğü kimlikler: yok olan bir displayID için her deneme ~10 sn
            // bekleyip CGError 1014 döndürüyordu (1…8 taraması dakikalar sürüyordu).
            physical.forceEnable(extraIDs: Array(1...8).filter { physical.onlineDisplayIDs().contains($0) })
            pollUntil(timeout: 1.5, interval: 0.05) { physical.anyPhysicalLit(excludedIDs: excludedIDs, excludedNames: excludedNames) }
        }
        let ok = physical.anyPhysicalLit(excludedIDs: excludedIDs, excludedNames: excludedNames)
        if ok { physical.forgetRemembered() }
        Log.info("Acil kurtarma → \(ok ? "monitör(ler) açık" : "BAŞARISIZ (kabloyu çıkarıp takın ya da Mac'i yeniden başlatın)")")
        return ok
    }

    /// BetterDisplay'in listelediği macOS yer tutucu ekranı ("Generic Display"): fiziksel değil.
    static func isGenericPlaceholder(_ d: DisplayInfo) -> Bool {
        [d.name, d.originalName ?? "", d.productName ?? ""].contains { $0.lowercased() == "generic display" }
    }
}
