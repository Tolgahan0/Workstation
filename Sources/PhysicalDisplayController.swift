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
}

#if os(macOS)
import AppKit
import CoreGraphics

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
            if CGDisplayIsBuiltin(id) != 0 { return nil }
            if excludedIDs.contains(id) { return nil }
            if activeOnly && CGDisplayIsActive(id) == 0 { return nil }
            let r = record(for: id, names: names)
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

    func loadRemembered() -> [PhysicalDisplayRecord] {
        guard let data = defaults.data(forKey: rememberedKey),
              let list = try? JSONDecoder().decode([PhysicalDisplayRecord].self, from: data) else { return [] }
        return list
    }

    private func saveRemembered(_ list: [PhysicalDisplayRecord]) {
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: rememberedKey) }
    }

    func forgetRemembered() { defaults.removeObject(forKey: rememberedKey) }

    // MARK: Devre dışı bırak / etkinleştir

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
        if let ext = externalSwitch {
            remaining = ext(displays, enabled)
            lastBackend = "BetterDisplay"
            if remaining.isEmpty { return true }
            Log.warn("BetterDisplay şu ekranları \(enabled ? "açamadı" : "kapatamadı"): \(remaining.map { $0.label }.joined(separator: ", ")) → sistem API'si deneniyor")
        }
        guard Self.isAvailable else { return false }
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
        guard !displays.isEmpty else { return true }
        var remembered = loadRemembered()
        for d in displays {
            remembered.removeAll { $0.id == d.id || $0.sameHardware(d) }
            remembered.append(d)
        }
        saveRemembered(remembered) // önce kaydet: işlem yarıda kalsa bile geri açılabilsin

        let targets = displays.filter { CGDisplayIsActive($0.id) != 0 }
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
        let targets = displays.filter { CGDisplayIsActive($0.id) == 0 }
        guard !targets.isEmpty else { return true }
        let ok = switchDisplays(targets, enabled: true)
        Thread.sleep(forTimeInterval: 0.5)
        let nowActive = targets.filter { CGDisplayIsActive($0.id) != 0 }
        var remembered = loadRemembered()
        remembered.removeAll { r in nowActive.contains { $0.id == r.id || $0.sameHardware(r) } }
        saveRemembered(remembered)
        Log.info("Etkinleştirildi (\(lastBackend)): \(targets.map { $0.label }.joined(separator: ", ")) → \(nowActive.count == targets.count ? "tamam" : "kısmen")")
        return ok && nowActive.count == targets.count
    }

    func isActive(_ id: UInt32) -> Bool { CGDisplayIsActive(id) != 0 }

    /// Hatırlanan ve şu an etkin olmayan tüm fiziksel ekranları yeniden etkinleştirir.
    @discardableResult
    func enableAll(excludedIDs: Set<UInt32>, excludedNames: [String]) -> Bool {
        let online = onlineDisplayIDs()
        let onlineRecords = online.map { record(for: $0, names: [:]) }
        var targets = Set<CGDirectDisplayID>()

        for r in loadRemembered() {
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
        where CGDisplayIsActive(r.id) == 0 {
            targets.insert(r.id)
        }
        targets = targets.filter { CGDisplayIsActive($0) == 0 }
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
        Thread.sleep(forTimeInterval: 1)
        let stillOff = targets.filter { CGDisplayIsActive($0) == 0 }
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
}

#endif
