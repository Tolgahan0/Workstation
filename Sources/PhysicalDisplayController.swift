import Foundation

/// Kalıcı olarak hatırlanan fiziksel ekran kaydı. displayID yeniden takma/yeniden başlatma sonrası
/// değişebileceği için vendor/model/seri numarası da saklanır.
struct PhysicalDisplayRecord: Codable, Equatable {
    var id: UInt32
    var vendor: UInt32
    var model: UInt32
    var serial: UInt32
    var name: String

    var label: String { "\(name) (displayID \(id))" }

    func sameHardware(_ other: PhysicalDisplayRecord) -> Bool {
        vendor == other.vendor && model == other.model && serial == other.serial
    }

    /// macOS'un hiç ekran kalmayınca oluşturduğu yer tutucu ("Generic Display", vendor 'unkn' / model 'virt')
    /// ya da artık var olmayan bir displayID (CoreGraphics 0xFFFFFFFF döndürür). Bunlar fiziksel monitör DEĞİLDİR:
    /// kapatılırsa Mac'te hiç görüntü kalmaz.
    var isPlaceholder: Bool { Self.isPlaceholder(vendor: vendor, model: model) }

    static let placeholderVendor: UInt32 = 0x756E_6B6E // "unkn"
    static let placeholderModel: UInt32 = 0x7669_7274  // "virt"
    static func isPlaceholder(vendor: UInt32, model: UInt32) -> Bool {
        vendor == placeholderVendor || model == placeholderModel || vendor == UInt32.max
    }
}

#if os(macOS)
import AppKit
import CoreGraphics
import IOKit.pwr_mgt

/// Fiziksel monitörleri BetterDisplay Pro'ya ihtiyaç duymadan, CoreGraphics'in özel
/// `CGSConfigureDisplayEnabled` (veya SkyLight `SLSConfigureDisplayEnabled`) API'si ile
/// devre dışı bırakır / yeniden etkinleştirir.
///
/// Değişiklikler `CGCompleteDisplayConfiguration(..., .forSession)` ile uygulanır: oturum
/// kapanana / Mac yeniden başlayana kadar sürer; böylece bir sorun olursa yeniden başlatma
/// monitörleri her zaman geri getirir. (`defaults write ... physicalDisableScope permanent`
/// ile kalıcı yapılabilir, önerilmez.)
final class PhysicalDisplayController {
    typealias ConfigureDisplayEnabledFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError

    private static let loaded: (fn: ConfigureDisplayEnabledFn, source: String)? = {
        let candidates: [(path: String, symbol: String)] = [
            ("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", "CGSConfigureDisplayEnabled"),
            ("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", "SLSConfigureDisplayEnabled"),
        ]
        for c in candidates {
            guard let handle = dlopen(c.path, RTLD_LAZY) else { continue }
            if let sym = dlsym(handle, c.symbol) {
                return (unsafeBitCast(sym, to: ConfigureDisplayEnabledFn.self), "\(c.symbol) (\((c.path as NSString).lastPathComponent))")
            }
        }
        return nil
    }()

    static var isAvailable: Bool { loaded != nil }
    static var apiDescription: String { loaded?.source ?? L("yok") }

    /// Harici anahtarlama arka ucu (BetterDisplay `connected`). Ayarlanmışsa önce o denenir;
    /// başaramadığı ekranlar için sistem API'sine (CGSConfigureDisplayEnabled) düşülür.
    /// Dönüş: BAŞARILAMAYAN kayıtlar.
    var externalSwitch: (([PhysicalDisplayRecord], Bool) -> [PhysicalDisplayRecord])?
    /// Son kullanılan arka uç (günlük/ayarlar için).
    private(set) var lastBackend = "—"

    private let rememberedKey = "disabledPhysicalDisplays"
    private let defaults = UserDefaults.standard

    private var configureOption: CGConfigureOption {
        defaults.string(forKey: "physicalDisableScope") == "permanent" ? .permanently : .forSession
    }

    // MARK: Listeleme

    func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// NSScreen adları (yalnızca etkin ekranlar). NSScreen ana iş parçacığında okunur.
    func screenNames() -> [CGDirectDisplayID: String] {
        let read: () -> [CGDirectDisplayID: String] = {
            var map: [CGDirectDisplayID: String] = [:]
            for screen in NSScreen.screens {
                if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                    map[CGDirectDisplayID(n.uint32Value)] = screen.localizedName
                }
            }
            return map
        }
        return Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
    }

    private func record(for id: CGDirectDisplayID, names: [CGDirectDisplayID: String]) -> PhysicalDisplayRecord {
        let remembered = loadRemembered().first { $0.id == id }
        return PhysicalDisplayRecord(
            id: id,
            vendor: CGDisplayVendorNumber(id),
            model: CGDisplayModelNumber(id),
            serial: CGDisplaySerialNumber(id),
            name: names[id] ?? remembered?.name ?? "Display \(id)")
    }

    /// Çevrimiçi fiziksel ekranlar: dahili ekran, BetterDisplay sanal/dummy ekranları ve
    /// adı hariç tutma listesinde olanlar dışarıda bırakılır.
    func physicalDisplays(excludedIDs: Set<UInt32>, excludedNames: [String], activeOnly: Bool) -> [PhysicalDisplayRecord] {
        let names = screenNames()
        let lowered = excludedNames.map { $0.lowercased() }.filter { !$0.isEmpty }
        let virtualHardware = loadVirtualHardware()
        return onlineDisplayIDs().compactMap { id -> PhysicalDisplayRecord? in
            if CGDisplayIsBuiltin(id) > 0 { return nil }
            if excludedIDs.contains(id) { return nil }
            if activeOnly && !Self.isLit(id) { return nil }
            let r = record(for: id, names: names)
            if r.isPlaceholder { return nil }
            let n = r.name.lowercased()
            if lowered.contains(where: { n.contains($0) }) { return nil }
            if virtualHardware.contains(where: { $0.sameHardware(r) }) { return nil }
            return r
        }
    }

    // MARK: Sanal ekran donanım kimliği (adı görünmediğinde de dışarıda bırakmak için)

    private let virtualHardwareKey = "virtualDisplayHardware"

    /// Etkin bir ekranın adı sanal ekran adıyla eşleşiyorsa vendor/model/serisini hatırla.
    func rememberVirtualHardware(named virtualName: String, ids: Set<UInt32>) {
        let names = screenNames()
        var list = loadVirtualHardware()
        for id in activeDisplayIDs() where names[id] == virtualName || ids.contains(id) {
            let r = record(for: id, names: names)
            if !list.contains(where: { $0.sameHardware(r) }) { list.append(r) }
        }
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: virtualHardwareKey) }
    }

    private func loadVirtualHardware() -> [PhysicalDisplayRecord] {
        guard let data = defaults.data(forKey: virtualHardwareKey),
              let list = try? JSONDecoder().decode([PhysicalDisplayRecord].self, from: data) else { return [] }
        return list
    }

    /// Sanal ekran macOS'ta etkin mi? (adıyla veya BetterDisplay'in bildirdiği displayID ile)
    func isVirtualActive(named virtualName: String, ids: Set<UInt32>) -> Bool {
        let names = screenNames()
        return activeDisplayIDs().contains { names[$0] == virtualName || ids.contains($0) }
    }

    // MARK: Hatırlanan (devre dışı bırakılmış) ekranlar

    /// Yer tutucu kayıtlar (eski sürümlerin yanlışlıkla hatırladığı "Generic Display") okunurken atılır.
    func loadRemembered() -> [PhysicalDisplayRecord] {
        guard let data = defaults.data(forKey: rememberedKey),
              let list = try? JSONDecoder().decode([PhysicalDisplayRecord].self, from: data) else { return [] }
        return list.filter { !$0.isPlaceholder }
    }

    private func saveRemembered(_ list: [PhysicalDisplayRecord]) {
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: rememberedKey) }
    }

    func forgetRemembered() { defaults.removeObject(forKey: rememberedKey) }

    // MARK: Devre dışı bırak / etkinleştir

    /// `configure`'ü en fazla `wait` sn bekler (macOS yok olan bir ekran için ~10 sn kilitlenebiliyor).
    /// Süre aşılırsa false döner; çağrı arka planda kendi kendine biter.
    private func configureBounded(_ ids: [CGDirectDisplayID], enabled: Bool, wait: TimeInterval) -> Bool {
        let done = DispatchSemaphore(value: 0)
        var result = false
        let lock = NSLock()
        DispatchQueue.global(qos: .userInitiated).async {
            let r = self.configure(ids, enabled: enabled)
            lock.lock(); result = r; lock.unlock()
            done.signal()
        }
        if done.wait(timeout: .now() + wait) == .timedOut {
            Log.warn("Sistem API'si \(wait) sn içinde yanıt vermedi (\(ids.map(String.init).joined(separator: ", "))); yedek yola geçiliyor")
            return false
        }
        lock.lock(); defer { lock.unlock() }
        return result
    }

    /// Ekran uykusundaki / bekleme modundaki monitörleri uyandırır (kullanıcı etkinliği bildirir) ve hiçbir
    /// fiziksel monitör görüntü vermiyorsa kısa süre (en fazla 4 sn) bağlantının geri gelmesini bekler.
    /// Uyumuş bir monitörü "açmaya" çalışmak yerine macOS'un kendi uyanma yolunu kullanır.
    func wakeDisplaysIfNeeded(excludedIDs: Set<UInt32>, excludedNames: [String], wait: Bool = false) {
        let online = onlineDisplayIDs()
        let asleep = online.contains { CGDisplayIsAsleep($0) > 0 }
        let anyLit = anyPhysicalLit(excludedIDs: excludedIDs, excludedNames: excludedNames)
        guard asleep || !anyLit else { return }
        let id = Self.declareUserActivity()
        if wait && !anyLit {
            let sw = Stopwatch("ekran uyandırma")
            let ok = pollUntil(timeout: 4, interval: 0.05) { anyPhysicalLit(excludedIDs: excludedIDs, excludedNames: excludedNames) }
            sw.lap(ok ? "monitör geri geldi" : "monitör gelmedi")
        }
        if id != 0 { IOPMAssertionRelease(id) }
    }

    /// "Kullanıcı etkin" bildirir: uyuyan ekranları uyandırır (fare kıpırdatmak gibi). Dönen kimlik bırakılmalı.
    @discardableResult
    static func declareUserActivity() -> IOPMAssertionID {
        var id: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Workstation: Masaüstü" as CFString, kIOPMUserActiveLocal, &id)
        return id
    }

    /// Tek bir yapılandırma işleminde verilen ekranları etkinleştirir/devre dışı bırakır.
    private func configure(_ ids: [CGDirectDisplayID], enabled: Bool) -> Bool {
        guard let fn = Self.loaded?.fn, !ids.isEmpty else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else {
            Log.error("CGBeginDisplayConfiguration başarısız.")
            return false
        }
        var ok = true
        for id in ids {
            // Aynalanan bir monitör önce aynadan çıkarılır (yoksa macOS yapılandırmayı reddedebilir).
            if !enabled && CGDisplayIsInMirrorSet(id) > 0 {
                _ = CGConfigureDisplayMirrorOfDisplay(cfg, id, kCGNullDirectDisplay)
            }
            let err = fn(cfg, id, enabled)
            if err != .success {
                ok = false
                Log.error("ConfigureDisplayEnabled(\(id), \(enabled)) → CGError \(err.rawValue)")
            }
        }
        let done = CGCompleteDisplayConfiguration(cfg, configureOption)
        if done != .success {
            Log.error("CGCompleteDisplayConfiguration → CGError \(done.rawValue)")
            CGCancelDisplayConfiguration(cfg)
            return false
        }
        return ok
    }

    /// Ekranları seçili arka uçla aç/kapa. Yalnızca VERİLEN ekranlara dokunur.
    private func switchDisplays(_ displays: [PhysicalDisplayRecord], enabled: Bool) -> Bool {
        guard !displays.isEmpty else { return true }
        var remaining = displays
        // AÇMA: önce sistem API'si, tüm monitörler TEK yapılandırma işleminde (ölçüm: ~0,15–0,45 sn;
        // BetterDisplay connected=on ~1,1 sn). Yalnızca çevrimiçi ya da bizim kestiğimiz (hatırlanan) kimlikler:
        // yok olan bir displayID için çağrı ~10 sn bekleyip CGError 1014 döndürüyordu. Başaramadıkları BetterDisplay'e.
        if enabled {
            // Bizim KESMEDİĞİMİZ (hatırlanmayan) ama görüntü vermeyen monitör kapalı değil, ekran uykusunda /
            // bekleme modundadır (ör. Uyku'dan dönüş). Onu "açmaya" çalışmak BetterDisplay'de 10 sn zaman aşımı,
            // sistem API'sinde ~10 sn bekleyip CGError 1014 veriyordu. macOS'un kendi uyanma yolu: kullanıcı etkinliği.
            let remembered = loadRemembered()
            let asleep = remaining.filter { r in !remembered.contains { $0.id == r.id || $0.sameHardware(r) } }
            if !asleep.isEmpty {
                let sw = Stopwatch("uyandır")
                let aid = Self.declareUserActivity()
                let back = pollUntil(timeout: 4, interval: 0.05) { asleep.allSatisfy { Self.isLit($0.id) } }
                if aid != 0 { IOPMAssertionRelease(aid) }
                sw.lap("\(asleep.map { $0.name }.joined(separator: ", ")) → \(back ? "uyandı" : "henüz gelmedi")")
                remaining = remaining.filter { !Self.isLit($0.id) }
                if remaining.isEmpty { return true }
            }
        }
        if enabled && Self.isAvailable {
            let online = Set(onlineDisplayIDs())
            let remembered = loadRemembered()
            let direct = remaining.filter { r in online.contains(r.id) || remembered.contains { $0.id == r.id } }
            if !direct.isEmpty {
                let sw = Stopwatch("sistem API'si aç")
                let ok = configureBounded(direct.map { $0.id }, enabled: true, wait: 3)
                let lit = pollUntil(timeout: ok ? 1.5 : 0.3, interval: 0.02) { direct.allSatisfy { Self.isLit($0.id) } }
                sw.lap("\(direct.map { $0.name }.joined(separator: ", ")) → \(lit ? "açık" : "tamamlanmadı")")
                lastBackend = Self.apiDescription
                remaining = remaining.filter { !Self.isLit($0.id) }
                if remaining.isEmpty { return true }
            }
        }
        if let ext = externalSwitch {
            remaining = ext(displays, enabled)
            lastBackend = "BetterDisplay"
            if remaining.isEmpty { return true }
            Log.warn("BetterDisplay şu ekranları \(enabled ? "açamadı" : "kapatamadı"): \(remaining.map { $0.label }.joined(separator: ", ")) → sistem API'si deneniyor")
        }
        guard Self.isAvailable else { return false }
        // BetterDisplay kapatamadıysa sistem API'siyle KAPATMA denenmez: bazı kurulumlarda (macOS 26, HDMI)
        // CGSConfigureDisplayEnabled kapalı monitörleri geri getirip hepsini aynalıyor. Açma için yedek kalır.
        if !enabled && externalSwitch != nil && !defaults.bool(forKey: "systemDisableFallback") {
            Log.warn("Sistem API'siyle kapatma atlandı (güvenli değil): \(remaining.map { $0.label }.joined(separator: ", "))")
            return false
        }
        if enabled { return false } // sistem API'siyle açma yukarıda denendi
        lastBackend = Self.apiDescription
        var ok = configure(remaining.map { $0.id }, enabled: enabled)
        if !ok && remaining.count > 1 {
            ok = remaining.map { configure([$0.id], enabled: enabled) }.allSatisfy { $0 }
        }
        return ok
    }

    /// Verilen fiziksel ekranları devre dışı bırakır ve yeniden açılabilmeleri için hatırlar.
    @discardableResult
    func disable(_ displays: [PhysicalDisplayRecord]) -> Bool {
        let displays = displays.filter { !$0.isPlaceholder }
        guard !displays.isEmpty else { return true }
        var remembered = loadRemembered()
        for d in displays {
            remembered.removeAll { $0.id == d.id || $0.sameHardware(d) }
            remembered.append(d)
        }
        saveRemembered(remembered) // önce kaydet: işlem yarıda kalsa bile geri açılabilsin

        let targets = displays.filter { Self.isLit($0.id) }
        guard !targets.isEmpty else {
            Log.info("Kapatma atlandı (zaten kapalı): \(displays.map { $0.label }.joined(separator: ", "))")
            return true
        }
        let ok = switchDisplays(targets, enabled: false)
        Log.info("Fiziksel ekranlar devre dışı (\(lastBackend)): \(targets.map { $0.label }.joined(separator: ", ")) → \(ok ? "tamam" : "hata")")
        return ok
    }

    /// Yalnızca verilen ekranları etkinleştirir (diğerlerine dokunmaz) ve etkinleşenleri hatırlanan listeden çıkarır.
    @discardableResult
    func enable(_ displays: [PhysicalDisplayRecord]) -> Bool {
        let targets = displays.filter { !Self.isLit($0.id) }
        guard !targets.isEmpty else { return true }
        let ok = switchDisplays(targets, enabled: true)
        pollUntil(timeout: 0.5, interval: 0.02) { targets.allSatisfy { Self.isLit($0.id) } }
        let nowActive = targets.filter { Self.isLit($0.id) }
        var remembered = loadRemembered()
        remembered.removeAll { r in nowActive.contains { $0.id == r.id || $0.sameHardware(r) } }
        saveRemembered(remembered)
        Log.info("Etkinleştirildi (\(lastBackend)): \(targets.map { $0.label }.joined(separator: ", ")) → \(nowActive.count == targets.count ? "tamam" : "kısmen")")
        return ok && nowActive.count == targets.count
    }

    func isActive(_ id: UInt32) -> Bool { Self.isLit(id) }

    /// Ekran gerçekten görüntü veriyor mu? Bir ayna kümesinin (ör. sanal ekranın aynası) üyesi olan
    /// monitörler için CGDisplayIsActive 0 döner ama monitör AÇIKTIR; bu yüzden ayna üyeliği de sayılır.
    ///
    /// DİKKAT: boolean_t döndüren CGDisplayIs* fonksiyonları artık var olmayan (bağlantısı kesilmiş, uykudan
    /// sonra geçersizleşmiş) bir displayID için -1 döndürür. `!= 0` denetimi bunu "açık" sayıyordu; Uyku'dan
    /// sonra kapalı monitörler açık sanılıp hiç geri açılmıyordu. Yalnızca `> 0` doğrudur.
    static func isLit(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayIsOnline(id) > 0 && (CGDisplayIsActive(id) > 0 || CGDisplayIsInMirrorSet(id) > 0)
    }

    /// Bu oturumda en az bir fiziksel (yer tutucu olmayan, dahili olmayan) monitör görüntü veriyor mu?
    func anyPhysicalLit(excludedIDs: Set<UInt32>, excludedNames: [String]) -> Bool {
        !physicalDisplays(excludedIDs: excludedIDs, excludedNames: excludedNames, activeOnly: true).isEmpty
    }

    /// Acil kurtarma: hatırlanan tüm monitörleri ve verilen ek displayID'leri sistem API'siyle
    /// (BetterDisplay olmadan) etkinleştirmeyi dener. Devre dışı bırakılan ekranlar displayID'lerini korur.
    @discardableResult
    func forceEnable(extraIDs: [CGDirectDisplayID]) -> Bool {
        let online = Set(onlineDisplayIDs())
        let ids = Array(Set(loadRemembered().map { $0.id } + extraIDs.filter { online.contains($0) })).sorted().filter { !Self.isLit($0) }
        guard !ids.isEmpty, Self.isAvailable else { return false }
        var any = false
        for id in ids where configureBounded([id], enabled: true, wait: 3) { any = true }
        Log.info("Acil kurtarma (sistem API'si): \(ids.map(String.init).joined(separator: ", ")) → \(any ? "denendi" : "başarısız")")
        return any
    }

    /// Hatırlanan ve şu an etkin olmayan tüm fiziksel ekranları yeniden etkinleştirir.
    @discardableResult
    func enableAll(excludedIDs: Set<UInt32>, excludedNames: [String]) -> Bool {
        let online = onlineDisplayIDs()
        let onlineRecords = online.map { record(for: $0, names: [:]) }
        var targets = Set<CGDirectDisplayID>()

        for r in loadRemembered() where !r.isPlaceholder {
            if online.contains(r.id) {
                targets.insert(r.id)
            } else if let match = onlineRecords.first(where: { $0.sameHardware(r) }) {
                targets.insert(match.id) // displayID değişmiş
            } else {
                targets.insert(r.id) // çevrimiçi listede değil; yine de dene
            }
        }
        // Hatırlanmamış ama çevrimiçi ve etkin olmayan fiziksel ekranlar (ör. önceki oturumdan kalan).
        for r in physicalDisplays(excludedIDs: excludedIDs, excludedNames: excludedNames, activeOnly: false)
        where !Self.isLit(r.id) {
            targets.insert(r.id)
        }
        targets = targets.filter { !Self.isLit($0) }
        guard !targets.isEmpty else {
            forgetRemembered()
            return true
        }

        let remembered = loadRemembered()
        let targetRecords: [PhysicalDisplayRecord] = targets.map { id in
            if let r = onlineRecords.first(where: { $0.id == id }) { return r }
            if let r = remembered.first(where: { $0.id == id }) { return r }
            return record(for: id, names: [:])
        }
        _ = switchDisplays(targetRecords, enabled: true)
        pollUntil(timeout: 1, interval: 0.02) { targets.allSatisfy { Self.isLit($0) } }
        let stillOff = targets.filter { !Self.isLit($0) }
        if stillOff.isEmpty {
            forgetRemembered()
        } else {
            Log.error("Etkinleştirilemeyen ekranlar: \(stillOff.map { String($0) }.joined(separator: ", "))")
        }
        Log.info("Fiziksel ekranlar etkinleştirildi: \(targets.map { String($0) }.joined(separator: ", ")) → \(stillOff.isEmpty ? "tamam" : "kısmen")")
        return stillOff.isEmpty
    }
}

#else

/// macOS dışı derleme (yalnızca Linux'ta sözdizimi/tip denetimi için) — işlevsiz yer tutucu.
final class PhysicalDisplayController {
    static var isAvailable: Bool { false }
    static var apiDescription: String { L("yok") }
    var externalSwitch: (([PhysicalDisplayRecord], Bool) -> [PhysicalDisplayRecord])?
    var lastBackend: String { "—" }
    func physicalDisplays(excludedIDs: Set<UInt32>, excludedNames: [String], activeOnly: Bool) -> [PhysicalDisplayRecord] { [] }
    func rememberVirtualHardware(named virtualName: String, ids: Set<UInt32>) {}
    func isVirtualActive(named virtualName: String, ids: Set<UInt32>) -> Bool { false }
    func loadRemembered() -> [PhysicalDisplayRecord] { [] }
    func forgetRemembered() {}
    @discardableResult func disable(_ displays: [PhysicalDisplayRecord]) -> Bool { false }
    @discardableResult func enableAll(excludedIDs: Set<UInt32>, excludedNames: [String]) -> Bool { false }
    @discardableResult func enable(_ displays: [PhysicalDisplayRecord]) -> Bool { false }
    func isActive(_ id: UInt32) -> Bool { false }
    func activeDisplayIDs() -> [UInt32] { [] }
    func anyPhysicalLit(excludedIDs: Set<UInt32>, excludedNames: [String]) -> Bool { false }
    @discardableResult func forceEnable(extraIDs: [UInt32]) -> Bool { false }
    func wakeDisplaysIfNeeded(excludedIDs: Set<UInt32>, excludedNames: [String], wait: Bool = false) {}
    func onlineDisplayIDs() -> [UInt32] { [] }
}

#endif
