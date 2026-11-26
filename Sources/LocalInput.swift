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
    /// Tetiklenince bir kez çağrılır (aygıt adıyla).
    var onLocalInput: ((String) -> Void)?
    var isRunning: Bool { manager != nil }
    var deviceNames: [String] { Array(Set(names.values)).sorted() }

    /// Klavyeler için Giriş İzleme izni gerekir; izin yokken yalnızca fareler izlenir (izin penceresi açılmaz).
    static var keyboardAccessGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Kullanıcı ayarlardan isteyince: sistem izin penceresini açar.
    static func requestKeyboardAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
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
        let openText = r == kIOReturnSuccess ? "tamam" : String(format: "0x%x", r)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self, self.manager != nil else { return }
            Log.info("Yerel giriş izleniyor (Remote'tan çıkış için): fareler\(keyboards ? " + klavyeler" : " (klavye için Giriş İzleme izni yok)") · açılış \(openText) · aygıtlar: \(self.deviceNames.joined(separator: ", "))")
            if self.allowed.isEmpty { self.installFallback() }
        }
    }

    /// Yedek (HID aygıtları açılamazsa): pencere sunucusunun fare olayları; yalnızca donanımdan gelenler
    /// (kaynak süreç 0 + HID sistem durumu) ve Ekran Paylaşımı bağlı DEĞİLKEN sayılır.
    private func installFallback() {
        guard fallbackMonitor == nil else { return }
        Log.warn("Yerel giriş: HID aygıtları açılamadı; yedek olarak fare olayları izleniyor")
        fallbackMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .mouseMoved, .scrollWheel]) { [weak self] e in
            guard let self = self, !self.fired, let c = e.cgEvent else { return }
            guard c.getIntegerValueField(.eventSourceUnixProcessID) == 0,
                  c.getIntegerValueField(.eventSourceStateID) == Int64(CGEventSourceStateID.hidSystemState.rawValue) else { return }
            let now = Date()
            if now.timeIntervalSince(self.viewerCheckedAt) > 2 {
                self.viewerActive = RemoteSessionProbe.current().screenSharing
                self.viewerCheckedAt = now
            }
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
