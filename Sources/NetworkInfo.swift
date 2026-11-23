import Foundation

/// Mac mini'nin Wake-on-LAN bilgisi (Remote sekmesinde gösterilir; `workstation netinfo` ile aynı kaynak).
struct NetworkInfo: Equatable {
    var interface: String = ""
    var mac: String = ""
    var ip: String = ""
    var broadcast: String = "255.255.255.255"
    var hostname: String = ""

    /// `KEY=değer` satırlarını çözer (workstation netinfo çıktısı).
    static func parse(_ text: String) -> NetworkInfo {
        var n = NetworkInfo()
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let v = parts[1].trimmingCharacters(in: .whitespaces)
            switch parts[0] {
            case "INTERFACE": n.interface = v
            case "MAC": n.mac = v.lowercased()
            case "IP": n.ip = v
            case "BROADCAST": if !v.isEmpty { n.broadcast = v }
            case "HOSTNAME": n.hostname = v == ".local" ? "" : v
            default: break
            }
        }
        return n
    }

    static func isValidMAC(_ s: String) -> Bool {
        let parts = s.split(separator: ":")
        guard parts.count == 6 else { return false }
        return parts.allSatisfy { $0.count == 2 && $0.allSatisfy { $0.isHexDigit } }
    }

    /// İstemci Mac'e kopyalanacak komut: önce yapılandırma, sonra bağlan.
    var sshHost: String { hostname.isEmpty ? (ip.isEmpty ? "studio" : ip) : hostname }

    var connectCommand: String {
        "workstation-connect --setup \(sshHost) && workstation-connect \(sshHost)"
    }

    /// ~/.config/workstation/config içeriği (elle kurulum için).
    var configText: String {
        var lines = ["HOST=\(sshHost)"]
        if Self.isValidMAC(mac) { lines.append("MAC=\(mac)") }
        lines.append("BROADCAST=\(broadcast)")
        return lines.joined(separator: "\n")
    }

    /// Arka planda çağrılmalı (kabuk komutu çalıştırır).
    static func fetch() -> NetworkInfo? {
        let script = "/usr/local/bin/workstation"
        guard FileManager.default.isExecutableFile(atPath: script) else { return nil }
        let r = Shell.run("/bin/zsh", [script, "netinfo"], timeout: 8)
        guard r.succeeded else { return nil }
        let n = parse(r.stdout)
        return (n.mac.isEmpty && n.ip.isEmpty) ? nil : n
    }
}
