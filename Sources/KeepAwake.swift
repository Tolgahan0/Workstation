import Foundation
#if os(macOS)
import IOKit.pwr_mgt
#endif

/// "Uyanık tut": IOPMAssertion (PreventUserIdleSystemSleep). Süre dolunca tek atımlık zamanlayıcı
/// bırakır (yoklama yok). Uygulama kapanınca macOS onayı otomatik bırakır.
final class KeepAwake {
    enum Duration: String, CaseIterable, Identifiable {
        case oneHour = "1h", threeHours = "3h", indefinite = "on"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .oneHour: return "1 sa"
            case .threeHours: return "3 sa"
            case .indefinite: return "Kapatana dek"
            }
        }
        var seconds: TimeInterval? {
            switch self {
            case .oneHour: return 3600
            case .threeHours: return 3 * 3600
            case .indefinite: return nil
            }
        }
        /// URL/CLI: "1h", "3h", "on", "90m", "2" (saat) …
        static func seconds(argument: String) -> TimeInterval?? {
            let a = argument.lowercased()
            if a == "on" || a == "true" || a.isEmpty { return .some(nil) }
            if a.hasSuffix("h"), let h = Double(a.dropLast()), h > 0 { return .some(h * 3600) }
            if a.hasSuffix("m"), let m = Double(a.dropLast()), m > 0 { return .some(m * 60) }
            if let h = Double(a), h > 0 { return .some(h * 3600) }
            return nil
        }
    }

    #if os(macOS)
    private var assertion: IOPMAssertionID = 0
    #endif
    private var expiryTimer: Timer?
    private(set) var isOn = false
    private(set) var until: Date?
    /// Durum değişince (ana iş parçacığında) çağrılır.
    var onChange: (() -> Void)?

    /// seconds nil = süresiz.
    func enable(seconds: TimeInterval?) {
        dispatchPrecondition(condition: .onQueue(.main))
        #if os(macOS)
        if assertion == 0 {
            var id: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "Workstation: Uyanık tut" as CFString, &id)
            guard r == kIOReturnSuccess else {
                Log.error("Uyanık tut: IOPMAssertion oluşturulamadı (\(r))")
                return
            }
            assertion = id
        }
        #endif
        isOn = true
        expiryTimer?.invalidate()
        expiryTimer = nil
        if let s = seconds {
            let end = Date().addingTimeInterval(s)
            until = end
            let t = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
                Log.info("Uyanık tut: süre doldu")
                self?.disable()
            }
            t.tolerance = 10
            RunLoop.main.add(t, forMode: .common)
            expiryTimer = t
        } else {
            until = nil
        }
        Log.info("Uyanık tut açık\(until.map { " (\($0) kadar)" } ?? " (süresiz)")")
        onChange?()
    }

    func disable() {
        dispatchPrecondition(condition: .onQueue(.main))
        expiryTimer?.invalidate()
        expiryTimer = nil
        #if os(macOS)
        if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        #endif
        let wasOn = isOn
        isOn = false
        until = nil
        if wasOn { Log.info("Uyanık tut kapalı") }
        onChange?()
    }
}
