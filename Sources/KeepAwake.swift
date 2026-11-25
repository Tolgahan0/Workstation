import Foundation
#if os(macOS)
import IOKit.pwr_mgt
#endif

/// "Uyanık tut": açıkken İKİ IOPMAssertion tutar:
///  - PreventUserIdleSystemSleep  → Mac boşta uyumaz
///  - PreventUserIdleDisplaySleep → ekran da boşta kararmaz (Masaüstü'nün `pmset displaysleep 15` ayarını da aşar)
/// Süreli modda bitiş zamanı duvar saatine göre tutulur (uyanınca / her 30 sn'de denetlenir), durum
/// UserDefaults'a yazılır: uygulama yeniden açılınca kalan süreyle (ya da süresiz) geri gelir.
/// `defaults write com.tolgahanayaz.workstationmode keepAwakeDebugSeconds -int 20` → 1 sa/3 sa yerine 20 sn (test).
final class KeepAwake {
    enum Duration: String, CaseIterable, Identifiable {
        case oneHour = "1h", threeHours = "3h", indefinite = "on"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .oneHour: return L("1 sa")
            case .threeHours: return L("3 sa")
            case .indefinite: return L("Kapatana dek")
            }
        }
        var seconds: TimeInterval? {
            switch self {
            case .oneHour: return KeepAwake.debugSeconds ?? 3600
            case .threeHours: return KeepAwake.debugSeconds.map { $0 * 3 } ?? 3 * 3600
            case .indefinite: return nil
            }
        }
        /// Saniyeye karşılık gelen segment (URL/CLI'dan gelen değer için); eşleşme yoksa nil.
        static func matching(seconds: TimeInterval?) -> Duration? {
            allCases.first { $0.seconds == seconds }
        }
        /// URL/CLI: "1h", "3h", "on", "90m", "2" (saat) …
        static func seconds(argument: String) -> TimeInterval?? {
            let a = argument.lowercased()
            if a == "on" || a == "true" || a.isEmpty { return .some(nil) }
            if a == "1h" { return .some(Duration.oneHour.seconds) }
            if a == "3h" { return .some(Duration.threeHours.seconds) }
            if a.hasSuffix("h"), let h = Double(a.dropLast()), h > 0 { return .some(h * 3600) }
            if a.hasSuffix("m"), let m = Double(a.dropLast()), m > 0 { return .some(m * 60) }
            if a.hasSuffix("s"), let s = Double(a.dropLast()), s > 0 { return .some(s) }
            if let h = Double(a), h > 0 { return .some(h * 3600) }
            return nil
        }
    }

    static var debugSeconds: TimeInterval? {
        let v = UserDefaults.standard.double(forKey: "keepAwakeDebugSeconds")
        return v > 0 ? v : nil
    }

    private static let onKey = "keepAwakeOn"
    private static let untilKey = "keepAwakeUntil"          // 1970'ten saniye; 0 = süresiz
    static let durationKey = "keepAwakeDuration"

    #if os(macOS)
    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    #endif
    private var ticker: Timer?
    private(set) var isOn = false
    private(set) var until: Date?
    /// Durum değişince ve süreli modda her 30 sn'de (kalan süre için) ana iş parçacığında çağrılır.
    var onChange: (() -> Void)?

    static var savedDuration: Duration {
        Duration(rawValue: UserDefaults.standard.string(forKey: durationKey) ?? "") ?? .oneHour
    }

    /// Kalan süre (süresizse nil).
    var remaining: TimeInterval? { until.map { max(0, $0.timeIntervalSinceNow) } }

    /// seconds nil = süresiz. Açıkken yeniden çağrılırsa süre yeniden kurulur, onaylar yeniden oluşturulmaz.
    func enable(seconds: TimeInterval?) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard createAssertions() else { return }
        isOn = true
        until = seconds.map { Date().addingTimeInterval($0) }
        persist()
        armTicker()
        Log.info("Uyanık tut açık\(until.map { " (\(Self.clock($0))'e kadar)" } ?? " (süresiz)")")
        onChange?()
    }

    func disable(reason: String? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        ticker?.invalidate()
        ticker = nil
        releaseAssertions()
        let wasOn = isOn
        isOn = false
        until = nil
        persist()
        if wasOn { Log.info("Uyanık tut kapalı\(reason.map { " (\($0))" } ?? "")") }
        onChange?()
    }

    /// Açılışta: önceki oturumdan kalan durumu geri yükler (süresi dolmuşsa kapalı kalır).
    func restore() {
        let d = UserDefaults.standard
        guard d.bool(forKey: Self.onKey) else { return }
        let u = d.double(forKey: Self.untilKey)
        if u <= 0 {
            Log.info("Uyanık tut geri yüklendi (süresiz)")
            enable(seconds: nil)
        } else if u > Date().timeIntervalSince1970 + 1 {
            Log.info("Uyanık tut geri yüklendi")
            enable(seconds: u - Date().timeIntervalSince1970)
        } else {
            disable(reason: L("süre uygulama kapalıyken doldu"))
        }
    }

    /// Uyanınca / zamanlayıcıda: duvar saatine göre süre dolduysa kapatır.
    func checkExpiry() {
        guard isOn, let u = until else { return }
        if u.timeIntervalSinceNow <= 0.5 {
            disable(reason: L("süre doldu"))
        } else {
            armTicker()
            onChange?()
        }
    }

    // MARK: İç

    private func armTicker() {
        ticker?.invalidate()
        ticker = nil
        guard let u = until else { return }
        // Bitişe kadar en fazla 30 sn'lik adımlar: kalan süre güncel kalır, bitiş en çok ~1 sn gecikir.
        let step = min(30, max(0.5, u.timeIntervalSinceNow))
        let t = Timer(timeInterval: step, repeats: false) { [weak self] _ in self?.checkExpiry() }
        t.tolerance = min(2, step / 10)
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(isOn, forKey: Self.onKey)
        d.set(until?.timeIntervalSince1970 ?? 0, forKey: Self.untilKey)
    }

    private func createAssertions() -> Bool {
        #if os(macOS)
        let name = L("Workstation: Uyanık tut") as CFString
        func make(_ type: String, _ id: inout IOPMAssertionID) -> Bool {
            guard id == 0 else { return true }
            var new: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), name, &new)
            guard r == kIOReturnSuccess else {
                Log.error("Uyanık tut: IOPMAssertion (\(type)) oluşturulamadı (\(r))")
                return false
            }
            id = new
            return true
        }
        guard make(kIOPMAssertionTypePreventUserIdleSystemSleep, &systemAssertion),
              make(kIOPMAssertionTypePreventUserIdleDisplaySleep, &displayAssertion) else {
            releaseAssertions()
            return false
        }
        #endif
        return true
    }

    private func releaseAssertions() {
        #if os(macOS)
        if systemAssertion != 0 { IOPMAssertionRelease(systemAssertion); systemAssertion = 0 }
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
        #endif
    }

    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    /// "2 sa 14 dk" / "2h 14m"; 1 dk'nın altı "<1 dk".
    static func format(remaining s: TimeInterval) -> String {
        if s < 60 { return L("%@ sn", String(Int(s.rounded(.up)))) }
        let mins = Int((s / 60).rounded(.up))
        let h = mins / 60, m = mins % 60
        if h == 0 { return L("%@ dk", String(m)) }
        if m == 0 { return L("%@ sa", String(h)) }
        return L("%@ sa %@ dk", String(h), String(m))
    }
}
