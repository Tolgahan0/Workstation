import Foundation
#if os(macOS)
import UserNotifications
#endif

/// Ayarlar › Bildirimler (hepsi varsayılan açık).
struct NotificationSettings: Codable, Equatable {
    var overheat = true
    var lowDisk = true
    var unexpectedExit = true
    var memoryPressure = true

    static let key = "notificationSettings"

    init() {}

    /// Eski kayıtlarda olmayan alanlar varsayılanı alır (yeni alan eklemek ayarları sıfırlamasın).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        overheat = try c.decodeIfPresent(Bool.self, forKey: .overheat) ?? true
        lowDisk = try c.decodeIfPresent(Bool.self, forKey: .lowDisk) ?? true
        unexpectedExit = try c.decodeIfPresent(Bool.self, forKey: .unexpectedExit) ?? true
        memoryPressure = try c.decodeIfPresent(Bool.self, forKey: .memoryPressure) ?? true
    }

    static func load(_ d: UserDefaults = .standard) -> NotificationSettings {
        guard let data = d.data(forKey: key), let s = try? JSONDecoder().decode(NotificationSettings.self, from: data) else {
            return NotificationSettings()
        }
        return s
    }

    func save(_ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key) }
    }
}

/// Saf kurallar (Linux'ta test edilir).
enum NotificationPolicy {
    static let overheatLimit: Double = 95
    static let lowDiskFraction: Double = 0.10
    /// Aynı türde iki bildirim arasındaki asgari süre.
    static func minInterval(_ kind: String) -> TimeInterval {
        switch kind {
        case "overheat": return 30 * 60
        case "lowDisk": return 12 * 3600
        case "memoryPressure": return 30 * 60
        case "memoryCritical": return 30 * 60
        default: return 0
        }
    }

    static func isOverheat(cpu: Double?, gpu: Double?) -> Double? {
        let hottest = [cpu, gpu].compactMap { $0 }.max()
        guard let h = hottest, h > overheatLimit else { return nil }
        return h
    }

    static func isLowDisk(free: Int64?, total: Int64?) -> Bool {
        guard let f = free, let t = total, t > 0 else { return false }
        return Double(f) / Double(t) < lowDiskFraction
    }

    static func shouldSend(kind: String, lastSent: Date?, now: Date) -> Bool {
        guard let l = lastSent else { return true }
        return now.timeIntervalSince(l) >= minInterval(kind)
    }
}

/// Temiz çıkış bayrağı: açılışta false yazılır, applicationWillTerminate'te true.
/// Açılışta false bulunursa önceki oturum beklenmedik bitmiştir (çökme, zorla kapatma, elektrik kesintisi).
enum CleanExit {
    static let key = "cleanExit"

    /// Açılışta bir kez çağrılır. true = önceki oturum beklenmedik bitti.
    static func checkAndArm(_ d: UserDefaults = .standard) -> Bool {
        let unexpected = d.object(forKey: key) != nil && !d.bool(forKey: key)
        d.set(false, forKey: key)
        return unexpected
    }

    static func markClean(_ d: UserDefaults = .standard) {
        d.set(true, forKey: key)
        d.synchronize()
    }
}

/// Yerel bildirimler (UNUserNotificationCenter). İzin ilk bildirimde bir kez istenir.
final class Notifier: NSObject {
    private let defaults = UserDefaults.standard
    private var authorized: Bool?
    /// Bildirime tıklanınca (tür ile). Ör. "update" → paneli aç.
    var onClick: ((String) -> Void)?

    /// Bildirim izni açıkça reddedilmiş mi (ana iş parçacığında döner).
    func checkDenied(_ done: @escaping (Bool) -> Void) {
        #if os(macOS)
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let denied = s.authorizationStatus == .denied
            DispatchQueue.main.async { done(denied) }
        }
        #else
        done(false)
        #endif
    }

    func notify(kind: String, title: String, body: String) {
        let now = Date()
        let lastKey = "lastNotification.\(kind)"
        let last = defaults.object(forKey: lastKey) as? Date
        guard NotificationPolicy.shouldSend(kind: kind, lastSent: last, now: now) else { return }
        defaults.set(now, forKey: lastKey)
        Log.info("Bildirim (\(kind)): \(title) — \(body)")
        #if os(macOS)
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let e = error { Log.warn("Bildirim izni hatası: \(e.localizedDescription)") }
            guard granted else {
                Log.warn("Bildirim izni yok (Sistem Ayarları › Bildirimler › Workstation)")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = ["kind": kind]
            let req = UNNotificationRequest(identifier: "\(kind)-\(Int(now.timeIntervalSince1970))", content: content, trigger: nil)
            center.add(req) { err in
                if let e = err { Log.warn("Bildirim gönderilemedi: \(e.localizedDescription)") }
            }
        }
        #endif
    }
}

#if os(macOS)
extension Notifier: UNUserNotificationCenterDelegate {
    /// Uygulama etkinken de afiş göster.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let kind = response.notification.request.content.userInfo["kind"] as? String
            ?? String(response.notification.request.identifier.split(separator: "-").first ?? "")
        DispatchQueue.main.async { [weak self] in self?.onClick?(kind) }
        completionHandler()
    }
}
#endif
