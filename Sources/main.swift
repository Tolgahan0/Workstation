import Cocoa

let bundleID = "com.tolgahanayaz.workstationmode"
let urlScheme = "workstation"
let setModeNotification = Notification.Name("com.tolgahanayaz.workstationmode.setMode")
let currentModeKey = "currentMode"

// MARK: - Komut satırı (ör. `WorkstationMode --mode remote --res 1512x982`)

/// `--mode X`, `--mode=X`, `--remote`, `--sleep`, `--desktop` biçimlerini destekler.
func modeFromArguments(_ args: [String]) -> WorkMode? {
    var i = 1
    while i < args.count {
        let arg = args[i]
        if arg == "--mode" || arg == "-mode" || arg == "-m", i + 1 < args.count {
            return WorkMode(argument: args[i + 1])
        }
        if arg.hasPrefix("--mode=") { return WorkMode(argument: String(arg.dropFirst("--mode=".count))) }
        if arg.hasPrefix("--"), let m = WorkMode(argument: String(arg.dropFirst(2))) { return m }
        i += 1
    }
    return nil
}

/// `--res 1512x982`, `--res=1512x982` veya `--preset mbp16` → normalleştirilmiş çözünürlük.
func resolutionFromArguments(_ args: [String]) -> String? {
    for (i, arg) in args.enumerated() {
        var value: String?
        if (arg == "--res" || arg == "--preset"), i + 1 < args.count { value = args[i + 1] }
        if arg.hasPrefix("--res=") { value = String(arg.dropFirst(6)) }
        if arg.hasPrefix("--preset=") { value = String(arg.dropFirst(9)) }
        if let v = value {
            if let p = RemotePreset.preset(id: v.lowercased()), p.id != "auto" { return p.resolution }
            if let r = RemotePreset.normalize(v) { return r }
        }
    }
    return nil
}

func printUsage() {
    print("""
    Kullanım:
      WorkstationMode                              Menü çubuğu uygulamasını başlatır
      WorkstationMode --mode remote [--res WxH]    Remote (isteğe bağlı istemci çözünürlüğü, ör. 1512x982)
      WorkstationMode --mode remote --preset mbp16 Ön ayar: mba13 mba15 mbp14 mbp16 imac24
      WorkstationMode --mode sleep                 Uyku / Gece
      WorkstationMode --mode desktop               Masaüstü
      WorkstationMode --status                     Geçerli modu yazdırır
      WorkstationMode --clean [--dry-run]          Disk temizleyici: yalnızca tarar ve listeler
      WorkstationMode --clean --yes                Seçili kategorileri temizler (her öğe silmeden önce yeniden denetlenir)
      WorkstationMode --clean --auto               Otomatik moddaki güvenli kümeyi temizler
    URL: workstation://remote[?res=WxH] | workstation://sleep | workstation://desktop
         workstation://profile/<ad> | workstation://fan/auto|half|max | workstation://keepawake/on|off|3h
         workstation://clean/scan | workstation://clean/auto
    """)
}

func readStoredMode() -> String {
    (CFPreferencesCopyAppValue(currentModeKey as CFString, bundleID as CFString) as? String) ?? WorkMode.desktop.rawValue
}

/// Komut satırı modu: isteği çalışan (GUI oturumundaki) örneğe iletir ve çıkar.
func forwardModeAndExit(_ mode: WorkMode, resolution: String?) -> Never {
    var url = "\(urlScheme)://\(mode.rawValue)"
    if mode == .remote, let r = resolution { url += "?res=\(r)" }
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-g", url]
    var ok = false
    do {
        try open.run()
        open.waitUntilExit()
        ok = open.terminationStatus == 0
    } catch {
        ok = false
    }
    if !ok {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if others.isEmpty {
            FileHandle.standardError.write("Hata: \(url) açılamadı ve çalışan WorkstationMode bulunamadı.\n".data(using: .utf8)!)
            exit(1)
        }
        let object = resolution.map { "\(mode.rawValue)?res=\($0)" } ?? mode.rawValue
        DistributedNotificationCenter.default().postNotificationName(
            setModeNotification, object: object, userInfo: nil, deliverImmediately: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }
    print("WorkstationMode → \(mode.title)\(resolution.map { " (\($0))" } ?? "") isteği gönderildi.")
    exit(0)
}

// MARK: - Giriş noktası

let arguments = CommandLine.arguments
// Disk temizleyici: arayüz olmadan çalışır (SSH'tan da). Örn. `--clean --dry-run`, `--clean --yes`, `--clean --auto`.
if arguments.contains("--clean") {
    setvbuf(stdout, nil, _IOLBF, 0)
    exit(CleanerCLI.run(arguments))
}
if arguments.contains("--help") || arguments.contains("-h") {
    printUsage()
    exit(0)
}
if arguments.contains("--status") {
    print(readStoredMode())
    exit(0)
}
if let requested = modeFromArguments(arguments) {
    forwardModeAndExit(requested, resolution: resolutionFromArguments(arguments))
}

// Aynı anda tek menü çubuğu örneği çalışsın.
let runningInstances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
if !runningInstances.isEmpty {
    NSLog("WorkstationMode zaten çalışıyor; bu örnek kapanıyor.")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // LSUIElement ile birlikte: Dock'ta görünmez
app.run()
