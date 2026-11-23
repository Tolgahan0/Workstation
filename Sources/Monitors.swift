import Foundation

/// Bir fiziksel monitörün çözümlenmiş hâli (CG kaydı + kararlı anahtar + IORegistry çıkışı + port).
struct ResolvedMonitor {
    var record: PhysicalDisplayRecord
    var key: String
    var port: String
    var outputPath: String?
}

#if os(macOS)
import AppKit
import CoreGraphics
import IOKit

// MARK: - Özel API'ler (dlsym ile, çalışma anında)

/// Apple Silicon DDC/CI: IOKit içindeki IOAVService fonksiyonları (MonitorControl vb. tarafından kullanılan).
private enum IOAV {
    typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> UnsafeMutableRawPointer?
    typealias I2CFn = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    static let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    static let create: CreateFn? = symbol("IOAVServiceCreateWithService")
    static let write: I2CFn? = symbol("IOAVServiceWriteI2C")
    static let read: I2CFn? = symbol("IOAVServiceReadI2C")

    private static func symbol<T>(_ name: String) -> T? {
        guard let h = handle, let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }
}

/// CoreDisplay_DisplayCreateInfoDictionary: ekranın IORegistry konumu (IODisplayLocation) ve EDID adı.
private enum CoreDisplayAPI {
    typealias InfoFn = @convention(c) (CGDirectDisplayID) -> UnsafeMutableRawPointer?
    static let info: InfoFn? = {
        guard let h = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY),
              let p = dlsym(h, "CoreDisplay_DisplayCreateInfoDictionary") else { return nil }
        return unsafeBitCast(p, to: InfoFn.self)
    }()

    static func infoDictionary(_ id: CGDirectDisplayID) -> [String: Any]? {
        guard let fn = info, let raw = fn(id) else { return nil }
        let dict = Unmanaged<CFDictionary>.fromOpaque(raw).takeRetainedValue()
        return dict as? [String: Any]
    }

    static func location(_ id: CGDirectDisplayID) -> String? {
        infoDictionary(id)?["IODisplayLocation"] as? String
    }

    /// DisplayProductName genellikle {"en_US": "DELL U2723QE"} biçimindedir.
    static func productName(_ id: CGDirectDisplayID) -> String? {
        guard let names = infoDictionary(id)?["DisplayProductName"] as? [String: String] else { return nil }
        return names["en_US"] ?? names.values.first
    }
}

/// IORegistry'de bulunan bir harici görüntü çıkışı (AppleCLCD2 framebuffer + DCPAVServiceProxy).
struct AVOutput {
    var framebufferPath: String
    var framebufferName: String
    var edidUUID: String
    var productName: String?
    var serial: UInt32?
    var upstream: String?
    var downstream: String?
    var parentNames: [String]
    var service: UnsafeMutableRawPointer?
}

/// Monitör başına bağımsız aç/kapa + parlaklık, kalıcı "istenen durum" ve yeniden uygulama.
final class MonitorManager {
    let physical: PhysicalDisplayController
    let store = MonitorStateStore()

    private let stateLock = NSLock()
    private let ddcLock = NSLock()
    private var lastResolved: [String: ResolvedMonitor] = [:]
    private var outputsByPath: [String: AVOutput] = [:]
    private var serviceCache: [String: UnsafeMutableRawPointer] = [:]
    private var ddcMax: [String: UInt16] = [:]
    private var ddcFailures: [String: Int] = [:]
    private var softwareDimmed: Set<UInt32> = []
    private var readAttempted: Set<String> = []
    private var correctionTimes: [Date] = []
    /// Bu oturumda DDC geri okuma doğrulaması yapılmış monitörler.
    private var ddcVerified: Set<String> = []

    init(physical: PhysicalDisplayController) {
        self.physical = physical
    }

    // MARK: IORegistry

    private static func regName(_ e: io_registry_entry_t) -> String {
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: 128)
        defer { buf.deallocate() }
        guard IORegistryEntryGetName(e, buf) == KERN_SUCCESS else { return "" }
        return String(cString: buf)
    }

    private static func className(_ e: io_object_t) -> String {
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: 128)
        defer { buf.deallocate() }
        guard IOObjectGetClass(e, buf) == KERN_SUCCESS else { return "" }
        return String(cString: buf)
    }

    private static func path(_ e: io_registry_entry_t) -> String {
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: 512)
        defer { buf.deallocate() }
        guard IORegistryEntryGetPath(e, kIOServicePlane, buf) == KERN_SUCCESS else { return "" }
        return String(cString: buf)
    }

    private static func property(_ e: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func parentNames(_ e: io_registry_entry_t, depth: Int = 8) -> [String] {
        var names: [String] = []
        var current = e
        IOObjectRetain(current)
        for _ in 0..<depth {
            var parent = io_registry_entry_t()
            let kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)
            guard kr == KERN_SUCCESS, parent != 0 else { return names }
            names.append(regName(parent))
            current = parent
        }
        IOObjectRelease(current)
        return names
    }

    /// Kayıt defterini sırayla dolaşır: AppleCLCD2/IOMobileFramebufferShim düğümünden sonra gelen
    /// ilk DCPAVServiceProxy onun AV servisidir (MonitorControl'ün kullandığı yöntem).
    private func scanOutputs() -> [AVOutput] {
        var outputs: [AVOutput] = []
        var iterator = io_iterator_t()
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane,
                                       IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var pending: AVOutput?
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            let name = Self.regName(entry)
            let cls = Self.className(entry)

            if cls.contains("AppleCLCD2") || cls.contains("IOMobileFramebufferShim") {
                var out = AVOutput(framebufferPath: Self.path(entry), framebufferName: name,
                                   edidUUID: (Self.property(entry, "EDID UUID") as? String) ?? "",
                                   productName: nil, serial: nil, upstream: nil, downstream: nil,
                                   parentNames: Self.parentNames(entry), service: nil)
                if let attrs = Self.property(entry, "DisplayAttributes") as? [String: Any],
                   let product = attrs["ProductAttributes"] as? [String: Any] {
                    out.productName = product["ProductName"] as? String
                    out.serial = (product["SerialNumber"] as? NSNumber)?.uint32Value
                }
                if let transport = Self.property(entry, "Transport") as? [String: Any] {
                    out.upstream = transport["Upstream"] as? String
                    out.downstream = transport["Downstream"] as? String
                }
                pending = out
            } else if name == "DCPAVServiceProxy" || cls == "DCPAVServiceProxy", var out = pending {
                pending = nil
                let location = Self.property(entry, "Location") as? String
                guard location == nil || location == "External" else { continue }
                out.parentNames += Self.parentNames(entry)
                if let cached = serviceCache[out.framebufferPath] {
                    out.service = cached
                } else if let create = IOAV.create, let svc = create(kCFAllocatorDefault, entry) {
                    serviceCache[out.framebufferPath] = svc
                    out.service = svc
                }
                outputs.append(out)
            }
        }
        return outputs
    }

    private func match(_ records: [PhysicalDisplayRecord], outputs: [AVOutput]) -> [UInt32: AVOutput] {
        var result: [UInt32: AVOutput] = [:]
        var used = Set<Int>()
        for r in records {
            let location = CoreDisplayAPI.location(r.id) ?? ""
            var best = -1
            var bestScore = 0
            for (i, o) in outputs.enumerated() where !used.contains(i) {
                var score = 0
                if !location.isEmpty, !o.framebufferPath.isEmpty,
                   location == o.framebufferPath || location.hasPrefix(o.framebufferPath) || o.framebufferPath.hasPrefix(location) {
                    score += 10
                }
                score += DisplayMatching.edidScore(edidUUID: o.edidUUID, vendor: r.vendor, model: r.model, serial: r.serial)
                if let pn = o.productName, !pn.isEmpty, pn == r.name { score += 1 }
                if let s = o.serial, s != 0, s == r.serial { score += 2 }
                if score > bestScore { bestScore = score; best = i }
            }
            if best >= 0 && bestScore >= 2 {
                used.insert(best)
                result[r.id] = outputs[best]
            }
        }
        return result
    }

    // MARK: Keşif

    /// Çevrimiçi fiziksel monitörler + kapatılmış (hatırlanan) monitörler.
    func discover(excludedIDs: Set<UInt32>, excludedNames: [String]) -> [ResolvedMonitor] {
        var records = physical.physicalDisplays(excludedIDs: excludedIDs, excludedNames: excludedNames, activeOnly: false)
        for r in physical.loadRemembered() where !records.contains(where: { $0.id == r.id || $0.sameHardware(r) }) {
            records.append(r)
        }
        records.sort { $0.id < $1.id }

        let outputs = scanOutputs()
        let matched = match(records, outputs: outputs)

        // İsim: NSScreen.localizedName → EDID ürün adı (IORegistry / CoreDisplay) → kayıtlı ad
        for i in records.indices where records[i].name.hasPrefix("Display ") {
            let id = records[i].id
            if let n = matched[id]?.productName ?? CoreDisplayAPI.productName(id), !n.isEmpty {
                records[i].name = n
            }
        }

        let keys = MonitorIdentity.uniqueKeys(for: records.map {
            (MonitorIdentity(vendor: $0.vendor, model: $0.model, serial: $0.serial),
             matched[$0.id]?.framebufferName ?? "id\($0.id)")
        })

        var resolved: [ResolvedMonitor] = []
        for (i, r) in records.enumerated() {
            let key = keys[i]
            var record = r
            let stored = store.state(for: key)
            if record.name.hasPrefix("Display "), let n = stored?.name, !n.isEmpty { record.name = n }
            let port: String
            if let o = matched[r.id] {
                port = DisplayMatching.portLabel(downstream: o.downstream, upstream: o.upstream,
                                                 parentNames: o.parentNames, framebufferName: o.framebufferName)
            } else {
                port = stored?.port ?? "Port bilinmiyor"
            }
            if stored?.name != record.name || stored?.port != port {
                store.update(key) { $0.name = record.name; $0.port = port }
            }
            resolved.append(ResolvedMonitor(record: record, key: key, port: port, outputPath: matched[r.id]?.framebufferPath))
        }

        stateLock.lock()
        lastResolved = Dictionary(uniqueKeysWithValues: resolved.map { ($0.key, $0) })
        for o in outputs { outputsByPath[o.framebufferPath] = o }
        stateLock.unlock()
        return resolved
    }

    private func cached(_ key: String) -> (ResolvedMonitor, AVOutput?)? {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let r = lastResolved[key] else { return nil }
        return (r, r.outputPath.flatMap { outputsByPath[$0] })
    }

    // MARK: Anlık görüntü (UI)

    func snapshot(excludedIDs: Set<UInt32>, excludedNames: [String]) -> [MonitorSnapshot] {
        let list = discover(excludedIDs: excludedIDs, excludedNames: excludedNames)
        return list.map { r in
            let id = r.record.id
            let active = physical.isActive(id)
            var desired = store.state(for: r.key) ?? DesiredMonitorState()
            let output = cached(r.key)?.1

            // Parlaklık hiç ayarlanmadıysa bir kez donanımdan oku.
            if desired.brightness == nil, active, let svc = output?.service, markReadAttempt(r.key),
               let value = ddcReadBrightness(svc, key: r.key) {
                desired = store.update(r.key) { $0.brightness = value }
            }

            return MonitorSnapshot(
                key: r.key, displayID: id, name: r.record.name, port: r.port,
                resolution: active ? Self.resolution(id) : "Kapalı",
                isActive: active, desiredEnabled: desired.enabled,
                brightness: desired.brightness ?? 100,
                brightnessMethod: brightnessMethod(key: r.key, output: output),
                forceSoftware: desired.forceSoftware ?? false,
                autoSoftware: desired.autoSoftware ?? false)
        }
    }

    private func markReadAttempt(_ key: String) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return readAttempted.insert(key).inserted
    }

    /// Monitörün şu anki parlaklık yöntemi (kaydırıcı hız sınırını seçmek için).
    func method(for key: String) -> BrightnessMethod {
        brightnessMethod(key: key, output: cached(key)?.1)
    }

    private func brightnessMethod(key: String, output: AVOutput?) -> BrightnessMethod {
        if store.state(for: key)?.forceSoftware == true { return .software }
        stateLock.lock(); defer { stateLock.unlock() }
        if output?.service == nil || IOAV.write == nil { return .software }
        return (ddcFailures[key] ?? 0) >= 3 ? .software : .ddc
    }

    private static func resolution(_ id: CGDirectDisplayID) -> String {
        guard let mode = CGDisplayCopyDisplayMode(id) else { return "—" }
        let hiDPI = mode.pixelWidth > mode.width
        var s = "\(mode.width)×\(mode.height)"
        if hiDPI { s += " HiDPI (\(mode.pixelWidth)×\(mode.pixelHeight))" }
        if mode.refreshRate > 0 { s += " · \(Int(mode.refreshRate.rounded())) Hz" }
        return s
    }

    // MARK: Aç / kapa

    /// Kullanıcı bir monitörü açtı/kapattı. İstenen durum kalıcı kaydedilir; yalnızca Masaüstü modunda
    /// hemen uygulanır (Remote/Uyku'da tüm fiziksel monitörler zaten kapalıdır).
    /// - Returns: Kullanıcıya gösterilecek not/hata (nil = sorun yok).
    func setDesiredEnabled(key: String, enabled: Bool, mode: WorkMode, virtualActive: Bool,
                           excludedIDs: Set<UInt32>, excludedNames: [String]) -> String? {
        let list = discover(excludedIDs: excludedIDs, excludedNames: excludedNames)
        guard let target = list.first(where: { $0.key == key }) else { return "Monitör bulunamadı" }

        if !enabled && mode == .desktop && !virtualActive {
            let othersActive = list.filter { $0.key != key && physical.isActive($0.record.id) }
            if othersActive.isEmpty && physical.isActive(target.record.id) {
                return "Son açık ekran kapatılamaz"
            }
        }
        store.update(key) { $0.enabled = enabled }
        Log.info("Monitör \(target.record.label) istenen durum: \(enabled ? "açık" : "kapalı")")

        guard mode == .desktop else { return "Kaydedildi — Masaüstü modunda uygulanacak" }
        logStates("önce", list)
        let alreadyThere = physical.isActive(target.record.id) == enabled
        if alreadyThere {
            Log.info("\(target.record.name) zaten \(enabled ? "açık" : "kapalı"); işlem yapılmadı.")
        } else if enabled {
            physical.enable([target.record])          // yalnızca bu monitör
        } else {
            physical.disable([target.record])         // yalnızca bu monitör
        }
        logStates("hemen sonra", list)

        // Doğrulama: yeniden yapılandırma flaşı geçtikten sonra (2 örnek, 0,6 sn arayla)
        // diğer monitörler istenen durumda değilse YALNIZCA onları tek seferde düzelt.
        Thread.sleep(forTimeInterval: 1.2)
        let fix = stableMismatches(list, mode: .desktop, samples: 2, gap: 0.6)
        logStates("1,8 sn sonra", list)
        if !fix.enable.isEmpty || !fix.disable.isEmpty {
            Log.warn("Son durum istenenden farklı → düzeltiliyor: aç=\(fix.enable.map { $0.record.name }) kapat=\(fix.disable.map { $0.record.name })")
            if !fix.enable.isEmpty { physical.enable(fix.enable.map { $0.record }) }
            if !fix.disable.isEmpty { physical.disable(fix.disable.map { $0.record }) }
            logStates("düzeltme sonrası", list)
        }
        if enabled, let b = store.state(for: key)?.brightness {
            _ = applyBrightness(key: key, percent: b)
        }
        return nil
    }

    /// Her monitörün anlık (CG) durumunu günlüğe yazar — tanılama için.
    private func logStates(_ stage: String, _ list: [ResolvedMonitor]) {
        let text = list.map { r -> String in
            let desired = store.state(for: r.key)?.enabled ?? true
            return "\(r.record.name)=\(physical.isActive(r.record.id) ? "açık" : "kapalı")(istenen \(desired ? "açık" : "kapalı"))"
        }.joined(separator: ", ")
        Log.info("Ekran durumu [\(stage)]: \(text)")
    }

    /// İstenen durumdan sapan monitörler; yalnızca TÜM örneklerde sapanlar döner
    /// (macOS'un yeniden yapılandırma sırasındaki geçici "karartma" anları yok sayılır).
    private func stableMismatches(_ list: [ResolvedMonitor], mode: WorkMode, samples: Int, gap: TimeInterval)
        -> (enable: [ResolvedMonitor], disable: [ResolvedMonitor]) {
        var enableKeys: Set<String>?
        var disableKeys: Set<String>?
        for i in 0..<max(1, samples) {
            if i > 0 { Thread.sleep(forTimeInterval: gap) }
            var e = Set<String>(), d = Set<String>()
            for r in list {
                let desiredOn = store.state(for: r.key)?.enabled ?? true
                let target = mode == .desktop ? desiredOn : false
                let active = physical.isActive(r.record.id)
                if target && !active { e.insert(r.key) }
                if !target && active { d.insert(r.key) }
            }
            enableKeys = enableKeys.map { $0.intersection(e) } ?? e
            disableKeys = disableKeys.map { $0.intersection(d) } ?? d
        }
        let en = list.filter { enableKeys?.contains($0.key) == true }
        let dis = list.filter { disableKeys?.contains($0.key) == true }
        return (en, dis)
    }

    // MARK: Uzlaştırma (istenen durumu geri uygula)

    /// İstenen durumu uygular:
    ///  - Masaüstü: her monitör kendi istenen durumuna (açık/kapalı) döner
    ///  - Remote/Uyku: tüm fiziksel monitörler kapalı
    /// Koruma: Masaüstü'nde son açık ekran kapatılmaz; Remote'da sanal ekran etkin değilse kapatılmaz.
    @discardableResult
    func reconcile(mode: WorkMode, virtualActive: Bool, applyBrightness: Bool,
                   excludedIDs: Set<UInt32>, excludedNames: [String]) -> [String] {
        var notes: [String] = []
        let list = discover(excludedIDs: excludedIDs, excludedNames: excludedNames)
        // Yalnızca istenen durumda OLMAYAN monitörlere dokunulur; geçici flaş anları için iki örnek alınır.
        let mismatch = stableMismatches(list, mode: mode, samples: 2, gap: 0.5)
        var toEnable: [ResolvedMonitor] = mismatch.enable
        var toDisable: [ResolvedMonitor] = mismatch.disable

        switch mode {
        case .sleep:
            break
        case .remote:
            if !toDisable.isEmpty && !virtualActive {
                notes.append("Sanal ekran etkin değil; fiziksel monitörler kapatılmadı")
                toDisable = []
            }
        case .desktop:
            let activeAfter = Set(list.filter { physical.isActive($0.record.id) }.map { $0.key })
                .subtracting(toDisable.map { $0.key })
                .union(toEnable.map { $0.key })
            if activeAfter.isEmpty, !list.isEmpty {
                // Hiç ekran kalmayacak: istenen durumu kapalı olsa da ilk monitörü açık tut/aç.
                if let keep = toDisable.first {
                    toDisable.removeFirst()
                    notes.append("\(keep.record.name) son ekran olduğu için açık bırakıldı")
                } else if let first = list.first {
                    toEnable.append(first)
                    notes.append("\(first.record.name) son ekran olduğu için açıldı")
                }
            }
        }

        if !toEnable.isEmpty || !toDisable.isEmpty {
            let now = Date()
            stateLock.lock()
            correctionTimes = correctionTimes.filter { now.timeIntervalSince($0) < 60 }
            let tooMany = correctionTimes.count >= 8
            if !tooMany { correctionTimes.append(now) }
            stateLock.unlock()
            if tooMany {
                Log.error("Uzlaştırma döngüsü algılandı (60 sn'de 8+ düzeltme); bu tur atlanıyor.")
                return notes + ["macOS ekranları sürekli değiştiriyor; düzeltme geçici olarak durduruldu"]
            }
            logStates("uzlaştırma öncesi", list)
            Log.info("Uzlaştırma (\(mode.rawValue)): aç=\(toEnable.map { $0.record.name }) kapat=\(toDisable.map { $0.record.name })")
            if !toEnable.isEmpty { physical.enable(toEnable.map { $0.record }) }
            if !toDisable.isEmpty { physical.disable(toDisable.map { $0.record }) }
        }

        if applyBrightness && mode == .desktop {
            for r in list where physical.isActive(r.record.id) {
                if let b = store.state(for: r.key)?.brightness {
                    _ = self.applyBrightness(key: r.key, percent: b)
                }
            }
        }
        notes.forEach { Log.info("Uzlaştırma notu: \($0)") }
        return notes
    }

    // MARK: Parlaklık

    /// Parlaklığı ayarlar ve istenen durum olarak kaydeder. (Kaydırıcı birleştiricisinin seri kuyruğunda çağrılır.)
    func setBrightness(key: String, percent: Double) -> BrightnessMethod {
        store.update(key) { $0.brightness = max(0, min(100, percent)) }
        return applyBrightness(key: key, percent: percent)
    }

    private func applyBrightness(key: String, percent: Double) -> BrightnessMethod {
        guard let c = cached(key) else { return .unknown }
        let r = c.0
        let output = c.1
        let id = r.record.id
        guard physical.isActive(id) else { return brightnessMethod(key: key, output: output) }

        if let svc = output?.service, brightnessMethod(key: key, output: output) == .ddc {
            stateLock.lock(); let maxV = ddcMax[key] ?? 100; let verified = ddcVerified.contains(key); stateLock.unlock()
            let raw = BrightnessCurve.ddcRawValue(slider: percent, max: maxV)
            if ddcWrite(svc, vcp: DDC.brightnessVCP, value: raw) {
                // Dock/adaptör arkasındaki monitörlerde yazma "başarılı" görünür ama iletilmez.
                // Oturumda bir kez geri okuyup doğrula; tutmuyorsa kalıcı olarak yazılıma geç.
                if !verified {
                    usleep(120_000)
                    let readBack = ddcReadRaw(svc, key: key)
                    let ok: Bool
                    if let rb = readBack {
                        let tolerance = max(2, Int(rb.max) / 25)
                        ok = abs(Int(rb.current) - Int(BrightnessCurve.ddcRawValue(slider: percent, max: rb.max))) <= tolerance
                    } else {
                        ok = false
                    }
                    stateLock.lock(); ddcVerified.insert(key); stateLock.unlock()
                    if !ok {
                        Log.warn("\(r.record.name): DDC yazması doğrulanamadı (geri okuma \(readBack.map { "\($0.current)/\($0.max)" } ?? "yok")) → yazılım karartmaya kalıcı olarak geçildi.")
                        store.update(key) { $0.forceSoftware = true; $0.autoSoftware = true }
                        return applySoftware(id: id, percent: percent)
                    }
                    Log.info("\(r.record.name): DDC parlaklık doğrulandı.")
                }
                stateLock.lock()
                ddcFailures[key] = 0
                let wasDimmed = softwareDimmed.remove(id) != nil
                stateLock.unlock()
                if wasDimmed { setSoftwareDim(id, factor: 1) }
                return .ddc
            }
            stateLock.lock()
            ddcFailures[key, default: 0] += 1
            let failures = ddcFailures[key] ?? 0
            stateLock.unlock()
            Log.warn("DDC yazma başarısız (\(r.record.name), \(failures). kez)\(failures >= 3 ? " → yazılım karartmaya geçiliyor" : "")")
            if failures >= 3 { store.update(key) { $0.forceSoftware = true; $0.autoSoftware = true } }
        }
        return applySoftware(id: id, percent: percent)
    }

    /// Yazılım karartma: gama tablosu ölçeği (tek çağrı, titreme yok; algısal eğri).
    private func applySoftware(id: CGDirectDisplayID, percent: Double) -> BrightnessMethod {
        let factor = BrightnessCurve.softwareFactor(slider: percent)
        setSoftwareDim(id, factor: factor)
        stateLock.lock()
        if factor < 0.999 { softwareDimmed.insert(id) } else { softwareDimmed.remove(id) }
        stateLock.unlock()
        return .software
    }

    private func setSoftwareDim(_ id: CGDirectDisplayID, factor: Double) {
        let f = CGGammaValue(max(0, min(1, factor)))
        let err = CGSetDisplayTransferByFormula(id, 0, f, 1, 0, f, 1, 0, f, 1)
        if err != .success { Log.error("CGSetDisplayTransferByFormula(\(id)) → \(err.rawValue)") }
    }

    /// Kullanıcı "yazılım karartma"yı zorlar veya DDC'yi yeniden denemek ister.
    func setForceSoftware(key: String, _ force: Bool) {
        store.update(key) { $0.forceSoftware = force; $0.autoSoftware = false }
        stateLock.lock()
        ddcFailures[key] = 0
        ddcVerified.remove(key) // DDC'ye dönülürse yeniden doğrula
        stateLock.unlock()
        if !force, let c = cached(key) { setSoftwareDim(c.0.record.id, factor: 1) }
        if let b = store.state(for: key)?.brightness { _ = applyBrightness(key: key, percent: b) }
    }

    // MARK: DDC/CI

    private func ddcWrite(_ svc: UnsafeMutableRawPointer, vcp: UInt8, value: UInt16) -> Bool {
        guard let write = IOAV.write else { return false }
        ddcLock.lock(); defer { ddcLock.unlock() }
        var packet = DDC.setVCPPacket(vcp: vcp, value: value)
        for _ in 0..<4 {
            var ok = false
            for _ in 0..<2 {
                usleep(10_000)
                let kr = packet.withUnsafeMutableBytes { buf -> IOReturn in
                    write(svc, DDC.chipAddress, DDC.dataAddress, buf.baseAddress!, UInt32(buf.count))
                }
                if kr == kIOReturnSuccess { ok = true }
            }
            if ok { return true }
            usleep(20_000)
        }
        return false
    }

    /// VCP 0x10 ham değerini okur (current, max). Maksimumu önbelleğe alır.
    private func ddcReadRaw(_ svc: UnsafeMutableRawPointer, key: String) -> (current: UInt16, max: UInt16)? {
        guard let write = IOAV.write, let read = IOAV.read else { return nil }
        ddcLock.lock(); defer { ddcLock.unlock() }
        var request = DDC.getVCPRequestPacket(vcp: DDC.brightnessVCP)
        for _ in 0..<3 {
            for _ in 0..<2 {
                usleep(10_000)
                _ = request.withUnsafeMutableBytes { buf in
                    write(svc, DDC.chipAddress, DDC.dataAddress, buf.baseAddress!, UInt32(buf.count))
                }
            }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 11)
            let kr = reply.withUnsafeMutableBytes { buf in
                read(svc, DDC.chipAddress, DDC.dataAddress, buf.baseAddress!, UInt32(buf.count))
            }
            if kr == kIOReturnSuccess, let v = DDC.parseGetVCPReply(reply, vcp: DDC.brightnessVCP) {
                stateLock.lock(); ddcMax[key] = v.max; stateLock.unlock()
                return v
            }
            usleep(20_000)
        }
        return nil
    }

    /// Kaydırıcı ölçeğinde (algısal eğri ters çevrilmiş) okunan parlaklık.
    private func ddcReadBrightness(_ svc: UnsafeMutableRawPointer, key: String) -> Double? {
        guard let v = ddcReadRaw(svc, key: key) else {
            Log.info("DDC okuma başarısız (\(key)); varsayılan %100 kabul edildi.")
            return nil
        }
        return BrightnessCurve.slider(fromDDC: v.current, max: v.max)
    }
}

#else

/// macOS dışı derleme için işlevsiz yer tutucu (Linux'ta tip denetimi).
final class MonitorManager {
    let physical: PhysicalDisplayController
    let store = MonitorStateStore()
    init(physical: PhysicalDisplayController) { self.physical = physical }
    func discover(excludedIDs: Set<UInt32>, excludedNames: [String]) -> [ResolvedMonitor] { [] }
    func snapshot(excludedIDs: Set<UInt32>, excludedNames: [String]) -> [MonitorSnapshot] { [] }
    func setDesiredEnabled(key: String, enabled: Bool, mode: WorkMode, virtualActive: Bool,
                           excludedIDs: Set<UInt32>, excludedNames: [String]) -> String? { "Desteklenmiyor" }
    @discardableResult
    func reconcile(mode: WorkMode, virtualActive: Bool, applyBrightness: Bool,
                   excludedIDs: Set<UInt32>, excludedNames: [String]) -> [String] { [] }
    func setBrightness(key: String, percent: Double) -> BrightnessMethod { .unknown }
    func setForceSoftware(key: String, _ force: Bool) {}
    func method(for key: String) -> BrightnessMethod { .unknown }
}

#endif
