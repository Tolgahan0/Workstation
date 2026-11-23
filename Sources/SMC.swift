import Foundation
#if os(macOS)
import IOKit
#endif

// AppleSMC erişimi (uygulama ve wm-fanhelper ortak kullanır). Yalnızca Foundation + IOKit;
// Log vb. uygulama türlerine bağımlı DEĞİLDİR (helper tek başına derlenir).
//
// Apple Silicon notları (açık kaynak uygulamalardan: agoodkind/macos-smc-fan, exelban/stats):
//  - Fan anahtarları: FNum, F%dAc (gerçek), F%dMn, F%dMx, F%dTg (hedef) — Apple Silicon'da tür "flt "
//    (4 bayt, little-endian IEEE754), Intel'de "fpe2" (2 bayt big-endian, /4). Tür her seferinde okunur.
//  - Mod anahtarı nesle göre "F%dmd" (küçük harf) veya "F%dMd": hangisi varsa o kullanılır (1 = manuel).
//  - M1/M2'de mod anahtarına doğrudan yazma reddedilirse önce "Ftst"=1 (force test) yazılır, ~0,5 sn
//    beklenir, mod anahtarı yeniden denenir. Otomatiğe dönüşte mod=0 ve (başka manuel fan yoksa) Ftst=0.

// MARK: - SMC parametre yapısı (C'deki SMCKeyData_t ile birebir: 80 bayt)

struct SMCParamStruct {
    typealias Bytes32 = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

    struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct PLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = Version()
    var pLimitData = PLimitData()
    var keyInfo = KeyInfo()
    /// Swift, iç yapıyı (KeyInfo, 9 bayt) C gibi 12 bayta doldurmaz; bu alan C düzenini korur (result @40).
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes32 = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

enum SMCCommand: UInt8 {
    case kernelIndex = 2
    case readBytes = 5
    case writeBytes = 6
    case readIndex = 8
    case readKeyInfo = 9
}

enum SMCError: Error, CustomStringConvertible {
    case openFailed
    case ioKit(Int32)
    case firmware(UInt8)
    case badKey(String)
    case typeMismatch(String)

    var description: String {
        switch self {
        case .openFailed: return L("AppleSMC açılamadı")
        case .ioKit(let c): return L("IOKit hatası 0x%@", String(UInt32(bitPattern: c), radix: 16))
        case .firmware(let c): return L("SMC hatası 0x%@", String(c, radix: 16))
        case .badKey(let k): return L("geçersiz anahtar %@", k)
        case .typeMismatch(let t): return L("beklenmeyen veri türü %@", t)
        }
    }
}

// MARK: - Veri biçimleri (saf; Linux'ta test edilir)

enum SMCFormat {
    static func fourCC(_ s: String) -> UInt32? {
        let u = Array(s.utf8)
        guard u.count == 4 else { return nil }
        return u.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    static func typeString(_ code: UInt32) -> String {
        let b = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF), UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        return String(bytes: b, encoding: .ascii) ?? "????"
    }

    /// Türüne göre sayıya çevirir: flt, fpe2, sp78, fp88, ui8/16/32, si8/16.
    static func decode(_ bytes: [UInt8], type: String) -> Double? {
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4.0
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256.0
        case "fp88":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 256.0
        case "ui8 ", "si8 ", "flag":
            guard let b = bytes.first else { return nil }
            return type == "si8 " ? Double(Int8(bitPattern: b)) : Double(b)
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "si16":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1])))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        default:
            return nil
        }
    }

    /// Hedef RPM'i anahtarın kendi türünde kodlar (yalnızca flt ve fpe2 desteklenir — fan hedefleri).
    static func encodeRPM(_ value: Double, type: String, size: Int) -> [UInt8]? {
        switch type {
        case "flt ":
            guard size == 4 else { return nil }
            let bits = Float(value).bitPattern
            return [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF), UInt8((bits >> 16) & 0xFF), UInt8((bits >> 24) & 0xFF)]
        case "fpe2":
            guard size == 2 else { return nil }
            let raw = UInt16(max(0, min(16383, value * 4)).rounded())
            return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
        default:
            return nil
        }
    }

    static func tuple(_ array: [UInt8]) -> SMCParamStruct.Bytes32 {
        var p = Array(array.prefix(32))
        p += [UInt8](repeating: 0, count: 32 - p.count)
        return (p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8], p[9], p[10], p[11], p[12], p[13], p[14], p[15],
                p[16], p[17], p[18], p[19], p[20], p[21], p[22], p[23], p[24], p[25], p[26], p[27], p[28], p[29], p[30], p[31])
    }

    static func array(_ t: SMCParamStruct.Bytes32, count: Int) -> [UInt8] {
        var copy = t
        return withUnsafeBytes(of: &copy) { Array($0.prefix(max(0, min(32, count)))) }
    }
}

// MARK: - Fan modu ve hedef hesabı (saf)

enum FanMode: String, CaseIterable, Identifiable, Codable {
    case auto, half, max
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return L("Otomatik")
        case .half: return L("Yarım")
        case .max: return "Full Blast"
        }
    }

    /// Yarım = min + %50 (max − min); Full Blast = max. Her zaman [min, max] aralığına sıkıştırılır.
    func target(min mn: Double, max mx: Double) -> Double? {
        guard mx > 0, mx >= mn else { return nil }
        switch self {
        case .auto: return nil
        case .half: return Swift.max(mn, Swift.min(mx, mn + 0.5 * (mx - mn)))
        case .max: return mx
        }
    }
}

struct FanInfo: Codable, Equatable {
    var index: Int
    var actual: Double
    var minimum: Double
    var maximum: Double
    var target: Double
    var manual: Bool
}

struct FanStatus: Codable, Equatable {
    var fans: [FanInfo] = []
    var cpuTemp: Double?
    var gpuTemp: Double?
    var modeKey: String = ""
    var ftst: Bool = false
    var model: String = ""
    var error: String?
}

/// Apple Silicon nesillerine göre sıcaklık anahtarları (macos-smc-fan SensorCatalog'dan).
enum TemperatureKeys {
    static let m1cpu = ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"]
    static let m1gpu = ["Tg05", "Tg0D", "Tg0L", "Tg0T"]
    static let m2cpu = ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"]
    static let m2gpu = ["Tg0f", "Tg0j"]
    static let m3cpu = ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"]
    static let m3gpu = ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"]
    static let m4cpu = ["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"]
    static let m4gpu = ["Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"]
    static let m5cpu = ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"]
    static let m5gpu = ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"]
    static let intelCPU = ["TC0P", "TC0D", "TC0E", "TC0F", "TCAD"]
    static let intelGPU = ["TG0P", "TG0D", "TCGC"]

    /// hw.model önekine göre (cpu, gpu) aday listesi; bilinmiyorsa tüm listelerin birleşimi.
    static func candidates(model: String) -> (cpu: [String], gpu: [String]) {
        if model.hasPrefix("Mac17") { return (m5cpu, m5gpu) }
        if model.hasPrefix("Mac16") { return (m4cpu, m4gpu) }
        if model.hasPrefix("Mac15") || model.hasPrefix("Mac14") { return (m3cpu + m2cpu, m3gpu + m2gpu) }
        if model.hasPrefix("Mac13") { return (m2cpu + m1cpu, m2gpu + m1gpu) }
        if model.hasPrefix("Mac12") || model.hasPrefix("MacBookPro18") || model.hasPrefix("MacBookAir10") || model.hasPrefix("Macmini9") || model.hasPrefix("iMac21") {
            return (m1cpu, m1gpu)
        }
        return (allCPU, allGPU)
    }

    static var allCPU: [String] { unique(m5cpu + m4cpu + m3cpu + m2cpu + m1cpu + intelCPU) }
    static var allGPU: [String] { unique(m5gpu + m4gpu + m3gpu + m2gpu + m1gpu + intelGPU) }

    static func unique(_ a: [String]) -> [String] {
        var seen = Set<String>()
        return a.filter { seen.insert($0).inserted }
    }
}

func hardwareModelString() -> String {
    #if os(macOS)
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    guard size > 0 else { return "" }
    var buf = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &buf, &size, nil, 0)
    return String(cString: buf)
    #else
    return "Linux"
    #endif
}

#if os(macOS)

// MARK: - AppleSMC bağlantısı

final class SMCConnection {
    private var conn: io_connect_t = 0

    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.openFailed }
        defer { IOObjectRelease(service) }
        var c: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &c) == kIOReturnSuccess else { throw SMCError.openFailed }
        conn = c
    }

    deinit { if conn != 0 { IOServiceClose(conn) } }

    private func call(_ input: SMCParamStruct) throws -> SMCParamStruct {
        var inp = input
        var out = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(conn, UInt32(SMCCommand.kernelIndex.rawValue),
                                           &inp, MemoryLayout<SMCParamStruct>.stride, &out, &outSize)
        guard kr == kIOReturnSuccess else { throw SMCError.ioKit(kr) }
        return out
    }

    /// (boyut, tür) — anahtar yoksa hata.
    func keyInfo(_ key: String) throws -> (size: Int, type: String) {
        guard let code = SMCFormat.fourCC(key) else { throw SMCError.badKey(key) }
        var p = SMCParamStruct()
        p.key = code
        p.data8 = SMCCommand.readKeyInfo.rawValue
        let out = try call(p)
        guard out.result == 0 else { throw SMCError.firmware(out.result) }
        return (Int(out.keyInfo.dataSize), SMCFormat.typeString(out.keyInfo.dataType))
    }

    func exists(_ key: String) -> Bool {
        guard let info = try? keyInfo(key) else { return false }
        return info.size > 0
    }

    func read(_ key: String) throws -> (bytes: [UInt8], type: String) {
        let info = try keyInfo(key)
        guard let code = SMCFormat.fourCC(key) else { throw SMCError.badKey(key) }
        var p = SMCParamStruct()
        p.key = code
        p.keyInfo.dataSize = UInt32(info.size)
        p.data8 = SMCCommand.readBytes.rawValue
        let out = try call(p)
        guard out.result == 0 else { throw SMCError.firmware(out.result) }
        return (SMCFormat.array(out.bytes, count: info.size), info.type)
    }

    func readNumber(_ key: String) -> Double? {
        guard let r = try? read(key) else { return nil }
        return SMCFormat.decode(r.bytes, type: r.type)
    }

    /// Yalnızca bilinen boyutta yazar (boyut uyuşmazsa reddeder).
    func write(_ key: String, bytes: [UInt8]) throws {
        let info = try keyInfo(key)
        guard bytes.count == info.size else { throw SMCError.typeMismatch("\(key) \(info.type) boyut \(info.size) ≠ \(bytes.count)") }
        guard let code = SMCFormat.fourCC(key) else { throw SMCError.badKey(key) }
        var p = SMCParamStruct()
        p.key = code
        p.keyInfo.dataSize = UInt32(info.size)
        p.data8 = SMCCommand.writeBytes.rawValue
        p.bytes = SMCFormat.tuple(bytes)
        let out = try call(p)
        guard out.result == 0 else { throw SMCError.firmware(out.result) }
    }
}

// MARK: - Fan okuma / yazma

final class FanSMC {
    let smc: SMCConnection
    let model: String
    /// "F%dmd" veya "F%dMd" (hangisi varsa); yoksa boş.
    let modeFormat: String
    let hasFtst: Bool
    private var tempKeys: (cpu: [String], gpu: [String])?

    init() throws {
        let conn = try SMCConnection()
        var mf = ""
        for f in ["F%dmd", "F%dMd"] where conn.exists(String(format: f, 0)) {
            mf = f
            break
        }
        smc = conn
        model = hardwareModelString()
        modeFormat = mf
        hasFtst = conn.exists("Ftst")
    }

    static func key(_ format: String, _ i: Int) -> String { String(format: format, i) }

    var fanCount: Int {
        guard let n = smc.readNumber("FNum") else { return 0 }
        return Swift.max(0, Swift.min(8, Int(n)))
    }

    func info(_ i: Int) -> FanInfo? {
        guard let mn = smc.readNumber(Self.key("F%dMn", i)),
              let mx = smc.readNumber(Self.key("F%dMx", i)) else { return nil }
        let ac = smc.readNumber(Self.key("F%dAc", i)) ?? 0
        let tg = smc.readNumber(Self.key("F%dTg", i)) ?? 0
        var manual = false
        if !modeFormat.isEmpty, let md = smc.readNumber(Self.key(modeFormat, i)) { manual = md >= 1 }
        return FanInfo(index: i, actual: ac, minimum: mn, maximum: mx, target: tg, manual: manual)
    }

    /// Geçerli sıcaklık anahtarlarını bir kez bulur (5–125 °C arası okunanlar).
    private func resolveTempKeys() -> (cpu: [String], gpu: [String]) {
        if let k = tempKeys { return k }
        func valid(_ keys: [String]) -> [String] {
            keys.filter { k in
                guard let v = smc.readNumber(k) else { return false }
                return v > 5 && v < 125
            }
        }
        let c = TemperatureKeys.candidates(model: model)
        var cpu = valid(c.cpu)
        var gpu = valid(c.gpu)
        if cpu.count < 2 { cpu = valid(TemperatureKeys.allCPU) }
        if gpu.isEmpty { gpu = valid(TemperatureKeys.allGPU) }
        let r = (cpu, gpu)
        tempKeys = r
        return r
    }

    private func average(_ keys: [String]) -> Double? {
        let values = keys.compactMap { smc.readNumber($0) }.filter { $0 > 5 && $0 < 125 }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    func status() -> FanStatus {
        var s = FanStatus()
        s.model = model
        s.modeKey = modeFormat
        s.ftst = hasFtst ? ((smc.readNumber("Ftst") ?? 0) >= 1) : false
        s.fans = (0..<fanCount).compactMap { info($0) }
        let keys = resolveTempKeys()
        s.cpuTemp = average(keys.cpu)
        s.gpuTemp = average(keys.gpu)
        return s
    }

    // MARK: Yazma (root gerekir — yalnızca wm-fanhelper kullanır)

    private func setManual(_ i: Int) throws {
        guard !modeFormat.isEmpty else { throw SMCError.badKey("F\(i)md/Md") }
        let mk = Self.key(modeFormat, i)
        do {
            try smc.write(mk, bytes: [1])
            return
        } catch {
            guard hasFtst else { throw error }
        }
        // M1/M2: Ftst (force test) kilidi
        try smc.write("Ftst", bytes: [1])
        Thread.sleep(forTimeInterval: 0.5)
        let deadline = Date().addingTimeInterval(8)
        var last: Error = SMCError.firmware(0x82)
        while Date() < deadline {
            do {
                try smc.write(mk, bytes: [1])
                return
            } catch {
                last = error
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        throw last
    }

    /// Hedefi [Mn, Mx] aralığına sıkıştırıp yazar.
    func apply(_ mode: FanMode, fan i: Int) throws -> Double? {
        guard let f = info(i), let t = mode.target(min: f.minimum, max: f.maximum) else {
            try setAuto(i)
            return nil
        }
        let clamped = Swift.max(f.minimum, Swift.min(f.maximum, t))
        try setManual(i)
        let tk = Self.key("F%dTg", i)
        let ti = try smc.keyInfo(tk)
        guard let bytes = SMCFormat.encodeRPM(clamped, type: ti.type, size: ti.size) else {
            throw SMCError.typeMismatch("\(tk) \(ti.type)")
        }
        try smc.write(tk, bytes: bytes)
        return clamped
    }

    func setAuto(_ i: Int) throws {
        guard !modeFormat.isEmpty else { return }
        try smc.write(Self.key(modeFormat, i), bytes: [0])
    }

    /// Tüm fanları sisteme bırak, Ftst=0.
    func resetAll() -> [String] {
        var errors: [String] = []
        for i in 0..<fanCount {
            do { try setAuto(i) } catch { errors.append("F\(i): \(error)") }
        }
        if hasFtst, (smc.readNumber("Ftst") ?? 0) >= 1 {
            do { try smc.write("Ftst", bytes: [0]) } catch { errors.append("Ftst: \(error)") }
        }
        return errors
    }
}

#endif
