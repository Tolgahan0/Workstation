import Foundation

/// `pmset` ile güç profillerini uygular. Parolasız çalışması için install.sh,
/// /etc/sudoers.d/workstation_toggle dosyasına `NOPASSWD: /usr/bin/pmset` kuralını ekler.
final class PowerManager {
    private static let sudo = "/usr/bin/sudo"
    private static let pmset = "/usr/bin/pmset"

    /// Remote modunda uygulama süreci boyunca boşta uyku/ekran uykusunu engelleyen etkinlik
    /// (pmset ayarlarına ek bir emniyet; yalnızca Foundation API'si).
    private var remoteActivity: NSObjectProtocol?

    /// Masaüstü: `sudo pmset -a sleep 0 displaysleep 15 lowpowermode 0`
    func applyDesktopProfile() {
        endRemoteActivity()
        pmsetSudo(["-a", "sleep", "0", "displaysleep", "15", "lowpowermode", "0"])
    }

    /// Uyku/Gece: `sudo pmset -a lowpowermode 1 sleep 1 displaysleep 1 womp 1`
    func applySleepProfile() {
        endRemoteActivity()
        pmsetSudo(["-a", "lowpowermode", "1", "sleep", "1", "displaysleep", "1", "womp", "1"])
    }

    /// Remote: `sudo pmset -a sleep 0 disksleep 0 displaysleep 0 lowpowermode 0 tcpkeepalive 1 autorestart 1 womp 1`
    /// (womp 1: Mac yine de uyursa workstation-connect Wake-on-LAN ile uyandırabilsin.)
    func applyRemoteProfile() {
        pmsetSudo(["-a", "sleep", "0", "disksleep", "0", "displaysleep", "0", "lowpowermode", "0", "tcpkeepalive", "1", "autorestart", "1", "womp", "1"])
        beginRemoteActivity()
    }

    /// `pmset displaysleepnow` — ekranları hemen uyutur (root gerekmez).
    func displaySleepNow() {
        let r = Shell.run(Self.pmset, ["displaysleepnow"], timeout: 10)
        if r.succeeded {
            Log.info("pmset displaysleepnow çalıştırıldı.")
        } else {
            Log.error("pmset displaysleepnow başarısız (\(r.status)): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// `sudo -n` parolasız çalışır; sudoers kuralı yoksa parola sormak yerine hata verir ve günlüğe yazılır.
    @discardableResult
    private func pmsetSudo(_ args: [String]) -> Bool {
        let r = Shell.run(Self.sudo, ["-n", Self.pmset] + args, timeout: 15)
        let cmd = "sudo pmset \(args.joined(separator: " "))"
        if r.succeeded {
            Log.info("\(cmd) uygulandı.")
            return true
        }
        let err = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if err.lowercased().contains("password") {
            Log.error("\(cmd) başarısız: sudo parola istiyor. /etc/sudoers.d/workstation_toggle kuralını kontrol edin (install.sh'yi tekrar çalıştırın).")
        } else {
            Log.error("\(cmd) başarısız (\(r.status)): \(err)")
        }
        return false
    }

    private func beginRemoteActivity() {
        #if os(macOS)
        guard remoteActivity == nil else { return }
        remoteActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "WorkstationMode Remote modu: Mac mini uykuya geçmemeli")
        Log.info("Remote uyku engelleme etkinliği başlatıldı.")
        #endif
    }

    private func endRemoteActivity() {
        #if os(macOS)
        if let a = remoteActivity {
            ProcessInfo.processInfo.endActivity(a)
            remoteActivity = nil
            Log.info("Remote uyku engelleme etkinliği sonlandırıldı.")
        }
        #endif
    }
}
