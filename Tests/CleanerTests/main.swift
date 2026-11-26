import Foundation

// Linux/macOS'ta çalışan, bağımlılıksız test koşucusu: Tests/run-tests.sh

var failures = 0
var passed = 0
func check(_ cond: @autoclosure () -> Bool, _ msg: String, file: String = #file, line: Int = #line) {
    if cond() { passed += 1 } else { failures += 1; print("✖ \(msg)  (\((file as NSString).lastPathComponent):\(line))") }
}

let fm = FileManager.default
let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path + "/wm-cleaner-tests-" + UUID().uuidString.prefix(8)
let home = tmp + "/home"
try! fm.createDirectory(atPath: home, withIntermediateDirectories: true)
CleanHistory.directoryOverride = URL(fileURLWithPath: tmp + "/state")
let old = Date().addingTimeInterval(-40 * 86400)

func write(_ rel: String, _ text: String = "x", size: Int = 0) {
    let p = home + "/" + rel
    try! fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let data = size > 0 ? Data(count: size) : text.data(using: .utf8)!
    _ = fm.createFile(atPath: p, contents: data)
}
func age(_ rel: String, _ date: Date = old) {
    let root = home + "/" + rel
    var paths = [root]
    if let en = fm.enumerator(atPath: root) { for case let s as String in en { paths.append(root + "/" + s) } }
    for p in paths.sorted(by: { $0.count > $1.count }) { try? fm.setAttributes([.modificationDate: date], ofItemAtPath: p) }
}
func git(_ dir: String, _ args: String...) {
    let r = Shell.run("/usr/bin/git", ["-C", home + "/" + dir] + args, timeout: 20)
    if !r.succeeded { print("git hata: \(args) \(r.stderr)") }
}

// MARK: PathGuard
do {
    let h = "/Users/a"
    check(PathGuard.check("/Users/a", home: h, neverTouch: []) == .protectedPath, "ev klasörü korunur")
    check(PathGuard.check("/Users/a/Library", home: h, neverTouch: []) == .protectedPath, "Library korunur")
    check(PathGuard.check("/Users/a/Library/Caches", home: h, neverTouch: []) == .protectedPath, "Library/Caches korunur")
    check(PathGuard.check("/Users/a/Library/Caches/foo", home: h, neverTouch: []) == nil, "Library/Caches/foo silinebilir")
    check(PathGuard.check("/Users/a/Desktop", home: h, neverTouch: []) == .protectedPath, "Desktop korunur")
    check(PathGuard.check("/Users/a/Desktop/app/node_modules", home: h, neverTouch: []) == nil, "proje içi hedef")
    check(PathGuard.check("/Users/a/.ssh/id", home: h, neverTouch: []) == .protectedPath, ".ssh korunur")
    check(PathGuard.check("/Users/a/.claude/projects/x", home: h, neverTouch: []) == .protectedPath, "claude projects korunur")
    check(PathGuard.check("/Users/a/.claude/todos/x.json", home: h, neverTouch: []) == nil, "claude todos silinebilir")
    check(PathGuard.check("/Users/a/p/.git/objects", home: h, neverTouch: []) == .protectedPath, ".git korunur")
    check(PathGuard.check("/opt/x", home: h, neverTouch: []) == .protectedPath, "ev dışı korunur")
    check(PathGuard.check("/Users/ab/x/y", home: h, neverTouch: []) == .protectedPath, "benzer önekli başka kullanıcı")
    check(PathGuard.check("/Users/a/work/app/node_modules", home: h, neverTouch: ["~/work/app"]) == .denyList, "dokunma listesi")
    check(PathGuard.check("/Users/a/work/app", home: h, neverTouch: ["~/work/app/keep"]) == .denyList, "dokunma listesini kapsayan üst klasör")
    check(PathGuard.check("/Users/a/../a/x/y", home: h, neverTouch: []) == nil, "normalize")
}

// MARK: OpenFileIndex
do {
    let out = "p1\nfcwd\nn/Users/a/proj\nf3\nn/Users/a/cache/x/file\np2\nftxt\nn/Users/a/cache-b/y\nf4\nn/private/tmp/z\n"
    let idx = OpenFileIndex.parse(lsofOutput: out, keepUnder: ["/Users/a"])
    check(idx.hasOpenFile(under: "/Users/a/cache") == "/Users/a/cache/x/file", "önek eşleşmesi")
    check(idx.hasOpenFile(under: "/Users/a/cache/x/file") != nil, "tam eşleşme")
    check(idx.hasOpenFile(under: "/Users/a/cach") == nil, "kısmi ad eşleşmez")
    check(idx.hasOpenFile(under: "/Users/a/other") == nil, "ilgisiz")
    check(idx.hasOpenFile(under: "/private/tmp") == nil, "ev dışı süzülür")
    check(idx.hasProcessCwd(under: "/Users/a/proj") != nil, "cwd")
    check(idx.hasProcessCwd(under: "/Users/a/proj2") == nil, "cwd benzer ad")
    let ps = ProcessList.parse("  12 /Applications/Xcode.app/Contents/MacOS/Xcode\n 99 java -cp gradle-launcher.jar org.gradle.launcher.daemon.bootstrap.GradleDaemon 8.7\n")
    check(ps.xcodeRunning && ps.gradleRunning && !ps.emulatorRunning, "süreç algılama")
}

// MARK: Kurallar
do {
    check(CleanerRules.version(in: "iPhone15,2 17.4.1 (21E236)") == [17, 4, 1], "DeviceSupport sürümü")
    check(CleanerRules.version(in: "16.0 (20A362)") == [16, 0], "DeviceSupport sürümü 2")
    check(CleanerRules.gradleWrapperDist(fromProperties: "distributionBase=GRADLE_USER_HOME\ndistributionUrl=https\\://services.gradle.org/distributions/gradle-8.7-bin.zip\n") == "gradle-8.7-bin", "wrapper")
    check(CleanerRules.gradleVersion("gradle-8.10.2-all") == [8, 10, 2], "gradle sürümü")
    check(CleanerRules.compareVersions([8, 9], [8, 10]), "sürüm karşılaştırma")
    let split = CleanerRules.olderThanNewest([("a", 1), ("a", 3), ("a", 2), ("b", 5)], keep: 2, group: { $0.0 }, isNewer: { $0.1 > $1.1 })
    check(split.old.map { $0.1 } == [1] && split.kept.count == 3, "en yeni N")
    check(CleanerRules.brewFreeBytes("This operation would free approximately 1.2GB of disk space.") == 1_200_000_000, "brew")
    check(CleanerRules.parseSize("512MB") == 512_000_000 && CleanerRules.parseSize("12.5kB") == 12_500, "boyut")
    let d = CleanerRules.dockerReclaimable("Images\t2.1GB (40%)\nBuild Cache\t800MB\nLocal Volumes\t0B (0%)\n")
    check(d["Images"] == 2_100_000_000 && d["Build Cache"] == 800_000_000 && d["Local Volumes"] == 0, "docker df")
    let b = CleanerRules.battery("Now drawing from 'Battery Power'\n -InternalBattery-0 (id=123)\t25%; discharging; 2:00 remaining")
    check(b?.percent == 25 && b?.onBattery == true, "pil")
    check(CleanerRules.battery("Now drawing from 'AC Power'\n") == nil, "pil yok (Mac mini)")
}

// MARK: URL yolları
do {
    check(URLRoute.parse("workstation://clean/scan") == .clean(.scan), "clean/scan")
    check(URLRoute.parse("workstation://clean/auto") == .clean(.auto), "clean/auto")
    check(URLRoute.parse("workstation://clean") == .clean(.scan), "clean varsayılan")
    check(URLRoute.parse("workstation://clean/sil") == nil, "bilinmeyen clean")
    check(CleanerCLI.mode(from: ["x", "--clean"]) == .dryRun && CleanerCLI.mode(from: ["x", "--clean", "--yes"]) == .yes, "CLI modu")
}

// MARK: Ağ bilgisi (Wake-on-LAN)
do {
    check(!NetworkInfo.isUsableMAC("02:00:00:00:00:00"), "gizlilik yer tutucusu reddedilir")
    check(!NetworkInfo.isUsableMAC("00:00:00:00:00:00") && !NetworkInfo.isUsableMAC("3a:11:22:33:44:55"), "sıfır/yerel yönetimli reddedilir")
    check(NetworkInfo.isUsableMAC("F0:18:98:AA:BB:CC"), "gerçek adres")
    let n = NetworkInfo.parse("INTERFACE=en0\nPORT=Ethernet\nMAC=02:00:00:00:00:00\nIP=192.168.1.5\n")
    check(n.mac.isEmpty && n.friendlyInterface == "Kablolu (Ethernet)" && !n.configText.contains("MAC="), "netinfo ayrıştırma")
    check(NetworkInfo.parse("PORT=Wi-Fi\nMAC=f0:18:98:aa:bb:cc").friendlyInterface == "Wi-Fi", "Wi-Fi adı")
}

// MARK: Otomatik mod
do {
    var s = CleanerSettings()
    check(CleanerAutoPolicy.nextDaily(after: Date(), settings: s) == nil, "kapalıyken zamanlama yok")
    s.autoEnabled = true; s.autoHour = 4; s.autoMinute = 0
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Istanbul")!
    let base = cal.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 14))!
    let next = CleanerAutoPolicy.nextDaily(after: base, settings: s, calendar: cal)!
    check(cal.component(.day, from: next) == 24 && cal.component(.hour, from: next) == 4, "sonraki gün 04:00")
    let total: Int64 = 500_000_000_000
    check(CleanerAutoPolicy.shouldRunLowSpace(free: 15_000_000_000, total: total, settings: s, lastRun: nil, now: base), "20 GB altı")
    check(!CleanerAutoPolicy.shouldRunLowSpace(free: 15_000_000_000, total: total, settings: s, lastRun: base.addingTimeInterval(-3600), now: base), "6 sa aralık")
    check(!CleanerAutoPolicy.shouldRunLowSpace(free: 100_000_000_000, total: total, settings: s, lastRun: nil, now: base), "yeterli alan")
    check(CleanerAutoPolicy.blocker(battery: (20, true), cpuPercent: 10, settings: s) != nil, "düşük pil engeller")
    check(CleanerAutoPolicy.blocker(battery: nil, cpuPercent: 90, settings: s) != nil, "yoğun işlemci engeller")
    check(CleanerAutoPolicy.blocker(battery: nil, cpuPercent: 20, settings: s) == nil, "uygun")
    check(s.isAuto(.derivedData) && !s.isAuto(.trash) && !s.isAuto(.dockerVolumes) && !s.isAuto(.nodeModules), "varsayılan otomatik küme")
    let enc = try! JSONEncoder().encode(s)
    check((try? JSONDecoder().decode(CleanerSettings.self, from: enc)) == s, "ayar kodlama")
}

// MARK: Tarayıcı + uygulayıcı (sahte ev klasörü)
do {
    // p1: pasif, git'te node_modules/.next/dist yok sayılıyor → silinebilir
    write("Projects/p1/package.json", "{}"); write("Projects/p1/package-lock.json", "{}")
    write("Projects/p1/node_modules/a/index.js", size: 40_000)
    write("Projects/p1/.next/cache/x", size: 10_000)
    write("Projects/p1/dist/main.js", size: 5_000)
    write("Projects/p1/.gitignore", "node_modules\n.next\ndist\n")
    git("Projects/p1", "init", "-q"); git("Projects/p1", "add", "."); git("Projects/p1", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "i")
    age("Projects/p1")
    // p2: aktif proje
    write("Projects/p2/package.json", "{}"); write("Projects/p2/yarn.lock", "")
    write("Projects/p2/node_modules/b/index.js", size: 1000)
    write("Projects/p2/src/app.ts", "new")
    age("Projects/p2/node_modules")
    // p3: node_modules git'te kayıtlı
    write("Projects/p3/package.json", "{}"); write("Projects/p3/package-lock.json", "{}")
    write("Projects/p3/node_modules/c/index.js", "c")
    git("Projects/p3", "init", "-q"); git("Projects/p3", "add", "."); git("Projects/p3", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "i")
    age("Projects/p3")
    // p4: kilit dosyası yok
    write("Projects/p4/package.json", "{}"); write("Projects/p4/node_modules/d/i.js", "d"); age("Projects/p4")
    // p5: dist yok sayılmıyor
    write("Projects/p5/package.json", "{}"); write("Projects/p5/package-lock.json", "{}"); write("Projects/p5/dist/x.js", "x")
    git("Projects/p5", "init", "-q"); age("Projects/p5")
    // p6: açık dosya, p7: çalışan süreç
    write("Projects/p6/package.json", "{}"); write("Projects/p6/package-lock.json", "{}"); write("Projects/p6/node_modules/e/i.js", "e"); age("Projects/p6")
    write("Projects/p7/package.json", "{}"); write("Projects/p7/package-lock.json", "{}"); write("Projects/p7/node_modules/f/i.js", "f"); age("Projects/p7")
    // Android projesi + Gradle sürümleri
    write("Dev/rn/package.json", "{}"); write("Dev/rn/package-lock.json", "{}")
    write("Dev/rn/android/app/build.gradle", "x"); write("Dev/rn/android/app/build/out.apk", size: 30_000)
    write("Dev/rn/android/gradle/wrapper/gradle-wrapper.properties", "distributionUrl=https\\://services.gradle.org/distributions/gradle-8.7-bin.zip\n")
    age("Dev/rn")
    for d in ["gradle-8.7-bin", "gradle-7.5-bin", "gradle-8.9-all"] { write(".gradle/wrapper/dists/\(d)/x/gradle.zip", size: 2000) }
    age(".gradle")
    // DerivedData: proje yok → silinebilir; aktif p2 → atlanır
    let plist1 = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>WorkspacePath</key><string>\(home)/Gone/App.xcodeproj</string></dict></plist>"
    let plist2 = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>WorkspacePath</key><string>\(home)/Projects/p2/App.xcworkspace</string></dict></plist>"
    write("Library/Developer/Xcode/DerivedData/Gone-abc/info.plist", plist1); write("Library/Developer/Xcode/DerivedData/Gone-abc/Build/x", size: 8000)
    write("Library/Developer/Xcode/DerivedData/App-def/info.plist", plist2)
    write("Projects/p2/App.xcworkspace/contents.xcworkspacedata", "x")
    age("Library/Developer/Xcode/DerivedData")
    // Claude günlükleri
    write(".claude/todos/old.json", size: 3000); write(".claude/todos/new.json", "n"); age(".claude/todos/old.json")
    write(".claude/projects/mem.jsonl", "keep"); age(".claude/projects")
    write(".claude/settings.json", "{}"); age(".claude/settings.json")

    let openIdx = OpenFileIndex(open: [home + "/Projects/p6/node_modules/e/i.js"], cwds: [home + "/Projects/p7"])
    let snap = SystemSnapshot(openFiles: openIdx, processes: ProcessList(procs: []))
    var settings = CleanerSettings()
    settings.permanentForCaches = true
    let scanner = CleanerScanner(settings: settings, home: home, snapshot: snap)
    scanner.runTools = false
    scanner.rootsOverride = [home]
    let cats: [CleanCategory] = [.nodeModules, .jsBuildOutputs, .androidBuilds, .gradleWrapperDists, .derivedData, .agentLogs]
    let report = scanner.scan(cats)
    func find(_ c: CleanCategory, _ suffix: String) -> CleanItem? {
        report.results.first { $0.category == c }?.items.first { ($0.path ?? "").hasSuffix(suffix) }
    }
    check(find(.nodeModules, "p1/node_modules")?.skip == nil, "p1 node_modules silinebilir")
    check((find(.nodeModules, "p1/node_modules")?.bytes ?? 0) >= 40_000, "boyut ölçüldü")
    check(find(.nodeModules, "p2/node_modules")?.skip == .activeProject, "aktif proje atlanır")
    check(find(.nodeModules, "p3/node_modules")?.skip == .gitTracked, "git'te kayıtlı atlanır")
    check(find(.nodeModules, "p4/node_modules")?.skip == .noLockfile, "kilit dosyası yok")
    check(find(.nodeModules, "p6/node_modules")?.skip == .openFiles, "açık dosya")
    check(find(.nodeModules, "p7/node_modules")?.skip == .runningProcess, "çalışan süreç")
    check(find(.jsBuildOutputs, "p1/dist")?.skip == nil, "yok sayılan dist")
    check(find(.jsBuildOutputs, "p5/dist")?.skip == .notIgnored, "yok sayılmayan dist")
    check(find(.jsBuildOutputs, "p1/.next")?.skip == nil, ".next")
    check(find(.androidBuilds, "android/app/build")?.skip == nil, "android build")
    check(find(.gradleWrapperDists, "gradle-8.7-bin")?.skip == .referenced, "kullanılan gradle")
    check(find(.gradleWrapperDists, "gradle-8.9-all")?.skip == .keptNewest, "en yeni gradle")
    check(find(.gradleWrapperDists, "gradle-7.5-bin")?.skip == nil, "eski gradle silinebilir")
    check(find(.derivedData, "Gone-abc")?.skip == nil, "sahipsiz DerivedData")
    check(find(.derivedData, "App-def")?.skip == .activeProject, "aktif projenin DerivedData'sı")
    check(find(.agentLogs, ".claude/todos")?.isActionable == true, "claude todos ayıklanır")
    check(report.results.flatMap { $0.items }.allSatisfy { !($0.path ?? "").contains(".claude/projects") }, "claude projects listelenmez")

    // Güvenilmez açık dosya denetimi → hiçbir proje öğesi silinemez
    let blind = CleanerScanner(settings: settings, home: home, snapshot: SystemSnapshot(openFiles: .unavailable, processes: ProcessList(procs: [])))
    blind.runTools = false; blind.rootsOverride = [home]
    let br = blind.scan([.nodeModules, .derivedData])
    check(br.selectedItems.isEmpty && !br.inUseCheckOK, "denetim yapılamazsa silme yok")

    // Uygulama: tarama ile silme arasında p1 yeniden aktif olursa atlanmalı
    let exec = CleanerExecutor(settings: settings, home: home)
    exec.snapshotProvider = { snap }
    var trashed: [String] = []
    exec.trashHandler = { url in trashed.append(url.path); try FileManager.default.removeItem(at: url) }
    write("Projects/p1/src/touched.ts", "now")
    let rec = exec.run(report.selectedItems, trigger: .manual)
    check(fm.fileExists(atPath: home + "/Projects/p1/node_modules"), "yeniden aktif proje korunur")
    check(rec.entries.contains { $0.title.hasSuffix("p1/node_modules") && $0.result.contains("aktif") }, "yeniden denetim kaydı")
    check(!fm.fileExists(atPath: home + "/Library/Developer/Xcode/DerivedData/Gone-abc"), "DerivedData kalıcı silindi (önbellek)")
    check(!fm.fileExists(atPath: home + "/.gradle/wrapper/dists/gradle-7.5-bin"), "eski gradle silindi")
    check(fm.fileExists(atPath: home + "/.gradle/wrapper/dists/gradle-8.7-bin"), "kullanılan gradle duruyor")
    check(trashed.contains { $0.hasSuffix("android/app/build") }, "proje çıktısı Çöp'e")
    check(!fm.fileExists(atPath: home + "/.claude/todos/old.json") && fm.fileExists(atPath: home + "/.claude/todos/new.json"), "yalnızca eski günlük")
    check(fm.fileExists(atPath: home + "/.claude/projects/mem.jsonl") && fm.fileExists(atPath: home + "/.claude/settings.json"), "claude ayar/hafıza duruyor")
    check(fm.fileExists(atPath: home + "/Projects/p1/src/touched.ts") && fm.fileExists(atPath: home + "/Projects/p1/package.json"), "kaynak dosyalar duruyor")
    check(CleanHistory.load().count == 1, "geçmiş yazıldı")

    // Sembolik bağlantı hedefi asla izlenmez
    write("Secret/important.txt", "keep")
    try? fm.createSymbolicLink(atPath: home + "/Projects/p8", withDestinationPath: home + "/Secret")
    let fake = CleanItem(id: "x", category: .nodeModules, path: home + "/Projects/p8", title: "p8")
    check(exec.execute(fake, snapshot: snap) == .skipped("sembolik bağlantı"), "bağlantı silinmez")
    check(fm.fileExists(atPath: home + "/Secret/important.txt"), "bağlantı hedefi duruyor")

    // Kilit
    let l1 = CleanerLock(), l2 = CleanerLock()
    check(l1.acquire() && !l2.acquire(), "tek temizlik kilidi")
    l1.release()
    check(l2.acquire(), "kilit bırakıldı"); l2.release()

    let text = CleanerCLI.render(report, home: home, verbose: true)
    check(text.contains("Toplam temizlenebilir"), "CLI çıktısı")
}

// MARK: Güncelleyici
do {
    func v(_ s: String) -> SemVer { SemVer(s)! }
    check(v("1.8.0") > v("1.7.9"), "sürüm sıralaması")
    check(v("v1.10.0") > v("1.9.3"), "çok haneli sürüm")
    check(v("1.8.0") > v("1.8.0-beta.2"), "kararlı > ön sürüm")
    check(v("1.8.0-beta.10") > v("1.8.0-beta.2"), "sayısal ön sürüm")
    check(v("1.8.0-rc.1") > v("1.8.0-beta.9"), "rc > beta")
    check(v("1.8") == v("1.8.0"), "eksik yama = 0")
    check(SemVer("abc") == nil && SemVer("1.x") == nil && SemVer("") == nil, "geçersiz sürüm")
    check(v("1.8.0+45") == v("1.8.0"), "derleme üst verisi yok sayılır")

    let json = """
    [{"tag_name":"v1.9.0-beta.1","prerelease":true,"draft":false,"assets":[]},
     {"tag_name":"v2.0.0","prerelease":false,"draft":true,"assets":[]},
     {"tag_name":"v1.8.0","name":"Workstation 1.8.0","body":"## Workstation 1.8.0\\n- Temizleyici\\n**Kurulum:** x","prerelease":false,
      "html_url":"https://github.com/x/y/releases/tag/v1.8.0",
      "assets":[{"name":"latest.json","url":"https://api.github.com/a/1","browser_download_url":"https://github.com/d/latest.json","size":10},
                {"name":"Workstation-1.8.0.zip","url":"https://api.github.com/a/2","browser_download_url":"https://github.com/d/W.zip"}]},
     {"tag_name":"v1.7.0","prerelease":false,"assets":[]}]
    """
    let rels = try! JSONDecoder().decode([GitHubRelease].self, from: json.data(using: .utf8)!)
    check(UpdatePolicy.pick(rels, current: v("1.7.0"), beta: false)?.tag_name == "v1.8.0", "kararlı sürüm seçilir, taslak atlanır")
    check(UpdatePolicy.pick(rels, current: v("1.7.0"), beta: true)?.tag_name == "v1.9.0-beta.1", "beta açıkken ön sürüm")
    check(UpdatePolicy.pick(rels, current: v("1.8.0"), beta: false) == nil, "güncel → yok")
    check(UpdatePolicy.pick(rels, current: v("1.9.0"), beta: true) == nil, "eski sürüme inilmez")
    let r18 = rels[2]
    check(r18.zipAsset?.name == "Workstation-1.8.0.zip" && r18.asset(named: "latest.json")?.url == "https://api.github.com/a/1", "dosyalar bulunur")
    check(UpdatePolicy.shortNotes(r18.body) == "Workstation 1.8.0\n• Temizleyici", "notlar sadeleşir")

    let m = try! JSONDecoder().decode(UpdateManifest.self, from: """
    {"version":"1.8.0","build":"120","zip_name":"Workstation-1.8.0.zip","sha256":"\(String(repeating: "a", count: 64))","helper_version":"3","notes":""}
    """.data(using: .utf8)!)
    check(m.version == "1.8.0" && UpdatePolicy.isValidSHA256(m.sha256), "latest.json okunur")
    check(!UpdatePolicy.isValidSHA256("abc") && !UpdatePolicy.isValidSHA256(String(repeating: "z", count: 64)), "geçersiz SHA")

    let ud = UserDefaults(suiteName: "wm-test-\(UUID().uuidString)")!
    check(UpdateSettings.load(ud) == UpdateSettings() && !UpdateSettings().autoInstall, "varsayılan: sadece haber ver")
    var us = UpdateSettings(); us.beta = true; us.save(ud)
    check(UpdateSettings.load(ud).beta, "ayar kaydı")

    // Değiştirme betiği sözdizimi
    let sp = tmp + "/swap.sh"
    try! Updater.swapScript.write(toFile: sp, atomically: true, encoding: .utf8)
    check(Shell.run("/bin/bash", ["-n", sp], timeout: 10).succeeded, "güncelleme betiği geçerli bash")
    check(Updater.swapScript.contains("xattr -dr com.apple.quarantine") && Updater.swapScript.contains("WorkstationMode.app"), "betik karantina + eski uygulama")
}

// MARK: Zamanlanmış modlar: kapalı kural hiçbir şey tetiklememeli
do {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/Istanbul")!
    let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 12))!   // Pazartesi
    var sleepRule = ScheduleRule(); sleepRule.hour = 23; sleepRule.minute = 30; sleepRule.mode = .sleep
    var desk = ScheduleRule(); desk.hour = 8; desk.minute = 0; desk.mode = .desktop; desk.weekdays = [2, 3, 4, 5, 6]
    check(ScheduleEngine.nextFire(after: now, rules: [sleepRule], calendar: cal)?.rule.id == sleepRule.id, "etkin kural tetiklenir")
    sleepRule.enabled = false
    check(ScheduleEngine.nextFire(after: now, rules: [sleepRule], calendar: cal) == nil, "kapalı kural tetiklenmez")
    let week = cal.date(byAdding: .day, value: 7, to: now)!
    check(ScheduleEngine.due(from: now, to: week, rules: [sleepRule], calendar: cal).isEmpty, "kapalı kural kaçırılmış sayılmaz")
    check(ScheduleEngine.pmsetRepeatArgs(rules: [sleepRule]) == nil, "uyku kuralı pmset yazmaz")
    check(ScheduleEngine.pmsetRepeatArgs(rules: [desk]) == ["repeat", "wakeorpoweron", "MTWRF", "07:58:00"], "masaüstü kuralı 2 dk önce uyandırır")
    desk.enabled = false
    check(ScheduleEngine.pmsetRepeatArgs(rules: [desk, sleepRule]) == nil, "hiç etkin kural yoksa planlı uyanma temizlenir")
    check(ScheduleEngine.nextFire(after: now, rules: [desk, sleepRule], calendar: cal) == nil, "tüm kurallar kapalı → zamanlayıcı yok")
    let ud = UserDefaults(suiteName: "wm-sched-\(UUID().uuidString)")!
    var ss = ScheduleSettings(); ss.rules = [desk, sleepRule]; ss.wakeEnabled = true; ss.save(ud)
    let back = ScheduleSettings.load(ud)
    check(back.rules.count == 2 && back.rules.allSatisfy { !$0.enabled } && back.wakeEnabled, "kapalı durum kalıcı")
}

// MARK: Güncelleme bildirimi, depo adı, test beslemesi
do {
    check(UpdatePolicy.checkInterval == 3600, "saatte bir kontrol")
    check(UpdatePolicy.shouldNotify(version: "1.9.1", lastNotified: nil), "ilk kez bildir")
    check(!UpdatePolicy.shouldNotify(version: "1.9.1", lastNotified: "1.9.1"), "aynı sürüm için bir kez")
    check(UpdatePolicy.shouldNotify(version: "1.9.2", lastNotified: "1.9.1"), "yeni sürüm yeniden bildirilir")
    check(UpdateSettings().repo == "Tolgahan0/Workstation", "asıl depo adı")
    let ud = UserDefaults(suiteName: "wm-upd-\(UUID().uuidString)")!
    var old = UpdateSettings(); old.repo = "Tolgahan0/workstation"; old.save(ud)
    check(UpdateSettings.load(ud).repo == "Tolgahan0/Workstation", "eski depo adı taşınır")
    check(UpdatePolicy.feedOverride(ud, env: [:]) == nil, "besleme yoksa nil")
    ud.set("/tmp/x/latest.json", forKey: "updateFeedURL")
    check(UpdatePolicy.feedOverride(ud, env: [:])?.isFileURL == true, "yerel besleme")
    check(UpdatePolicy.feedOverride(ud, env: ["WORKSTATION_UPDATE_FEED": "https://e.com/l.json"])?.host == "e.com", "ortam değişkeni önceliklidir")
    let asx = Updater.helperInstallAppleScript(app: "/Applications/Work \"x\".app", user: "ayaz")
    check(asx.hasSuffix("with administrator privileges") && asx.contains("quoted form of \"/Applications/Work \\\"x\\\".app/Contents/Resources/install-helper.sh\""), "AppleScript tırnaklama")
    check(!Updater.swapScript.contains("with administrator privileges\" >/dev/null"), "betik yardımcı için parola penceresi açmaz")
}

// MARK: Remote ön ayarları (çentik altı)
do {
    check(RemotePreset.preset(matching: "1512x945")?.id == "mbp14n", "14 inç çentik altı ön ayarı")
    check(RemotePreset.preset(matching: "1728x1080")?.id == "mbp16n", "16 inç çentik altı ön ayarı")
    check(RemotePreset.aspect(of: "1512x945").map { $0 == (8, 5) } == true, "1512x945 → 8:5")
    check(RemotePreset.fallback.resolution == "1512x945", "varsayılan 14 inç tam ekran (çentik altı)")
}

// MARK: Yer tutucu ekran (macOS'un "Generic Display"i) fiziksel monitör sayılmaz
do {
    let generic = PhysicalDisplayRecord(id: 34, vendor: 1970170734, model: 1986622068, serial: 0, name: "")
    let hp = PhysicalDisplayRecord(id: 1, vendor: 8718, model: 14387, serial: 16843009, name: "HP P27h G5")
    let odyssey = PhysicalDisplayRecord(id: 2, vendor: 19501, model: 1, serial: 0, name: "Odyssey G50F")
    let gone = PhysicalDisplayRecord(id: 9, vendor: UInt32.max, model: UInt32.max, serial: 0, name: "")
    check(generic.isPlaceholder, "Generic Display yer tutucu sayılır")
    check(gone.isPlaceholder, "var olmayan displayID (0xFFFFFFFF) yer tutucu sayılır")
    check(!hp.isPlaceholder && !odyssey.isPlaceholder, "gerçek monitörler yer tutucu değil")
}

// MARK: Kaynaklar: uygulamaya göre gruplama
do {
    let G = ProcessGrouping.classify
    let chrome = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/131/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
    check(G("Google Chrome Helper (Renderer)", chrome, []).title == "Google Chrome", "Chrome yardımcıları Google Chrome'a toplanır")
    check(G("Google Chrome", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", []).key == G("x", chrome, []).key, "Chrome ana süreç ile aynı grup")
    check(G("launchd_sim", "/Library/Developer/CoreSimulator/Volumes/iOS_22A/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 18.0.simruntime/Contents/Resources/RuntimeRoot/sbin/launchd_sim", []).kind == .simulator, "launchd_sim simülatör")
    check(G("SpringBoard", "/Library/Developer/CoreSimulator/Volumes/iOS/RuntimeRoot/System/Library/CoreServices/SpringBoard.app/SpringBoard", []).title == ProcessGrouping.simulatorTitle, "simülatör içi süreçler iOS Simülatörü")
    check(G("Simulator", "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator", []).kind == .simulator, "Simulator.app simülatör (Xcode değil)")
    check(G("claude", "/Users/a/.local/share/claude/versions/2.0.1", []).title == "Claude Code", "claude ikilisi")
    check(G("claude.exe", "/claude", []).title == "Claude Code", "claude.exe (yerel kurulum)")
    check(G("SimMetalHost", "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/SimRenderingServices.simdeviceio/Contents/XPCServices/SimMetalHost.xpc/Contents/MacOS/SimMetalHost", []).kind == .simulator, "SimMetalHost simülatör")
    check(G("node", "/opt/homebrew/bin/node", ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"]).title == "Claude Code", "node üzerinde claude-code")
    check(G("node", "/Users/a/.local/bin/node", ["node", "/Users/a/.local/share/cursor-agent/versions/x/index.js"]).title == "Cursor Agent", "cursor-agent")
    check(G("node", "/opt/homebrew/bin/node", ["node", "server.js"]).title == "Node.js", "sıradan node → Node.js")
    check(G("node", "/opt/homebrew/bin/node", ["node", "server.js"]).kind == .agent, "node aday sayılır")
    check(G("Cursor Helper (Plugin)", "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)", ["node", "cursor-agent"]).title == "Cursor", "Cursor.app yardımcıları uygulamaya (ajan değil)")
    check(G("WindowServer", "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", []).kind == .system, "WindowServer sistem")
    check(G("Finder", "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", []).kind == .system, "/System içindeki uygulama sistem")
    check(G("mds_stores", "/System/Library/Frameworks/CoreServices.framework/mds_stores", []).kind == .system, "mds sistem")
    check(G("zsh", "/bin/zsh", []).kind == .system, "/bin sistem")
    check(G("com.docker.backend", "/Applications/Docker.app/Contents/MacOS/com.docker.backend", []).key == "app.Docker", "Docker arka ucu Docker'a")
    check(G("python3", "/opt/homebrew/bin/python3", []).kind == .other, "python ajan değil")
    check(ProcessGrouping.outermostApp("/usr/local/bin/x") == nil, "uygulama paketi yok")
}

// MARK: Kaynaklar: boşta kararı ve bildirim
do {
    let now = Date()
    func h(_ pts: [(Double, Double)]) -> [(Date, Double)] { pts.map { (now.addingTimeInterval(-$0.0 * 60), $0.1) } }
    check(IdlePolicy.isIdle(history: h([(20, 10), (10, 10.5), (0, 10.6)]), now: now, minutes: 15), "15 dk'da 0.6 sn CPU → boşta")
    check(!IdlePolicy.isIdle(history: h([(20, 10), (0, 40)]), now: now, minutes: 15), "15 dk'da 30 sn CPU → meşgul")
    check(!IdlePolicy.isIdle(history: h([(5, 10), (0, 10)]), now: now, minutes: 15), "yeterli geçmiş yok → boşta sayılmaz")
    check(!IdlePolicy.isIdle(history: [], now: now, minutes: 15), "geçmiş yok")
    check(IdlePolicy.shouldNotify(level: 2, previous: 1) && IdlePolicy.shouldNotify(level: 4, previous: 2), "baskı yükselince bildirim")
    check(!IdlePolicy.shouldNotify(level: 2, previous: 2) && !IdlePolicy.shouldNotify(level: 2, previous: 4) && !IdlePolicy.shouldNotify(level: 1, previous: 1), "aynı/düşen seviyede bildirim yok")
    check(NotificationPolicy.minInterval("memoryPressure") == 30 * 60, "bellek bildirimi 30 dk sınırlı")
    let old = try! JSONDecoder().decode(NotificationSettings.self, from: #"{"overheat":false,"lowDisk":true,"unexpectedExit":true}"#.data(using: .utf8)!)
    check(!old.overheat && old.memoryPressure, "eski bildirim ayarları korunur, yeni alan varsayılan açık")
    let mb = MemoryBreakdown(total: 16, app: 5, wired: 2, compressed: 1, cached: 6, swapUsed: 0)
    check(mb.used == 8, "kullanılan = uygulama + sabit + sıkıştırılmış (önbellek hariç)")
}

// MARK: Remote'tan yerel çıkış (takılı klavye/fare)
do {
    let P = LocalInputPolicy.isPhysical
    check(P("USB", "AJAZZ 2.4G", false) && P("USB", "2.4G Wireless Receiver", false), "USB alıcılar fiziksel")
    check(P("Bluetooth", "Magic Mouse", false) && P("Bluetooth Low Energy", "MX Keys", false), "Bluetooth fiziksel")
    check(!P("Virtual", "Screen Sharing Keyboard", false) && !P(nil, "x", false) && !P("", "x", false), "sanal/taşıyıcısız aygıt fiziksel değil")
    check(!P("USB", "Karabiner DriverKit VirtualHIDKeyboard", false), "Karabiner sanal klavye fiziksel değil")
    check(!P("USB", "Mouse", true), "VirtualDevice işaretli aygıt fiziksel değil")
    let t0 = Date()
    var d = LocalInputDetector(armedAt: t0.addingTimeInterval(20))
    check(!d.feed(.press, at: t0.addingTimeInterval(5), remoteViewerActive: false), "bekleme süresinde tık yok sayılır")
    check(d.feed(.press, at: t0.addingTimeInterval(21), remoteViewerActive: false), "izleyici yokken tek tık yeter")
    var m = LocalInputDetector(armedAt: t0)
    check(!m.feed(.move(40), at: t0.addingTimeInterval(1), remoteViewerActive: false), "küçük titreme yetmez")
    check(!m.feed(.move(100), at: t0.addingTimeInterval(1.3), remoteViewerActive: false), "henüz eşik altında")
    check(m.feed(.move(-200), at: t0.addingTimeInterval(1.6), remoteViewerActive: false), "1 sn içinde belirgin hareket tetikler")
    var slow = LocalInputDetector(armedAt: t0)
    var fired = false
    for i in 0..<20 { fired = fired || slow.feed(.move(50), at: t0.addingTimeInterval(Double(i) * 2), remoteViewerActive: false) }
    check(!fired, "seyrek küçük hareketler (titreşim) tetiklemez")
    var v = LocalInputDetector(armedAt: t0)
    check(!v.feed(.move(5000), at: t0.addingTimeInterval(1), remoteViewerActive: true), "izleyici bağlıyken hareket yok sayılır")
    check(!v.feed(.press, at: t0.addingTimeInterval(2), remoteViewerActive: true), "izleyici bağlıyken tek tık yetmez")
    check(v.feed(.press, at: t0.addingTimeInterval(3.5), remoteViewerActive: true), "izleyici bağlıyken 3 sn içinde 2 tık tetikler")
    var w = LocalInputDetector(armedAt: t0)
    check(w.feed(.scroll(6), at: t0.addingTimeInterval(1), remoteViewerActive: false), "belirgin kaydırma tetikler")
}

// MARK: Uzaktan erişim teşhisi
do {
    check(RemoteAccessDiagnostics.screenSharingEnabled(launchctlOutput: "disabled services = {\n\t\t\"com.apple.screensharing\" => enabled\n}"), "Ekran Paylaşımı açık")
    check(!RemoteAccessDiagnostics.screenSharingEnabled(launchctlOutput: "\t\t\"com.apple.screensharing\" => disabled"), "Ekran Paylaşımı kapalı")
    check(!RemoteAccessDiagnostics.screenSharingEnabled(launchctlOutput: "\"com.openssh.sshd\" => enabled"), "anahtar yoksa kapalı")
    check(NetworkInfo.isTailscale("100.98.61.110") && !NetworkInfo.isTailscale("100.200.1.1") && !NetworkInfo.isTailscale("192.168.1.34"), "Tailscale CGNAT aralığı")
    let n = NetworkInfo.parse("IP=192.168.1.34\nHOSTNAME=studio.local\nTAILSCALE_IP=100.98.61.110\nTAILSCALE_NAME=studio.tail9cb433.ts.net\n")
    check(n.remoteAddress == "studio.tail9cb433.ts.net", "dışarıdan adres MagicDNS adı")
    check(NetworkInfo.parse("TAILSCALE_IP=100.98.61.110").remoteAddress == "100.98.61.110", "ad yoksa Tailscale IP")
    check(NetworkInfo.parse("HOSTNAME=studio.local").remoteAddress.isEmpty, "Tailscale yoksa dışarıdan adres yok")
}

// MARK: İstemci: sanal ekranı Ekran Paylaşımı alanına uydurma
do {
    check(ClientGeometry.fullscreenTarget(screenWidth: 1512, screenHeight: 982, safeTop: 37) == "1512x945", "14\" tam ekran = çentik altı 1512x945")
    check(ClientGeometry.fullscreenTarget(screenWidth: 1728, screenHeight: 1117, safeTop: 37) == "1728x1080", "16\" tam ekran = 1728x1080")
    check(ClientGeometry.fullscreenTarget(screenWidth: 2560, screenHeight: 1440, safeTop: 0) == "2560x1440", "çentiksiz ekran tam boy")
    let scr = (w: 1512.0, h: 982.0)
    check(ClientGeometry.target(window: (0, 37, 1512, 945), screen: scr, safeTop: 37, toolbar: 52) == "1512x945", "tam ekran pencere (çentik altı): araç çubuğu yok")
    check(ClientGeometry.target(window: (0, 0, 1512, 982), screen: scr, safeTop: 37, toolbar: 52) == "1512x945", "tüm ekranı kaplayan pencere: çentik payı düşülür")
    check(ClientGeometry.target(window: (0, 37, 1512, 945 - 0), screen: scr, safeTop: 37, toolbar: 52) != "1512x893", "tam ekranda araç çubuğu düşülmez")
    check(ClientGeometry.target(window: (0, 37, 1512, 900), screen: scr, safeTop: 37, toolbar: 52) == "1512x848", "büyütülmüş pencere: araç çubuğu düşülür")
    check(ClientGeometry.target(window: (0, 0, 200, 100), screen: scr, safeTop: 37) == nil, "çok küçük pencere yok sayılır")
    check(ClientGeometry.resolution(1511.4, 944.6) == "1511x945", "tam sayıya yuvarlanır")
    check(!ClientGeometry.differsEnough("1512x945", "1512x948") && ClientGeometry.differsEnough("1512x945", "1512x893"), "küçük oynamada yeniden uydurma yok")
    check(URLRoute.parse("workstation://fit?res=1512x945") == .fit("1512x945"), "fit URL'si")
    check(URLRoute.parse("workstation://fit/1512x893") == .fit("1512x893"), "fit yol biçimi")
    check(URLRoute.parse("workstation://fit?res=abc") == nil, "geçersiz fit")
}

// MARK: İstemci: Mac mini duyurusu → yapılandırma
do {
    var info = NetworkInfo()
    info.hostname = "studio.local"; info.tailscaleName = "studio.tail9cb433.ts.net"; info.tailscaleIP = "100.98.61.110"
    info.mac = "c8:80:6d:38:80:c0"; info.broadcast = "192.168.1.255"
    let txt = StudioBeacon.txt(info: info, user: "ayaz", version: "1.9.7")
    let cfg = StudioBeacon.config(fromTXT: txt)
    check(cfg?["HOST"] == "studio.local" && cfg?["ALT_HOST"] == "studio.tail9cb433.ts.net", "duyurudan ev + Tailscale adresi")
    check(cfg?["SSH_USER"] == "ayaz" && cfg?["MAC"] == "c8:80:6d:38:80:c0" && cfg?["BROADCAST"] == "192.168.1.255", "kullanıcı, MAC, yayın")
    check(StudioBeacon.config(fromTXT: ["host": "x.local"]) == nil, "studio olmayan duyuru yok sayılır")
    var user = ClientConfig.parse("# elle\nHOST=studio\nVNC_HOST=\"studio.local\"\nWAKE_TIMEOUT=60\n")
    check(user.values["HOST"] == "studio" && user.values["VNC_HOST"] == "studio.local", "yapılandırma okunur (tırnaklar atılır)")
    let changed = user.merge(cfg!, overwrite: ["ALT_HOST", "MAC", "BROADCAST", "SSH_USER"])
    check(changed && user.values["HOST"] == "studio" && user.values["ALT_HOST"] == "studio.tail9cb433.ts.net", "kullanıcının HOST'u korunur, Tailscale eklenir")
    check(user.values["WAKE_TIMEOUT"] == "60", "diğer ayarlar korunur")
    check(!user.merge(cfg!, overwrite: ["ALT_HOST"]), "aynı duyuru ikinci kez değişiklik yapmaz")
    let out = user.serialized(header: "test")
    check(ClientConfig.parse(out) == ClientConfig.parse(out) && ClientConfig.parse(out).values == user.values, "yaz-oku tutarlı")
}

// MARK: Dil
do {
    check(L10n.isTurkish, "test ortamı Türkçe")
    check(L("%@ dk", 5) == "5 dk", "yer tutucu")
    var bad: [String] = []
    for (k, v) in L10n.en where k.components(separatedBy: "%@").count != v.components(separatedBy: "%@").count { bad.append(k) }
    check(bad.isEmpty, "İngilizce çeviriler aynı sayıda %@ içerir: \(bad)")
    check(L10n.en.values.allSatisfy { !$0.isEmpty }, "boş çeviri yok")
}

try? fm.removeItem(atPath: tmp)
print(failures == 0 ? "✔ \(passed) test geçti" : "✖ \(failures) başarısız, \(passed) geçti")
exit(failures == 0 ? 0 : 1)
