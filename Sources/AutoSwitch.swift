import Foundation
#if os(macOS)
import Darwin
#endif

/// Uzak oturum bitince ne yapılsın.
enum AfterRemoteAction: String, CaseIterable, Identifiable, Codable {
    case sleep, desktop, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sleep: return L("Uyku")
        case .desktop: return L("Masaüstü")
        case .none: return L("Hiçbir şey")
        }
    }
    var mode: WorkMode? {
        switch self {
        case .sleep: return .sleep
        case .desktop: return .desktop
        case .none: return nil
        }
    }
}

/// Ayarlar > Otomatik mod geçişi (varsayılan kapalı).
struct AutoSwitchSettings: Codable, Equatable {
    var enabled = false
    var includeSSH = false
    var idleMinutes = 15
    var after: AfterRemoteAction = .sleep

    static let key = "autoSwitchSettings"
    static let checkInterval: TimeInterval = 10

    static func load(_ d: UserDefaults = .standard) -> AutoSwitchSettings {
        guard let data = d.data(forKey: key), var s = try? JSONDecoder().decode(AutoSwitchSettings.self, from: data) else {
            return AutoSwitchSettings()
        }
        s.idleMinutes = Swift.max(1, Swift.min(240, s.idleMinutes))
        return s
    }

    func save(_ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key) }
    }
}

/// Uzak oturum durum makinesi (saf; Linux'ta test edilir).
/// - Oturum BAŞLADIĞINDA (geçiş anında) mod Remote değilse → Remote'a geç. Oturum sürerken kullanıcı elle
///   başka moda geçerse tekrar zorlanmaz.
/// - Oturum BİTTİKTEN sonra `idleMinutes` boyunca yeni oturum olmazsa ve mod hâlâ Remote ise → `after`.
struct AutoSwitchEngine {
    enum Action: Equatable {
        case none
        case enterRemote(reason: String)
        case leaveRemote(WorkMode)
    }

    private(set) var sessionActive = false
    private(set) var endedAt: Date?

    mutating func update(screenSharing: Bool, ssh: Bool, now: Date, currentMode: WorkMode,
                         settings: AutoSwitchSettings) -> Action {
        let sshCounts = settings.includeSSH && ssh
        let active = screenSharing || sshCounts
        if active {
            endedAt = nil
            if !sessionActive {
                sessionActive = true
                if currentMode != .remote {
                    return .enterRemote(reason: screenSharing ? L("Ekran Paylaşımı oturumu") : L("SSH oturumu"))
                }
            }
            return .none
        }
        if sessionActive {
            sessionActive = false
            endedAt = now
        }
        guard currentMode == .remote else { endedAt = nil; return .none }
        guard let e = endedAt, let target = settings.after.mode else { return .none }
        if now.timeIntervalSince(e) >= Double(settings.idleMinutes) * 60 {
            endedAt = nil
            return .leaveRemote(target)
        }
        return .none
    }

    /// Ayarlar kapatıldığında / mod elle değiştiğinde sıfırla.
    mutating func reset() {
        sessionActive = false
        endedAt = nil
    }
}

/// Uzak oturum algılama: süreç listesi süreç içinde taranır (komut çalıştırılmaz).
///  - Ekran Paylaşımı: `screensharingd` yalnızca bağlantı varken çalışır (launchd talep üzerine başlatır).
///  - SSH: `sshd-session` (macOS 15+) veya bağlantı başına başlatılan `sshd` süreçleri.
enum RemoteSessionProbe {
    static func classify(processNames: [String]) -> (screenSharing: Bool, ssh: Bool) {
        var vnc = false, ssh = false
        for n in processNames {
            if n == "screensharingd" { vnc = true }
            if n == "sshd-session" || n == "sshd" { ssh = true }
        }
        return (vnc, ssh)
    }

    static func current() -> (screenSharing: Bool, ssh: Bool) {
        classify(processNames: processNames())
    }

    static func processNames() -> [String] {
        #if os(macOS)
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let n = pids.withUnsafeMutableBufferPointer { buf -> Int32 in
            proc_listallpids(buf.baseAddress, Int32(buf.count * MemoryLayout<pid_t>.size))
        }
        guard n > 0 else { return [] }
        var names: [String] = []
        var buf = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(Int(n)) where pid > 0 {
            let len = proc_name(pid, &buf, UInt32(buf.count))
            if len > 0 { names.append(String(cString: buf)) }
        }
        return names
        #else
        return []
        #endif
    }
}
