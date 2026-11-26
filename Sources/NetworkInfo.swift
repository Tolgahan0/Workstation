import Foundation

/// Mac mini'nin Wake-on-LAN bilgisi (Remote sekmesinde gösterilir; `workstation netinfo` ile aynı kaynak).
struct NetworkInfo: Equatable {
    var interface: String = ""
    /// Donanım portu adı ("Ethernet", "Wi-Fi" …).
    var port: String = ""
    var mac: String = ""
    var ip: String = ""
    var broadcast: String = "255.255.255.255"
    var hostname: String = ""
    /// Dışarıdan erişim (Tailscale). Boşsa yalnızca ev ağından bağlanılabilir.
    var tailscaleIP: String = ""
    var tailscaleName: String = ""

    /// `KEY=değer` satırlarını çözer (workstation netinfo çıktısı).
    static func parse(_ text: String) -> NetworkInfo {
        var n = NetworkInfo()
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let v = parts[1].trimmingCharacters(in: .whitespaces)
            switch parts[0] {
            case "INTERFACE": n.interface = v
            case "PORT": n.port = v
            case "MAC": n.mac = isUsableMAC(v) ? v.lowercased() : ""
            case "IP": n.ip = v
            case "BROADCAST": if !v.isEmpty { n.broadcast = v }
            case "HOSTNAME": n.hostname = v == ".local" ? "" : v
            case "TAILSCALE_IP": n.tailscaleIP = v
            case "TAILSCALE_NAME": n.tailscaleName = v
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

    /// Wake-on-LAN'da işe yarar gerçek donanım adresi mi? Sıfır, yayın ve yerel yönetimli
    /// (02:… gibi rastgele/sanal) adresler reddedilir.
    static func isUsableMAC(_ s: String) -> Bool {
        let m = s.lowercased()
        guard isValidMAC(m), m != "00:00:00:00:00:00", m != "ff:ff:ff:ff:ff:ff",
              let first = UInt8(m.prefix(2), radix: 16) else { return false }
        return first & 0x02 == 0
    }

    /// Kullanıcıya gösterilen bağlantı adı.
    var friendlyInterface: String {
        let p = port.lowercased()
        if p.contains("wi-fi") || p.contains("airport") { return "Wi-Fi" }
        if p.contains("ethernet") || p.contains("lan") { return L("Kablolu (Ethernet)") }
        return port.isEmpty ? interface : port
    }

    /// Ev dışından Ekran Paylaşımı adresi (Tailscale MagicDNS adı, yoksa 100.x IP'si).
    var remoteAddress: String { tailscaleName.isEmpty ? tailscaleIP : tailscaleName }

    /// İstemci Mac'e kopyalanacak komut: önce yapılandırma, sonra bağlan.
    var sshHost: String { hostname.isEmpty ? (ip.isEmpty ? "studio" : ip) : hostname }

    var connectCommand: String {
        "workstation-connect --setup \(sshHost) && workstation-connect \(sshHost)"
    }

    /// ~/.config/workstation/config içeriği (elle kurulum için).
    var configText: String {
        var lines = ["HOST=\(sshHost)"]
        if Self.isUsableMAC(mac) { lines.append("MAC=\(mac)") }
        lines.append("BROADCAST=\(broadcast)")
        return lines.joined(separator: "\n")
    }

    /// Tailscale (CGNAT 100.64.0.0/10) adresi; komut çalıştırmaz (getifaddrs).
    static func tailscaleIPv4() -> String? {
        ipv4s().first { isTailscale($0.1) }?.1
    }

    /// Ev ağı adresleri (en*, Tailscale ve loopback hariç).
    static func localIPv4s() -> [String] {
        ipv4s().filter { $0.0.hasPrefix("en") && !isTailscale($0.1) }.map { $0.1 }
    }

    static func isTailscale(_ ip: String) -> Bool {
        let p = ip.split(separator: ".").compactMap { Int($0) }
        return p.count == 4 && p[0] == 100 && (64...127).contains(p[1])
    }

    private static func ipv4s() -> [(String, String)] {
        #if !os(macOS)
        return []
        #else
        var out: [(String, String)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var p = head
        while let cur = p {
            if let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    out.append((String(cString: cur.pointee.ifa_name), String(cString: host)))
                }
            }
            p = cur.pointee.ifa_next
        }
        return out
        #endif
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
