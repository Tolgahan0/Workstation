import Foundation

// MARK: - Modlar

enum WorkMode: String, CaseIterable {
    case desktop, sleep, remote

    var title: String {
        switch self {
        case .desktop: return "Masaüstü"
        case .sleep: return "Uyku"
        case .remote: return "Remote"
        }
    }

    var symbolName: String {
        switch self {
        case .desktop: return "display.2"
        case .sleep: return "moon.zzz.fill"
        case .remote: return "laptopcomputer.and.iphone"
        }
    }

    var keyEquivalent: String {
        switch self {
        case .desktop: return "1"
        case .sleep: return "2"
        case .remote: return "3"
        }
    }

    /// "remote", "Remote", "dışarı", "night" vb. girdileri moda çevirir.
    init?(argument: String) {
        let a = argument.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/ \n\t"))
        switch a {
        case "desktop", "masaustu", "masaüstü", "normal": self = .desktop
        case "sleep", "night", "uyku", "gece": self = .sleep
        case "remote", "away", "disari", "dışarı", "macbook", "mbp": self = .remote
        default: return nil
        }
    }
}

// MARK: - Monitör modeli (yalnızca Foundation; Linux'ta da derlenir)

/// Parlaklığın nasıl uygulandığı.
enum BrightnessMethod: String, Codable {
    case ddc        // Donanım: DDC/CI (IOAVService üzerinden VCP 0x10)
    case software   // Yazılım: gama ile karartma (CGSetDisplayTransferByFormula)
    case unknown
}

/// Monitörün kararlı kimliği. displayID değişebilir; vendor+model+seri değişmez.
/// Aynı model iki monitörde (seri 0 veya aynı) port etiketi ayırt edici olarak eklenir.
struct MonitorIdentity: Equatable {
    var vendor: UInt32
    var model: UInt32
    var serial: UInt32

    var baseKey: String { String(format: "%04X-%04X-%08X", vendor, model, serial) }

    /// Çakışma varsa (aynı baseKey'e sahip birden çok monitör) port/sıra eki eklenir.
    static func uniqueKeys(for identities: [(identity: MonitorIdentity, tiebreak: String)]) -> [String] {
        var counts: [String: Int] = [:]
        for i in identities { counts[i.identity.baseKey, default: 0] += 1 }
        var used = Set<String>()
        return identities.map { item in
            let base = item.identity.baseKey
            var key = (counts[base] ?? 0) > 1 ? "\(base)@\(item.tiebreak)" : base
            var n = 2
            while used.contains(key) { key = "\(base)@\(item.tiebreak)#\(n)"; n += 1 }
            used.insert(key)
            return key
        }
    }
}

/// Kullanıcının monitör başına İSTEDİĞİ durum. Uyanma/yeniden bağlanma sonrası bu durum geri uygulanır.
struct DesiredMonitorState: Codable, Equatable {
    var enabled: Bool = true
    /// 0–100. nil = henüz ayarlanmadı (donanımdan okunur).
    var brightness: Double?
    var name: String = ""
    var port: String?
    /// true: DDC denenmez, parlaklık yazılımla (gama) ayarlanır.
    var forceSoftware: Bool?
    /// true: yazılım karartmaya DDC geri okuma doğrulaması başarısız olduğu için OTOMATİK geçildi.
    var autoSoftware: Bool?
}

/// UI'a verilen anlık görüntü.
struct MonitorSnapshot: Identifiable, Equatable {
    var key: String
    var displayID: UInt32
    var name: String
    var port: String
    var resolution: String
    var isActive: Bool
    var desiredEnabled: Bool
    var brightness: Double
    var brightnessMethod: BrightnessMethod
    var forceSoftware: Bool
    var autoSoftware: Bool

    var id: String { key }
}

/// İstenen durumları UserDefaults'ta (JSON) saklar. İş parçacığı güvenli.
final class MonitorStateStore {
    private let key = "monitorDesiredStates"
    private let lock = NSLock()
    private let defaults: UserDefaults
    private var cache: [String: DesiredMonitorState]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: DesiredMonitorState].self, from: data) {
            cache = decoded
        } else {
            cache = [:]
        }
    }

    func state(for k: String) -> DesiredMonitorState? {
        lock.lock(); defer { lock.unlock() }
        return cache[k]
    }

    /// Kayıt yoksa varsayılanla (açık) oluşturur, değiştirir ve kaydeder.
    @discardableResult
    func update(_ k: String, _ mutate: (inout DesiredMonitorState) -> Void) -> DesiredMonitorState {
        lock.lock(); defer { lock.unlock() }
        var s = cache[k] ?? DesiredMonitorState()
        mutate(&s)
        cache[k] = s
        if let data = try? JSONEncoder().encode(cache) { defaults.set(data, forKey: key) }
        return s
    }

    func all() -> [String: DesiredMonitorState] {
        lock.lock(); defer { lock.unlock() }
        return cache
    }
}

// MARK: - DDC/CI paketleri

/// DDC/CI (VESA MCCS) paket yardımcıları. Apple Silicon'da IOAVServiceWriteI2C/ReadI2C ile
/// I²C adresi 0x37'ye, veri ofseti (kaynak adresi) 0x51 ile gönderilir.
enum DDC {
    static let chipAddress: UInt32 = 0x37
    static let dataAddress: UInt32 = 0x51
    static let brightnessVCP: UInt8 = 0x10

    static func checksum(initial: UInt8, _ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(initial) { $0 ^ $1 }
    }

    /// Set VCP: [0x84, 0x03, vcp, değer_yüksek, değer_düşük, sağlama]
    /// Sağlama = 0x6E ^ 0x51 ^ diğer baytlar (hedef 0x6E, kaynak 0x51).
    static func setVCPPacket(vcp: UInt8, value: UInt16) -> [UInt8] {
        var p: [UInt8] = [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF)]
        p.append(checksum(initial: 0x6E ^ 0x51, p))
        return p
    }

    /// Get VCP isteği: [0x82, 0x01, vcp, sağlama]. (Pratikte çalışan MonitorControl uygulamasıyla
    /// aynı biçimde sağlama başlangıcı 0x6E kullanılır.)
    static func getVCPRequestPacket(vcp: UInt8) -> [UInt8] {
        var p: [UInt8] = [0x82, 0x01, vcp]
        p.append(checksum(initial: 0x6E, p))
        return p
    }

    /// Get VCP yanıtı (11 bayt): [0x6E, 0x88, 0x02, sonuç, vcp, tür, maxH, maxL, curH, curL, sağlama]
    /// Sağlama başlangıcı 0x50.
    static func parseGetVCPReply(_ r: [UInt8], vcp: UInt8) -> (current: UInt16, max: UInt16)? {
        guard r.count >= 11 else { return nil }
        guard checksum(initial: 0x50, Array(r[0..<10])) == r[10] else { return nil }
        guard r[2] == 0x02, r[3] == 0x00, r[4] == vcp else { return nil }
        let maxV = UInt16(r[6]) << 8 | UInt16(r[7])
        let cur = UInt16(r[8]) << 8 | UInt16(r[9])
        guard maxV > 0 else { return nil }
        return (cur, maxV)
    }
}

// MARK: - IORegistry eşleştirme yardımcıları

enum DisplayMatching {
    /// "EDID UUID" (ör. 10AC2EA1-0000-0000-2C1E-0104B53C2278) ile CG vendor/model eşleşme puanı.
    /// İlk 4 hex = vendor, sonraki 4 hex = model (küçük-endian, bayt sırası ters).
    static func edidScore(edidUUID: String, vendor: UInt32, model: UInt32, serial: UInt32) -> Int {
        let u = edidUUID.uppercased().replacingOccurrences(of: "-", with: "")
        guard u.count >= 8 else { return 0 }
        var score = 0
        let vendorHex = String(format: "%04X", vendor & 0xFFFF)
        let modelSwapped = String(format: "%02X%02X", model & 0xFF, (model >> 8) & 0xFF)
        let modelPlain = String(format: "%04X", model & 0xFFFF)
        if u.hasPrefix(vendorHex) { score += 1 }
        let m = String(u.dropFirst(4).prefix(4))
        if m == modelSwapped || m == modelPlain { score += 1 }
        if serial != 0 {
            let s = serial
            let serialSwapped = String(format: "%02X%02X%02X%02X", s & 0xFF, (s >> 8) & 0xFF, (s >> 16) & 0xFF, (s >> 24) & 0xFF)
            if u.contains(serialSwapped) || u.contains(String(format: "%08X", s)) { score += 1 }
        }
        return score
    }

    /// Port etiketi (en iyi tahmin).
    /// - downstream/upstream: AppleCLCD2 "Transport" sözlüğü (ör. Upstream "DP", Downstream "HDMI")
    /// - parentNames: DCPAVServiceProxy'den yukarı doğru IORegistry düğüm adları (ör. "atc1", "dispext0")
    static func portLabel(downstream: String?, upstream: String?, parentNames: [String], framebufferName: String?) -> String {
        let all = (parentNames + [framebufferName ?? ""]).map { $0.lowercased() }
        var atcIndex: Int?
        for n in all {
            if let r = n.range(of: #"atc(\d+)"#, options: .regularExpression) {
                atcIndex = Int(n[r].dropFirst(3)); break
            }
        }
        let down = (downstream ?? "").uppercased()
        let up = (upstream ?? "").uppercased()
        var dispext: String?
        for n in all {
            if let r = n.range(of: #"dispext\d+"#, options: .regularExpression) { dispext = String(n[r]); break }
        }
        let suffix = dispext.map { " · \($0)" } ?? ""
        if down.contains("HDMI") || all.contains(where: { $0.contains("hdmi") }) {
            return "HDMI" + suffix
        }
        if let i = atcIndex {
            return "USB-C / Thunderbolt \(i + 1)" + suffix
        }
        if up.contains("DP") || down.contains("DP") {
            return "USB-C / Thunderbolt (DP)" + suffix
        }
        return (dispext != nil ? "Harici" : "Bilinmeyen port") + suffix
    }
}

// MARK: - Parlaklık eğrileri

/// Kaydırıcı değeri (0–100, algısal) → donanım/yazılım değeri.
enum BrightnessCurve {
    /// DDC: monitör arka ışığı yaklaşık doğrusal ışıklıktır; algısal eşitlik için üs 1.6.
    static let ddcExponent = 1.6

    static func ddcFraction(slider: Double) -> Double {
        pow(max(0, min(100, slider)) / 100, ddcExponent)
    }

    static func ddcRawValue(slider: Double, max maxV: UInt16) -> UInt16 {
        UInt16((ddcFraction(slider: slider) * Double(maxV)).rounded())
    }

    /// Ters dönüşüm (geri okunan ham değer → kaydırıcı).
    static func slider(fromDDC raw: UInt16, max maxV: UInt16) -> Double {
        guard maxV > 0 else { return 100 }
        let f = max(0, min(1, Double(raw) / Double(maxV)))
        return pow(f, 1 / ddcExponent) * 100
    }

    /// Yazılım (gama tablosu) ölçek çarpanı. Alt sınır 0.08 (ekran tamamen kararmasın).
    /// Gama tablosu kodlanmış değeri ölçtüğünden algısal olarak yaklaşık doğrusaldır; hafif eğri yeterli.
    static let softwareFloor = 0.08
    static func softwareFactor(slider: Double) -> Double {
        let s = max(0, min(100, slider)) / 100
        return softwareFloor + (1 - softwareFloor) * pow(s, 1.25)
    }
}

// MARK: - Remote çözünürlük ön ayarları

struct RemotePreset: Identifiable, Equatable {
    let id: String
    let title: String
    let width: Int
    let height: Int

    var resolution: String { "\(width)x\(height)" }

    /// Varsayılan "looks like" (HiDPI) çözünürlükleri (Apple Silicon modelleri).
    static let auto = RemotePreset(id: "auto", title: "Otomatik", width: 0, height: 0)
    static let all: [RemotePreset] = [
        auto,
        RemotePreset(id: "mba13", title: "MacBook Air 13\"", width: 1470, height: 956),
        RemotePreset(id: "mba15", title: "MacBook Air 15\"", width: 1710, height: 1107),
        RemotePreset(id: "mbp14", title: "MacBook Pro 14\"", width: 1512, height: 982),
        RemotePreset(id: "mbp16", title: "MacBook Pro 16\"", width: 1728, height: 1117),
        RemotePreset(id: "imac24", title: "iMac 24\"", width: 2240, height: 1260),
    ]
    static let fallback = all.first { $0.id == "mbp14" }!

    static func preset(id: String) -> RemotePreset? { all.first { $0.id == id } }

    static func preset(matching resolution: String) -> RemotePreset? {
        all.first { $0.id != "auto" && $0.resolution == resolution }
    }

    /// "1512x982", "1512 x 982" vb. biçimleri doğrular/normalleştirir.
    static func normalize(_ text: String) -> String? {
        let t = text.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "×", with: "x")
        let parts = t.split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]),
              (640...7680).contains(w), (400...4320).contains(h) else { return nil }
        return "\(w)x\(h)"
    }

    /// En-boy oranı: gcd ile sadeleştirilir; sayılar büyükse (ör. 1512x982 → 756:491) BetterDisplay'in
    /// kabul edeceği küçük bir orana (≤32) yaklaştırılır (1512x982 → 20:13, 1728x1117 → 17:11, 2240x1260 → 16:9).
    static func aspect(of resolution: String) -> (Int, Int)? {
        guard let n = normalize(resolution) else { return nil }
        let p = n.split(separator: "x").compactMap { Int($0) }
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let g = gcd(p[0], p[1])
        let (w, h) = (p[0] / g, p[1] / g)
        if w <= 32 && h <= 32 { return (w, h) }
        let ratio = Double(p[0]) / Double(p[1])
        var best = (16, 10)
        var bestErr = Double.infinity
        for hh in 1...32 {
            for ww in hh...max(hh, 64) where ww <= 32 {
                let err = abs(Double(ww) / Double(hh) - ratio)
                if err < bestErr - 1e-9 { bestErr = err; best = (ww, hh) }
            }
        }
        return best
    }
}

/// Remote çözünürlük seçimi (UserDefaults).
enum RemoteResolution {
    static let presetKey = "remotePreset"
    static let lastClientKey = "lastClientResolution"

    static var selectedPresetID: String {
        get { UserDefaults.standard.string(forKey: presetKey) ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: presetKey) }
    }

    /// İstemciden (workstation-connect / URL ?res=) gelen son çözünürlük.
    static var lastClientResolution: String? {
        get { UserDefaults.standard.string(forKey: lastClientKey).flatMap(RemotePreset.normalize) }
        set { UserDefaults.standard.set(newValue, forKey: lastClientKey) }
    }

    /// Kullanılacak çözünürlük: istek geçersiz kılması → seçili ön ayar → (Otomatik) son istemci → 14".
    static func effective(override: String? = nil) -> String {
        if let o = override.flatMap(RemotePreset.normalize) { return o }
        if let p = RemotePreset.preset(id: selectedPresetID), p.id != "auto" { return p.resolution }
        return lastClientResolution ?? RemotePreset.fallback.resolution
    }
}

// MARK: - Geri sayım ayarı

/// Uyku / Remote başlamadan önceki geri sayım süresi (sn). 0 = kapalı, varsayılan 3.
enum CountdownSettings {
    static let key = "countdownSeconds"
    static let defaultSeconds = 3

    static var seconds: Int {
        get {
            guard UserDefaults.standard.object(forKey: key) != nil else { return defaultSeconds }
            return max(0, min(10, UserDefaults.standard.integer(forKey: key)))
        }
        set { UserDefaults.standard.set(max(0, min(10, newValue)), forKey: key) }
    }
}

// MARK: - Fiziksel ekran kesme yöntemi

/// Ayarlar > Ekran kontrolü. Otomatik = BetterDisplay kurulu ve CLI açıksa BetterDisplay, değilse sistem API'si.
enum PhysicalMethod: String, CaseIterable, Identifiable {
    case auto, betterDisplay = "betterdisplay", system

    static let key = "physicalDisplayMethod"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Otomatik"
        case .betterDisplay: return "BetterDisplay"
        case .system: return "macOS"
        }
    }

    static var preference: PhysicalMethod {
        get {
            let raw = (UserDefaults.standard.string(forKey: key) ?? "auto").lowercased()
            if raw == "cgs" || raw == "native" { return .system }
            return PhysicalMethod(rawValue: raw) ?? .auto
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

/// Ayarlar sayfasındaki bilgi ızgarası (arka planda toplanır, ana iş parçacığında gösterilir).
struct SettingsInfo: Equatable {
    var method: String = "—"
    var betterDisplay: String = "—"
    var virtualScreen: String = "—"
    var monitors: String = "—"
    var power: String = "—"
}

/// `pmset -g` çıktısından kısa güç profili özeti (ör. "uyku kapalı · ekran 15 dk · düşük güç kapalı").
enum PmsetSummary {
    static func parse(_ text: String) -> String {
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2 else { continue }
            values[parts[0]] = parts[1]
        }
        var out: [String] = []
        if let v = values["sleep"] { out.append(v == "0" ? "Mac uyumaz" : "Mac \(v) dk sonra uyur") }
        if let v = values["displaysleep"] { out.append(v == "0" ? "ekran kararmaz" : "ekran \(v) dk sonra kararır") }
        if let lp = values["lowpowermode"] { out.append(lp == "1" ? "enerji tasarrufu açık" : "enerji tasarrufu kapalı") }
        return out.isEmpty ? "—" : out.joined(separator: " · ")
    }
}
