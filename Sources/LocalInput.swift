import Foundation
#if os(macOS)
import AppKit
import IOKit
import IOKit.hid
#endif

// Remote'tan yerel çıkış: Mac mini'ye USB/Bluetooth ile TAKILI klavye/fareden gelen girdi fiziksel monitörleri
// geri açar (Masaüstü). Ekran Paylaşımı'nın enjekte ettiği olaylar bir HID aygıtından gelmez (CGEvent olarak
// pencere sunucusuna verilir), bu yüzden IOHIDManager'da hiç görünmez: uzak oturum monitörleri asla uyandırmaz.
// Saf kurallar Linux'ta da derlenir ve test edilir.

enum LocalInputPolicy {
    static let enabledKey = "localInputExitsRemote"
    /// Varsayılan açık.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Remote uygulandıktan sonra bu süre girdi yok sayılır (Remote'u başlatan tıklama, masadan kalkarken fareye çarpma).
    static let graceSeconds: TimeInterval = 20

    /// Fiziksel olarak takılı aygıt mı? Sanal aygıtlar (Ekran Paylaşımı, Universal Control, Karabiner, sanal HID
    /// sürücüleri) reddedilir; yalnızca bilinen donanım taşıyıcıları kabul edilir.
    static func isPhysical(transport: String?, product: String?, isVirtual: Bool) -> Bool {
        guard !isVirtual else { return false }
        let p = (product ?? "").lowercased()
        if p.contains("virtual") || p.contains("karabiner") || p.contains("universal control") { return false }
        let t = (transport ?? "").lowercased()
        return ["usb", "bluetooth", "bluetooth low energy", "spi", "i2c", "fifo", "aid"].contains(t)
    }
}

/// Girdi olaylarından "kullanıcı gerçekten başında" kararını verir.
/// - Uzak izleyici yokken: tek tuş / tık ya da 1 sn içinde belirgin fare hareketi yeter.
/// - Ekran Paylaşımı bağlıyken (biri uzaktan çalışıyor): fare hareketi yok sayılır, 3 sn içinde 2 tuş/tık gerekir.
struct LocalInputDetector {
    enum Event: Equatable {
        case press          // fare tuşu ya da klavye tuşu (basma)
        case move(Double)   // göreli hareket (|dx|+|dy|, ham sayım)
        case scroll(Double)
    }

    var armedAt: Date
    var moveThreshold: Double = 300
    var moveWindow: TimeInterval = 1
    var pressWindow: TimeInterval = 3
    private var moveStart: Date?
    private var moveSum: Double = 0
    private var lastPress: Date?

    init(armedAt: Date) { self.armedAt = armedAt }

    mutating func feed(_ e: Event, at now: Date, remoteViewerActive: Bool) -> Bool {
        guard now >= armedAt else { return false }
        switch e {
        case .press:
            if !remoteViewerActive { return true }
            if let l = lastPress, now.timeIntervalSince(l) <= pressWindow { return true }
            lastPress = now
            return false
        case .move(let d), .scroll(let d):
            guard !remoteViewerActive else { return false }
            let amount: Double
            if case .scroll = e { amount = abs(d) * 60 } else { amount = abs(d) }
            if let s = moveStart, now.timeIntervalSince(s) <= moveWindow {
                moveSum += amount
            } else {
                moveStart = now
                moveSum = amount
            }
            return moveSum >= moveThreshold
        }
    }
}

/// İzin gerektirmeyen yedek: sistemin "son girdi" sayacı (HIDIdleTime) sıfırlandı mı?
/// Ekran Paylaşımı da bu sayacı sıfırlar; bu yüzden yalnızca bağlı izleyici YOKKEN (ve son 20 sn'de olmamışken) sayılır.
/// Fare kaynaklı sıfırlamalar fare katmanına bırakılır (titreşim eşiği orada); fare olayı olmayan sıfırlama = klavye.
struct IdleResetRule {
    var armedAt: Date
    var viewerQuiet: TimeInterval = 20
    var mouseWindow: TimeInterval = 0.6
    private var lastIdle: Double?
    private var viewerSeenAt = Date.distantPast
    private var mouseSeenAt = Date.distantPast

    init(armedAt: Date) { self.armedAt = armedAt }

    mutating func viewer(at now: Date) { viewerSeenAt = now }
    mutating func mouse(at now: Date) { mouseSeenAt = now }

    /// `idle`: saniye. Sayaç geriye gittiyse (yeni girdi) ve koşullar uygunsa true.
    mutating func sample(idle: Double, at now: Date, viewerActive: Bool) -> Bool {
        defer { lastIdle = idle }
        if viewerActive { viewerSeenAt = now; return false }
        guard let prev = lastIdle, idle + 0.05 < prev, idle < 1.0 else { return false }
        guard now >= armedAt, now.timeIntervalSince(viewerSeenAt) > viewerQuiet else { return false }
        guard abs(now.timeIntervalSince(mouseSeenAt)) > mouseWindow else { return false }
        return true
    }
}

/// Uzaktan erişimin önkoşulları (yalnızca okunur; arka planda çağrılmalı).
struct RemoteAccessDiagnostics {
    var screenSharingEnabled: Bool
    var tailscaleIP: String?

    var summary: String {
        "Ekran Paylaşımı \(screenSharingEnabled ? "açık" : "KAPALI") · Tailscale \(tailscaleIP ?? "yok/kapalı")"
            + " · ev ağı \(NetworkInfo.localIPv4s().joined(separator: ", "))"
    }

    static func current() -> RemoteAccessDiagnostics {
        let r = Shell.run("/bin/launchctl", ["print-disabled", "system"], timeout: 5)
        return RemoteAccessDiagnostics(screenSharingEnabled: screenSharingEnabled(launchctlOutput: r.stdout),
                                       tailscaleIP: NetworkInfo.tailscaleIPv4())
    }

    /// `launchctl print-disabled system`: `"com.apple.screensharing" => enabled` (eski sürümler: `=> false`).
    static func screenSharingEnabled(launchctlOutput: String) -> Bool {
        for line in launchctlOutput.split(separator: "\n") where line.contains("\"com.apple.screensharing\"") {
            return line.contains("enabled") || line.contains("=> false")
        }
        return false
    }
}

#if os(macOS)
/// Yalnızca Remote modunda çalışır (aksi hâlde kapalı; maliyet sıfır).
final class LocalInputWatcher {
    private var manager: IOHIDManager?
    private var allowed = Set<UnsafeMutableRawPointer>()   // kabul edilen aygıtlar (IOHIDDevice işaretçisi)
    private var names: [UnsafeMutableRawPointer: String] = [:]
    private var detector = LocalInputDetector(armedAt: .distantFuture)
    private var viewerCheckedAt = Date.distantPast
    private var viewerActive = false
    private var fired = false
    private var fallbackMonitor: Any?
    private var idleTimer: Timer?
    private var idleRule = IdleResetRule(armedAt: .distantFuture)
    /// Son başlatmanın açılış sonucu (teşhis).
    private(set) var openResult: String = "?"
    /// Tetiklenince bir kez çağrılır (aygıt adıyla).
    var onLocalInput: ((String) -> Void)?
    var isRunning: Bool { manager != nil || fallbackMonitor != nil }
    var deviceNames: [String] { Array(Set(names.values)).sorted() }

    /// Klavyeler için Giriş İzleme izni gerekir; izin yokken yalnızca fareler izlenir (izin penceresi açılmaz).
    static var keyboardAccessGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Kullanıcı ayarlardan isteyince: sistem izin penceresini açar.
    static func requestKeyboardAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// İzin hiç sorulmadıysa sistem penceresini açar (Workstation Giriş İzleme listesine eklenir);
    /// reddedildiyse Sistem Ayarları › Gizlilik › Giriş İzleme'yi açar.
    static func ensureAccessRequested(openSettingsIfDenied: Bool) {
        let s = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if s == kIOHIDAccessTypeGranted { return }
        if s == kIOHIDAccessTypeUnknown {
            let ok = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            Log.info("Giriş İzleme izni istendi (sistem penceresi): \(ok ? "verildi" : "bekleniyor")")
            if ok || !openSettingsIfDenied { return }
        }
        if openSettingsIfDenied, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    static var accessStateText: String {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return "verildi"
        case kIOHIDAccessTypeDenied: return "reddedildi"
        default: return "sorulmadı"
        }
    }

    func start(grace: TimeInterval = LocalInputPolicy.graceSeconds) {
        stop()
        fired = false
        detector = LocalInputDetector(armedAt: Date().addingTimeInterval(grace))
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        var matches: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Pointer],
        ]
        let keyboards = Self.keyboardAccessGranted
        if keyboards {
            matches.append([kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard])
        }
        IOHIDManagerSetDeviceMatchingMultiple(m, matches as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, device in
            guard let ctx = ctx else { return }
            Unmanaged<LocalInputWatcher>.fromOpaque(ctx).takeUnretainedValue().deviceAdded(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, device in
            guard let ctx = ctx else { return }
            Unmanaged<LocalInputWatcher>.fromOpaque(ctx).takeUnretainedValue().deviceRemoved(device)
        }, ctx)
        IOHIDManagerRegisterInputValueCallback(m, { ctx, _, _, value in
            guard let ctx = ctx else { return }
            Unmanaged<LocalInputWatcher>.fromOpaque(ctx).takeUnretainedValue().input(value)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
        let openText = r == kIOReturnSuccess ? "tamam" : (r == kIOReturnNotPermitted ? "izin yok (0x\(String(r, radix: 16)))" : String(format: "0x%x", r))
        openResult = openText
        // Yedekler HER ZAMAN açık: HID açılışı izin yüzünden başarısız olsa da (0xe00002e2, aygıtlar listelenir ama
        // olay gelmez) fare olayları ve sistem boşta sayacı monitörleri geri getirir.
        installFallback()
        startIdleWatch()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self, self.manager != nil else { return }
            Log.info("Yerel giriş izleniyor (Remote'tan çıkış için): HID \(openText)\(keyboards ? " (fare + klavye)" : " (yalnız fare; Giriş İzleme: \(Self.accessStateText))") · yedek: fare olayları + boşta sayacı · aygıtlar: \(self.deviceNames.joined(separator: ", "))")
        }
    }

    /// Sistem boşta sayacı (izin gerekmez): klavye dahil her yerel girdi sayacı sıfırlar.
    private func startIdleWatch() {
        idleTimer?.invalidate()
        idleRule = IdleResetRule(armedAt: detector.armedAt)
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self, !self.fired else { return }
            let now = Date()
            let idle = ClientEnvironment.idleSeconds
            // İzleyici durumunu sayaç sıfırlandığında taze oku (Ekran Paylaşımı bağlanınca sayacı o da sıfırlar).
            var viewer = self.viewerActive
            if now.timeIntervalSince(self.viewerCheckedAt) > (idle < 1.0 ? 0.5 : 2) {
                viewer = RemoteSessionProbe.current().screenSharing
                self.viewerActive = viewer
                self.viewerCheckedAt = now
            }
            if self.idleRule.sample(idle: idle, at: now, viewerActive: viewer) {
                self.fired = true
                self.onLocalInput?(L("klavye (sistem girdisi)"))
            }
        }
        RunLoop.main.add(t, forMode: .common)
        idleTimer = t
    }

    /// Yedek (HID aygıtları açılamazsa): pencere sunucusunun fare olayları; yalnızca donanımdan gelenler
    /// (kaynak süreç 0 + HID sistem durumu) ve Ekran Paylaşımı bağlı DEĞİLKEN sayılır.
    private func installFallback() {
        guard fallbackMonitor == nil else { return }
        fallbackMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .mouseMoved, .scrollWheel]) { [weak self] e in
            guard let self = self, !self.fired, let c = e.cgEvent else { return }
            guard c.getIntegerValueField(.eventSourceUnixProcessID) == 0,
                  c.getIntegerValueField(.eventSourceStateID) == Int64(CGEventSourceStateID.hidSystemState.rawValue) else { return }
            let now = Date()
            self.idleRule.mouse(at: now)
            if now.timeIntervalSince(self.viewerCheckedAt) > 2 {
                self.viewerActive = RemoteSessionProbe.current().screenSharing
                self.viewerCheckedAt = now
            }
            // Ekran Paylaşımı bağlıyken enjekte edilen olaylar buradan ayırt edilemeyebilir: yalnız HID katmanı sayar.
            guard !self.viewerActive else { return }
            let ev: LocalInputDetector.Event
            switch e.type {
            case .mouseMoved: ev = .move(Double(abs(e.deltaX) + abs(e.deltaY)) * 3)
            case .scrollWheel: ev = .scroll(Double(abs(e.scrollingDeltaY)) / 4)
            default: ev = .press
            }
            if self.detector.feed(ev, at: now, remoteViewerActive: false) {
                self.fired = true
                self.onLocalInput?(L("fare"))
            }
        }
    }

    func stop() {
        if let f = fallbackMonitor { NSEvent.removeMonitor(f); fallbackMonitor = nil }
        idleTimer?.invalidate(); idleTimer = nil
        guard let m = manager else { return }
        IOHIDManagerRegisterInputValueCallback(m, nil, nil)
        IOHIDManagerRegisterDeviceMatchingCallback(m, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(m, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
        allowed.removeAll()
        names.removeAll()
    }

    private static func prop(_ d: IOHIDDevice, _ key: String) -> Any? { IOHIDDeviceGetProperty(d, key as CFString) }

    private func deviceAdded(_ d: IOHIDDevice) {
        let transport = Self.prop(d, kIOHIDTransportKey) as? String
        let product = Self.prop(d, kIOHIDProductKey) as? String
        let virt = (Self.prop(d, "VirtualDevice") as? Bool) == true || (Self.prop(d, "HIDVirtualDevice") as? Bool) == true
        let key = Unmanaged.passUnretained(d).toOpaque()
        let label = "\(product ?? "?") (\(transport ?? "?"))"
        if LocalInputPolicy.isPhysical(transport: transport, product: product, isVirtual: virt) {
            allowed.insert(key)
            names[key] = label
        } else if manager != nil {
            Log.info("Yerel giriş: sanal/bilinmeyen aygıt yok sayıldı: \(label)")
        }
    }

    private func deviceRemoved(_ d: IOHIDDevice) {
        let key = Unmanaged.passUnretained(d).toOpaque()
        allowed.remove(key)
        names[key] = nil
    }

    private func input(_ value: IOHIDValue) {
        guard !fired else { return }
        let el = IOHIDValueGetElement(value)
        let dev = IOHIDElementGetDevice(el)
        let key = Unmanaged.passUnretained(dev).toOpaque()
        guard allowed.contains(key) else { return }
        let page = IOHIDElementGetUsagePage(el)
        let usage = IOHIDElementGetUsage(el)
        let v = IOHIDValueGetIntegerValue(value)
        let event: LocalInputDetector.Event
        switch (Int(page), Int(usage)) {
        case (kHIDPage_Button, _) where v != 0:
            event = .press
        case (kHIDPage_KeyboardOrKeypad, 0x04...0xE7) where v != 0:
            event = .press
        case (kHIDPage_GenericDesktop, kHIDUsage_GD_X), (kHIDPage_GenericDesktop, kHIDUsage_GD_Y):
            guard v != 0, IOHIDElementIsRelative(el) else { return }
            event = .move(Double(v))
        case (kHIDPage_GenericDesktop, kHIDUsage_GD_Wheel):
            guard v != 0 else { return }
            event = .scroll(Double(v))
        default:
            return
        }
        let now = Date()
        guard now >= detector.armedAt else { return }
        // Ekran Paylaşımı bağlı mı? (süreç listesi; en fazla 2 sn'de bir bakılır)
        if now.timeIntervalSince(viewerCheckedAt) > 2 {
            viewerActive = RemoteSessionProbe.current().screenSharing
            viewerCheckedAt = now
        }
        if detector.feed(event, at: now, remoteViewerActive: viewerActive) {
            fired = true
            let name = names[key] ?? "?"
            DispatchQueue.main.async { [weak self] in self?.onLocalInput?(name) }
        }
    }
}
#endif
