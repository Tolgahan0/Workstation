import Foundation
#if os(macOS)
import AppKit
import CoreGraphics
import IOKit
#endif

// İstemci rolü (MacBook): Mac mini'yi ev ağında Bonjour ile bulur, adreslerini (ev + Tailscale) kendiliğinden
// kaydeder, tek tıkla bağlanır (dışarıdaysa Tailscale'i açar), sanal ekranı bu Mac'in Ekran Paylaşımı alanına
// birebir uydurur ve pencere/tam ekran değişince yeniden uydurur. Mac mini (studio) rolü: kendini Bonjour'da duyurur.
// Saf kurallar Linux'ta da derlenir ve test edilir.

// MARK: - Geometri (saf)

enum ClientGeometry {
    /// Ekran Paylaşımı penceresinin araç çubuğu + başlık yüksekliği (pt, pencere kipinde; tam ekranda gizlenir).
    static var toolbarHeight: Double {
        let v = UserDefaults.standard.double(forKey: "screenSharingToolbarHeight")
        return v > 0 ? v : 52
    }

    /// Tam ekran Ekran Paylaşımı'nın kullandığı alan: çentikli ekranlarda çentiğin altı (ör. 14": 1512x945).
    static func fullscreenTarget(screenWidth: Double, screenHeight: Double, safeTop: Double) -> String {
        resolution(screenWidth, screenHeight - max(0, safeTop))
    }

    /// Ekran Paylaşımı penceresinin görüntü alanı → sanal ekran çözünürlüğü.
    /// - fullscreen: pencere ekranı kaplıyorsa (çentik altı ya da tüm ekran) araç çubuğu yoktur.
    /// - Aksi hâlde pencere yüksekliğinden araç çubuğu düşülür.
    static func target(window: (x: Double, y: Double, w: Double, h: Double),
                       screen: (w: Double, h: Double), safeTop: Double, toolbar: Double = toolbarHeight) -> String? {
        guard window.w >= 400, window.h >= 300 else { return nil }
        let full = abs(window.w - screen.w) <= 2 && window.h >= screen.h - max(0, safeTop) - 2
        if full {
            // Tüm ekranı (çentik bölgesi dahil) kaplıyorsa görüntü çentiğin altına çizilir.
            let h = window.h > screen.h - 1 ? screen.h - max(0, safeTop) : window.h
            return resolution(window.w, h)
        }
        return resolution(window.w, window.h - toolbar)
    }

    /// Tam sayıya yuvarlanmış, makul sınırlar içinde "WxH". (Tek sayılar da olur: 14" çentik altı 1512x945,
    /// BetterDisplay'in çözünürlük listesinde HiDPI olarak çalışıyor; çifte yuvarlamak 1 pt bant bırakır.)
    static func resolution(_ w: Double, _ h: Double) -> String {
        let ww = min(max(Int(w.rounded()), 800), 6016), hh = min(max(Int(h.rounded()), 500), 3384)
        return "\(ww)x\(hh)"
    }

    /// Küçük oynamalarda (birkaç pt) yeniden uydurma yapılmaz (her uydurma bir anlık yeniden çizim demek).
    static func differsEnough(_ a: String?, _ b: String, tolerance: Int = 6) -> Bool {
        guard let a = a else { return true }
        let p = a.split(separator: "x").compactMap { Int($0) }, q = b.split(separator: "x").compactMap { Int($0) }
        guard p.count == 2, q.count == 2 else { return true }
        return abs(p[0] - q[0]) > tolerance || abs(p[1] - q[1]) > tolerance
    }
}

// MARK: - workstation-connect yapılandırması (saf)

/// ~/.config/workstation/config: KEY=değer satırları. Birleştirirken kullanıcının yazdıkları korunur.
struct ClientConfig: Equatable {
    var values: [String: String] = [:]
    var order: [String] = []

    static var path: String { NSHomeDirectory() + "/.config/workstation/config" }

    static func parse(_ text: String) -> ClientConfig {
        var c = ClientConfig()
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
                v = String(v.dropFirst().dropLast())
            }
            guard k.range(of: "^[A-Z_]+$", options: .regularExpression) != nil else { continue }
            if c.values[k] == nil { c.order.append(k) }
            c.values[k] = v
        }
        return c
    }

    /// Bulunan değerleri yazar. `keepUser`: HOST / VNC_HOST kullanıcı tarafından yazılmışsa ezilmez.
    mutating func merge(_ found: [String: String], overwrite: Set<String>) -> Bool {
        var changed = false
        for (k, v) in found.sorted(by: { $0.key < $1.key }) where !v.isEmpty {
            if values[k] == nil {
                order.append(k); values[k] = v; changed = true
            } else if overwrite.contains(k), values[k] != v {
                values[k] = v; changed = true
            }
        }
        return changed
    }

    func serialized(header: String) -> String {
        (["# \(header)"] + order.compactMap { k in values[k].map { "\(k)=\($0)" } }).joined(separator: "\n") + "\n"
    }
}

// MARK: - Bonjour duyurusu (saf kısım)

enum StudioBeacon {
    static let type = "_workstation._tcp."

    /// Duyurulan alanlar: host (ev adı), ts (Tailscale adı), tsip, user (SSH kullanıcısı), mac, bc, v (sürüm).
    static func txt(info: NetworkInfo, user: String, version: String) -> [String: String] {
        var d: [String: String] = ["role": "studio", "user": user, "v": version]
        if !info.hostname.isEmpty { d["host"] = info.hostname }
        if !info.tailscaleName.isEmpty { d["ts"] = info.tailscaleName }
        if !info.tailscaleIP.isEmpty { d["tsip"] = info.tailscaleIP }
        if !info.mac.isEmpty { d["mac"] = info.mac }
        if !info.broadcast.isEmpty { d["bc"] = info.broadcast }
        return d
    }

    /// Duyurudan istemci yapılandırması (workstation-connect anahtarları).
    static func config(fromTXT t: [String: String]) -> [String: String]? {
        guard t["role"] == "studio", let host = t["host"], !host.isEmpty else { return nil }
        var c: [String: String] = ["HOST": host, "VNC_HOST": host]
        if let u = t["user"], !u.isEmpty { c["SSH_USER"] = u }
        if let ts = t["ts"] ?? t["tsip"], !ts.isEmpty { c["ALT_HOST"] = ts }
        if let m = t["mac"], NetworkInfo.isUsableMAC(m) { c["MAC"] = m }
        if let b = t["bc"], !b.isEmpty { c["BROADCAST"] = b }
        return c
    }
}

#if os(macOS)
// MARK: - Bu Mac (macOS)

enum ClientEnvironment {
    /// Dizüstü mü (yerleşik ekranı var mı)? Mac mini/Studio: hayır → studio rolü.
    static var hasBuiltInDisplay: Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).contains { CGDisplayIsBuiltin($0) != 0 }
    }

    /// Son kullanıcı girdisinden bu yana geçen süre (sn).
    static var idleSeconds: Double {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard entry != 0 else { return 0 }
        defer { IOObjectRelease(entry) }
        guard let v = IORegistryEntryCreateCFProperty(entry, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return 0 }
        return v.doubleValue / 1e9
    }

    static let tailscaleBundleIDs = ["io.tailscale.ipn.macsys", "io.tailscale.ipn.macos"]

    static var tailscaleAppURL: URL? {
        for id in tailscaleBundleIDs {
            if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return u }
        }
        return nil
    }

    static var tailscaleRunning: Bool {
        tailscaleBundleIDs.contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    }

    static var tailscaleConnected: Bool { NetworkInfo.tailscaleIPv4() != nil }

    /// Tailscale'i arka planda açar (pencere öne gelmez). Yönetici izni gerekmez.
    static func launchTailscale() {
        guard let url = tailscaleAppURL, !tailscaleRunning else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.hides = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, err in
            if let e = err { Log.warn("Tailscale açılamadı: \(e.localizedDescription)") } else { Log.info("Tailscale açıldı (Workstation)") }
        }
    }

    static let screenSharingBundleID = "com.apple.ScreenSharing"

    /// Ekran Paylaşımı'nın en büyük ekrandaki penceresi (izin gerekmez: yalnızca konum/boyut okunur).
    static func screenSharingWindow() -> (x: Double, y: Double, w: Double, h: Double)? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: screenSharingBundleID).first else { return nil }
        let pid = app.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        var best: (x: Double, y: Double, w: Double, h: Double)?
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? Int32) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: Double],
                  let ww = b["Width"], let hh = b["Height"] else { continue }
            if best == nil || ww * hh > best!.w * best!.h { best = (b["X"] ?? 0, b["Y"] ?? 0, ww, hh) }
        }
        return best
    }

    /// Ekran Paylaşımı penceresinin bulunduğu ekran (yoksa ana ekran): boyut ve çentik payı.
    static func screenGeometry(containing window: (x: Double, y: Double, w: Double, h: Double)? = nil) -> (w: Double, h: Double, safeTop: Double) {
        let screens = NSScreen.screens
        var s = NSScreen.main ?? screens.first
        if let win = window, let primary = screens.first {
            // CGWindow koordinatları sol üstten; NSScreen sol alttan.
            let cx = win.x + win.w / 2, cy = primary.frame.height - (win.y + win.h / 2)
            s = screens.first { $0.frame.contains(CGPoint(x: cx, y: cy)) } ?? s
        }
        guard let scr = s else { return (1512, 982, 0) }
        var top: Double = 0
        if #available(macOS 12.0, *) { top = Double(scr.safeAreaInsets.top) }
        return (Double(scr.frame.width), Double(scr.frame.height), top)
    }

    static func tcpReachable(_ host: String, port: Int, timeout: Double = 2) -> Bool {
        let h = host.split(separator: "@").last.map(String.init) ?? host
        return Shell.run("/usr/bin/nc", ["-z", "-G", String(Int(max(1, timeout))), h, String(port)], timeout: timeout + 2).succeeded
    }
}

/// Mac mini: kendini ev ağında duyurur (istemci MacBook'lar adresleri buradan öğrenir).
final class StudioAdvertiser: NSObject, NetServiceDelegate {
    private var service: NetService?

    func publish(txt: [String: String]) {
        let data = NetService.data(fromTXTRecord: txt.mapValues { Data($0.utf8) })
        if let s = service {
            s.setTXTRecord(data)
            return
        }
        let s = NetService(domain: "local.", type: StudioBeacon.type, name: Host.current().localizedName ?? "Workstation", port: 22)
        s.delegate = self
        s.setTXTRecord(data)
        s.publish()
        service = s
        Log.info("Bonjour: Workstation duyuruluyor (\(txt["host"] ?? "?"), Tailscale \(txt["ts"] ?? "yok"))")
    }

    func stop() { service?.stop(); service = nil }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        Log.warn("Bonjour duyurusu başarısız: \(errorDict)")
    }
}

/// MacBook: ev ağında Mac mini'yi arar; bulunca TXT kaydını bildirir.
final class StudioBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var pending: [NetService] = []
    var onFound: (([String: String]) -> Void)?

    func start() {
        browser.delegate = self
        browser.searchForServices(ofType: StudioBeacon.type, inDomain: "local.")
    }

    func stop() { browser.stop(); pending.removeAll() }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard service.name != (Host.current().localizedName ?? "") else { return }
        service.delegate = self
        pending.append(service)
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        defer { pending.removeAll { $0 === sender } }
        guard let data = sender.txtRecordData() else { return }
        let txt = NetService.dictionary(fromTXTRecord: data).compactMapValues { String(data: $0, encoding: .utf8) }
        onFound?(txt)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        pending.removeAll { $0 === sender }
    }
}
#endif
