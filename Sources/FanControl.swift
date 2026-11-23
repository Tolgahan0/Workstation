import Foundation

/// Uygulama tarafı fan denetimi.
///  - Okuma: süreç içinde AppleSMC (root gerekmez); açılamazsa `sudo -n wm-fanhelper status`.
///  - Yazma: yalnızca `sudo -n /usr/local/libexec/wm-fanhelper set all <mod>` / `reset`.
///  - Boşta hiçbir zamanlayıcı çalışmaz. Tek istisna: "Yarım" modundayken 15 sn'de bir sıcaklık
///    bekçisi (95 °C üstünde Full Blast'a çıkar). Otomatik / Full Blast'ta bekçi yoktur.
final class FanController {
    static let helperPath = "/usr/local/libexec/wm-fanhelper"
    static let preferredKey = "fanMode"
    /// Manuel mod uygulandığında true, otomatiğe dönünce false. Açılışta true ise önceki oturum
    /// çökmüş demektir → önce reset.
    static let manualActiveKey = "fanManualActive"
    static let watchdogLimit: Double = 95

    private let queue = DispatchQueue(label: "com.tolgahanayaz.workstationmode.fan", qos: .utility)
    private let defaults = UserDefaults.standard
    private var watchdog: DispatchSourceTimer?
    #if os(macOS)
    private var reader: FanSMC?
    private var readerFailed = false
    #endif

    /// Uygulanmış (etkin) mod — bekçi Full Blast'a çıkardıysa .max olur.
    private(set) var appliedMode: FanMode = .auto
    /// Bekçi devreye girdiğinde (ana kuyrukta) çağrılır.
    var onWatchdog: ((Double) -> Void)?

    var preferredMode: FanMode {
        get { FanMode(rawValue: defaults.string(forKey: Self.preferredKey) ?? "") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: Self.preferredKey) }
    }

    static var helperInstalled: Bool { FileManager.default.isExecutableFile(atPath: helperPath) }

    // MARK: Okuma

    /// Anlık durum (arka planda). Fansız Mac'te fans boş döner.
    func readStatus(completion: @escaping (FanStatus) -> Void) {
        queue.async {
            let s = self.readStatusSync()
            DispatchQueue.main.async { completion(s) }
        }
    }

    private func readStatusSync() -> FanStatus {
        #if os(macOS)
        if reader == nil && !readerFailed {
            do { reader = try FanSMC() } catch {
                readerFailed = true
                Log.warn("Fan: AppleSMC doğrudan açılamadı (\(error)); yardımcı ile okunacak.")
            }
        }
        if let r = reader { return r.status() }
        #endif
        return helperStatus()
    }

    private func helperStatus() -> FanStatus {
        guard Self.helperInstalled else {
            var s = FanStatus()
            s.error = L("Fan yardımcısı kurulu değil")
            return s
        }
        let r = Shell.run("/usr/bin/sudo", ["-n", Self.helperPath, "status"], timeout: 8)
        guard r.succeeded, let data = r.stdout.data(using: .utf8),
              let s = try? JSONDecoder().decode(FanStatus.self, from: data) else {
            var s = FanStatus()
            s.error = L("Fan durumu okunamadı")
            return s
        }
        return s
    }

    // MARK: Yazma (yardımcı ile)

    private func runHelper(_ args: [String]) -> String? {
        guard Self.helperInstalled else { return L("Fan yardımcısı kurulu değil (DMG’deki Kurulum.command’ı ya da install.sh’yi çalıştır)") }
        let r = Shell.run("/usr/bin/sudo", ["-n", Self.helperPath] + args, timeout: 20)
        if r.succeeded { return nil }
        let msg = (r.stderr + " " + r.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        if msg.contains("password") || msg.contains("parola") {
            return L("sudo izni yok: /etc/sudoers.d/workstation_toggle (install.sh)")
        }
        return msg.isEmpty ? L("wm-fanhelper hata kodu %@", r.status) : msg
    }

    /// Modu uygular. Hata olursa güvenlik için reset denenir ve hata döner.
    func apply(_ mode: FanMode, reason: String, remember: Bool = true, completion: ((String?) -> Void)? = nil) {
        if remember { preferredMode = mode }
        queue.async {
            let err = self.applySync(mode, reason: reason)
            DispatchQueue.main.async { completion?(err) }
        }
    }

    private func applySync(_ mode: FanMode, reason: String) -> String? {
        Log.info("Fan: \(mode.title) uygulanıyor (\(reason))")
        if mode != .auto { defaults.set(true, forKey: Self.manualActiveKey) }
        let err = runHelper(["set", "all", mode.rawValue])
        if let e = err {
            Log.error("Fan: \(mode.title) uygulanamadı: \(e) → otomatiğe dönülüyor")
            _ = runHelper(["reset"])
            defaults.set(false, forKey: Self.manualActiveKey)
            appliedMode = .auto
            stopWatchdog()
            return e
        }
        appliedMode = mode
        if mode == .auto { defaults.set(false, forKey: Self.manualActiveKey) }
        if mode == .half { startWatchdog() } else { stopWatchdog() }
        Log.info("Fan: \(mode.title) etkin")
        return nil
    }

    /// Fanları sisteme bırakır (tercih korunur). Uyku / çıkış için eşzamanlı (en fazla ~6 sn).
    func resetSync(reason: String) {
        let needed = appliedMode != .auto || defaults.bool(forKey: Self.manualActiveKey)
        guard needed else { return }
        let work = {
            Log.info("Fan: otomatiğe dönülüyor (\(reason))")
            self.stopWatchdog()
            if let e = self.runHelper(["reset"]) { Log.error("Fan reset: \(e)") }
            self.appliedMode = .auto
            self.defaults.set(false, forKey: Self.manualActiveKey)
        }
        queue.sync(execute: work)
    }

    /// Eşzamansız reset (Uyku moduna geçerken).
    func reset(reason: String, completion: (() -> Void)? = nil) {
        queue.async {
            if self.appliedMode != .auto || self.defaults.bool(forKey: Self.manualActiveKey) {
                Log.info("Fan: otomatiğe dönülüyor (\(reason))")
                self.stopWatchdog()
                if let e = self.runHelper(["reset"]) { Log.error("Fan reset: \(e)") }
                self.appliedMode = .auto
                self.defaults.set(false, forKey: Self.manualActiveKey)
            }
            DispatchQueue.main.async { completion?() }
        }
    }

    /// Açılış: önceki oturum manuel modda çöktüyse reset; sonra tercih edilen modu uygula.
    func launchRecovery(reapply: Bool) {
        queue.async {
            if self.defaults.bool(forKey: Self.manualActiveKey) {
                Log.warn("Fan: önceki oturum manuel modda kapanmamış → reset")
                _ = self.runHelper(["reset"])
                self.defaults.set(false, forKey: Self.manualActiveKey)
            }
            if reapply, self.preferredMode != .auto {
                _ = self.applySync(self.preferredMode, reason: L("açılış"))
            }
        }
    }

    /// Tercih edilen modu yeniden uygular (uyanma / Uyku'dan çıkış).
    func reapplyPreferred(reason: String) {
        let mode = preferredMode
        guard mode != .auto else { return }
        queue.async {
            guard self.appliedMode != mode else { return }
            _ = self.applySync(mode, reason: reason)
        }
    }

    // MARK: Sıcaklık bekçisi (yalnızca Yarım modunda)

    private func startWatchdog() {
        stopWatchdog()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(5))
        t.setEventHandler { [weak self] in self?.watchdogTick() }
        t.resume()
        watchdog = t
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func watchdogTick() {
        guard appliedMode == .half else { stopWatchdog(); return }
        let s = readStatusSync()
        let hottest = [s.cpuTemp, s.gpuTemp].compactMap { $0 }.max() ?? 0
        guard hottest > Self.watchdogLimit else { return }
        Log.warn("Fan bekçisi: \(Int(hottest)) °C > \(Int(Self.watchdogLimit)) °C → Full Blast")
        _ = applySync(.max, reason: L("sıcaklık bekçisi"))
        DispatchQueue.main.async { self.onWatchdog?(hottest) }
    }
}
