import Foundation
#if canImport(Glibc)
import Glibc
#endif

// Geliştirici Temizleyici — çekirdek (yalnızca Foundation; Linux'ta derlenir ve test edilir).
// Burada saf modeller ve güvenlik kuralları bulunur. Tarama: CleanerScanner.swift, silme: CleanerExecutor.swift.

// MARK: - Kategoriler

enum CleanGroup: String, Codable, CaseIterable {
    case xcode, android, js, iosDeps, homebrew, docker, langs, agents, system

    var title: String {
        switch self {
        case .xcode: return L("Xcode ve simülatörler")
        case .android: return "Android"
        case .js: return "JavaScript"
        case .iosDeps: return "CocoaPods"
        case .homebrew: return "Homebrew"
        case .docker: return "Docker"
        case .langs: return "Python · Rust · Go"
        case .agents: return L("Yapay zekâ araçları")
        case .system: return L("Çöp ve uygulama önbellekleri")
        }
    }

    var icon: String {
        switch self {
        case .xcode: return "hammer"
        case .android: return "iphone.gen1"
        case .js: return "curlybraces"
        case .iosDeps: return "shippingbox"
        case .homebrew: return "mug"
        case .docker: return "cube.box"
        case .langs: return "chevron.left.forwardslash.chevron.right"
        case .agents: return "sparkles"
        case .system: return "trash"
        }
    }
}

/// Silme biçimi: Çöp'e taşı (geri alınabilir) veya — yeniden oluşturulabilen önbelleklerde, "Kalıcı sil" açıksa — kalıcı sil.
enum DeleteStyle: String, Codable {
    case trash          // her zaman Çöp Sepeti
    case cache          // varsayılan Çöp; "Kalıcı sil" açıksa doğrudan silinir
    case permanent      // Çöp Sepeti'nin kendisi gibi: yalnızca kalıcı
}

enum CleanCategory: String, Codable, CaseIterable, Identifiable {
    // Xcode
    case derivedData, xcodeArchives, deviceSupport, unavailableSimulators, simulatorCaches, simulatorRuntimes
    // Android
    case androidBuilds, gradleWrapperDists, gradleVersionCaches, gradleModuleCache, avdSnapshots, androidSDK
    // JS
    case nodeModules, npmCache, pnpmStore, yarnCache, bunCache, jsBuildOutputs, playwrightBrowsers
    // iOS bağımlılıkları
    case cocoapodsCache, podsDirs
    // Homebrew / Docker
    case homebrew, homebrewAutoremove, dockerDangling, dockerVolumes
    // Diller
    case pipCache, uvCache, cargoCache, rustTargets, goBuildCache
    // Yapay zekâ araçları
    case editorServers, agentLogs
    // Sistem
    case trash, appCaches

    var id: String { rawValue }

    var group: CleanGroup {
        switch self {
        case .derivedData, .xcodeArchives, .deviceSupport, .unavailableSimulators, .simulatorCaches, .simulatorRuntimes: return .xcode
        case .androidBuilds, .gradleWrapperDists, .gradleVersionCaches, .gradleModuleCache, .avdSnapshots, .androidSDK: return .android
        case .nodeModules, .npmCache, .pnpmStore, .yarnCache, .bunCache, .jsBuildOutputs, .playwrightBrowsers: return .js
        case .cocoapodsCache, .podsDirs: return .iosDeps
        case .homebrew, .homebrewAutoremove: return .homebrew
        case .dockerDangling, .dockerVolumes: return .docker
        case .pipCache, .uvCache, .cargoCache, .rustTargets, .goBuildCache: return .langs
        case .editorServers, .agentLogs: return .agents
        case .trash, .appCaches: return .system
        }
    }

    var title: String {
        switch self {
        case .derivedData: return L("Eski derleme klasörleri (DerivedData)")
        case .xcodeArchives: return L("Eski arşivler")
        case .deviceSupport: return L("Eski cihaz destek dosyaları")
        case .unavailableSimulators: return L("Kullanılamayan simülatörler")
        case .simulatorCaches: return L("Simülatör önbelleği")
        case .simulatorRuntimes: return L("Simülatör sürümleri (öneri)")
        case .androidBuilds: return L("Android derleme çıktıları")
        case .gradleWrapperDists: return L("Kullanılmayan Gradle sürümleri")
        case .gradleVersionCaches: return L("Eski Gradle önbellekleri")
        case .gradleModuleCache: return L("Gradle bağımlılık önbelleği (tamamı)")
        case .avdSnapshots: return L("Emülatör anlık görüntüleri")
        case .androidSDK: return L("Android SDK eski sürümler (öneri)")
        case .nodeModules: return L("node_modules (pasif projeler)")
        case .npmCache: return L("npm / npx önbelleği")
        case .pnpmStore: return L("pnpm deposu")
        case .yarnCache: return L("Yarn önbelleği")
        case .bunCache: return L("Bun önbelleği")
        case .jsBuildOutputs: return L("Web derleme çıktıları (.next, dist…)")
        case .playwrightBrowsers: return L("Eski Playwright/Puppeteer tarayıcıları")
        case .cocoapodsCache: return L("CocoaPods önbelleği")
        case .podsDirs: return L("Pods klasörleri (pasif projeler)")
        case .homebrew: return L("Homebrew eski paketleri")
        case .homebrewAutoremove: return L("Homebrew artık gerekmeyen paketler (öneri)")
        case .dockerDangling: return L("Docker: sahipsiz imajlar ve derleme önbelleği")
        case .dockerVolumes: return L("Docker: kullanılmayan birimler")
        case .pipCache: return L("pip önbelleği")
        case .uvCache: return L("uv önbelleği")
        case .cargoCache: return L("Cargo indirme önbelleği")
        case .rustTargets: return L("Rust target klasörleri (pasif projeler)")
        case .goBuildCache: return L("Go derleme önbelleği")
        case .editorServers: return L("Eski Cursor/VS Code sunucu sürümleri")
        case .agentLogs: return L("Claude / Cursor / Codex eski günlükleri")
        case .trash: return L("Çöp Sepeti (eski öğeler)")
        case .appCaches: return L("Kapalı uygulamaların eski önbellekleri")
        }
    }

    /// Kullanıcıya gösterilen kısa açıklama (teknik terim yok).
    var hint: String {
        switch self {
        case .derivedData: return L("Xcode tekrar açınca yeniden oluşturur. Son günlerde açtığın projelere dokunulmaz.")
        case .xcodeArchives: return L("Her uygulamanın en yeni 2 arşivi kalır. Çöp'e taşınır.")
        case .deviceSupport: return L("Bağladığın telefonların eski iOS sürümleri için. En yeni 2 sürüm kalır.")
        case .unavailableSimulators: return L("Artık açılamayan simülatörler Xcode'un kendi komutuyla silinir.")
        case .simulatorCaches: return L("Simülatör ilk açılışta yeniden oluşturur.")
        case .simulatorRuntimes: return L("Sadece listelenir, silinmez. İstersen Xcode ayarlarından kaldırırsın.")
        case .androidBuilds: return L("Son günlerde dokunmadığın projelerin derleme klasörleri. Bir sonraki derlemede geri gelir.")
        case .gradleWrapperDists: return L("Hiçbir projenin kullanmadığı Gradle sürümleri.")
        case .gradleVersionCaches: return L("Artık kullanılmayan Gradle sürümlerine ait önbellekler.")
        case .gradleModuleCache: return L("Tüm indirilen bağımlılıklar. Silinirse ilk derlemede yeniden indirilir.")
        case .avdSnapshots: return L("Emülatörün hızlı açılış kayıtları. Emülatör açıkken dokunulmaz.")
        case .androidSDK: return L("Sadece listelenir, silinmez.")
        case .nodeModules: return L("Yalnızca kilit dosyası olan projelerde. İstediğin an yeniden kurulur.")
        case .npmCache: return L("npm'in kendi temizliği çalışır; eski npx indirmeleri Çöp'e taşınır.")
        case .pnpmStore: return L("pnpm'in kendi temizliği: hiçbir projenin kullanmadığı paketler.")
        case .yarnCache: return L("Yarn önbelleğinin tamamı silinir, gerekince yeniden indirilir.")
        case .bunCache: return L("Bun önbelleğinin tamamı silinir, gerekince yeniden indirilir.")
        case .jsBuildOutputs: return L("Pasif projelerin derleme çıktıları. dist yalnızca git'te yok sayılıyorsa.")
        case .playwrightBrowsers: return L("Her tarayıcının en yeni sürümü kalır.")
        case .cocoapodsCache: return L("CocoaPods önbelleğinin tamamı silinir.")
        case .podsDirs: return L("Pasif projelerde. pod install ile geri gelir.")
        case .homebrew: return L("Homebrew'un kendi temizliği: 30 günden eski indirmeler ve eski sürümler.")
        case .homebrewAutoremove: return L("Sadece listelenir.")
        case .dockerDangling: return L("Yalnızca etiketsiz imajlar ve kullanılmayan derleme önbelleği. Konteynerlere dokunulmaz.")
        case .dockerVolumes: return L("Hiçbir konteynerin kullanmadığı birimler. İçlerindeki veri kaybolur.")
        case .pipCache: return L("Eski indirmeler, gerekince yeniden indirilir.")
        case .uvCache: return L("uv'nin kendi temizliği: kullanılmayan paketler.")
        case .cargoCache: return L("Eski crate indirmeleri.")
        case .rustTargets: return L("Pasif Rust projelerinin derleme klasörleri.")
        case .goBuildCache: return L("Go'nun kendi temizliği.")
        case .editorServers: return L("En yeni ve şu an çalışan sürüm kalır.")
        case .agentLogs: return L("Sadece eski günlük ve geçici dosyalar. Ayarlar, oturum ve hafıza dosyalarına dokunulmaz.")
        case .trash: return L("30 günden uzun süredir Çöp'te duran öğeler kalıcı silinir.")
        case .appCaches: return L("Şu an açık olmayan uygulamaların uzun süredir dokunulmamış önbellekleri.")
        }
    }

    /// Yalnızca bilgi verir, asla silmez.
    var suggestOnly: Bool {
        switch self {
        case .simulatorRuntimes, .androidSDK, .homebrewAutoremove: return true
        default: return false
        }
    }

    /// Elle taramada varsayılan olarak seçili mi?
    var defaultEnabled: Bool {
        switch self {
        case .gradleModuleCache, .avdSnapshots, .yarnCache, .bunCache, .cocoapodsCache, .dockerVolumes,
             .goBuildCache, .trash, .appCaches, .xcodeArchives:
            return false
        default:
            return true
        }
    }

    /// Otomatik modda çalıştırılabilir mi (güvenli ve kendiliğinden geri gelen)?
    var autoEligible: Bool {
        switch self {
        case .derivedData, .unavailableSimulators, .simulatorCaches, .homebrew, .androidBuilds, .jsBuildOutputs,
             .npmCache, .pnpmStore, .uvCache, .gradleWrapperDists, .gradleVersionCaches, .deviceSupport,
             .playwrightBrowsers, .editorServers, .agentLogs, .pipCache, .cargoCache, .dockerDangling, .nodeModules, .podsDirs, .rustTargets:
            return true
        default:
            return false
        }
    }

    /// Otomatik modda varsayılan olarak açık olanlar (en güvenli küme).
    var autoDefault: Bool {
        switch self {
        case .derivedData, .unavailableSimulators, .homebrew, .androidBuilds, .jsBuildOutputs, .npmCache, .pnpmStore, .uvCache:
            return true
        default:
            return false
        }
    }

    var deleteStyle: DeleteStyle {
        switch self {
        case .trash: return .permanent
        case .derivedData, .simulatorCaches, .gradleWrapperDists, .gradleVersionCaches, .gradleModuleCache, .npmCache,
             .pipCache, .cargoCache, .playwrightBrowsers, .editorServers, .deviceSupport, .appCaches:
            return .cache
        default:
            return .trash
        }
    }

    /// Yaş eşiği (gün) — nil: eşik yok.
    var defaultAgeDays: Int? {
        switch self {
        case .derivedData: return 7
        case .androidBuilds, .jsBuildOutputs, .podsDirs, .rustTargets: return 7
        case .nodeModules: return 14
        case .npmCache, .pipCache, .trash, .appCaches, .agentLogs, .simulatorCaches: return 30
        case .cargoCache, .gradleVersionCaches: return 60
        case .deviceSupport: return 90
        case .avdSnapshots: return 30
        default: return nil
        }
    }

    static func inGroup(_ g: CleanGroup) -> [CleanCategory] { allCases.filter { $0.group == g } }
}

// MARK: - Öğeler

enum CleanAction: Codable, Equatable {
    /// Dosya/klasör silme (biçim kategoriden gelir).
    case delete
    /// Aracın kendi temizlik komutu (mutlak yol + argümanlar).
    case command(String, [String])
    /// Klasördeki `gün` günden eski dosyaları kalıcı siler (önbellekler için; klasörün kendisi kalır).
    case pruneFiles(Int)
    /// Sadece bilgi.
    case suggest
}

enum SkipReason: String, Codable, Equatable {
    case activeProject, openFiles, runningProcess, gitTracked, denyList, protectedPath, recent, keptNewest,
         referenced, toolRunning, notIgnored, noLockfile, unverified, noAccess

    var text: String {
        switch self {
        case .activeProject: return L("aktif proje — atlandı")
        case .openFiles: return L("açık dosya var — atlandı")
        case .runningProcess: return L("çalışan program — atlandı")
        case .gitTracked: return L("git'te kayıtlı — atlandı")
        case .denyList: return L("dokunma listesinde")
        case .protectedPath: return L("korunan yol")
        case .recent: return L("yakında kullanıldı")
        case .keptNewest: return L("en yenisi — tutuldu")
        case .referenced: return L("bir proje kullanıyor")
        case .toolRunning: return L("araç şu an çalışıyor — atlandı")
        case .notIgnored: return L("git'te yok sayılmıyor — atlandı")
        case .noLockfile: return L("kilit dosyası yok — atlandı")
        case .unverified: return L("kullanım kontrol edilemedi — atlandı")
        case .noAccess: return L("erişim izni yok")
        }
    }
}

struct CleanItem: Codable, Identifiable, Equatable {
    var id: String
    var category: CleanCategory
    var path: String?
    var title: String
    var detail: String = ""
    var bytes: Int64 = 0
    var modified: Date?
    var skip: SkipReason?
    var action: CleanAction = .delete
    /// Proje düzeyindeki hedefler için proje kökü (silmeden hemen önce yeniden denetlenir).
    var projectRoot: String?
    /// Proje bu kadar gündür dokunulmamış olmalı (silmeden önce yeniden denetlenir).
    var inactiveDays: Int?
    var selected: Bool = true

    var isActionable: Bool { skip == nil && action != .suggest }
}

struct CategoryResult: Codable, Identifiable, Equatable {
    var category: CleanCategory
    var items: [CleanItem] = []
    var note: String?
    var id: String { category.rawValue }

    var actionable: [CleanItem] { items.filter { $0.isActionable } }
    var selectedBytes: Int64 { items.filter { $0.isActionable && $0.selected }.reduce(0) { $0 + $1.bytes } }
    var reclaimableBytes: Int64 { actionable.reduce(0) { $0 + $1.bytes } }
}

struct ScanReport: Codable, Equatable {
    var date: Date
    var results: [CategoryResult]
    var duration: TimeInterval
    var inUseCheckOK: Bool
    var cancelled = false

    var selectedBytes: Int64 { results.reduce(0) { $0 + $1.selectedBytes } }
    var reclaimableBytes: Int64 { results.reduce(0) { $0 + $1.reclaimableBytes } }
    var selectedItems: [CleanItem] { results.flatMap { $0.items.filter { $0.isActionable && $0.selected } } }
}

// MARK: - Ayarlar

struct CleanerSettings: Codable, Equatable {
    /// Elle taramada seçili kategoriler (anahtar: rawValue).
    var enabled: [String: Bool] = [:]
    /// Otomatik modda çalışacak kategoriler.
    var autoCategories: [String: Bool] = [:]
    /// Kategori başına yaş eşiği (gün).
    var ageDays: [String: Int] = [:]
    /// Önbelleklerde Çöp yerine kalıcı sil.
    var permanentForCaches = false
    /// Asla dokunulmayacak yollar (önek).
    var neverTouch: [String] = []
    /// Ek proje kökleri.
    var extraRoots: [String] = []
    /// Ev klasöründe tarama derinliği.
    var maxDepth = 6

    // Otomatik mod
    var autoEnabled = false
    var autoDaily = true
    var autoHour = 4
    var autoMinute = 0
    var autoLowSpace = true
    var autoLowSpaceGB = 20
    var autoLowSpacePercent = 10
    var autoMinBatteryPercent = 30
    var autoMaxCPUPercent = 70

    static let key = "cleanerSettings"

    func isEnabled(_ c: CleanCategory) -> Bool { enabled[c.rawValue] ?? c.defaultEnabled }
    func isAuto(_ c: CleanCategory) -> Bool { c.autoEligible && (autoCategories[c.rawValue] ?? c.autoDefault) }
    func age(_ c: CleanCategory) -> Int? {
        guard let d = c.defaultAgeDays else { return nil }
        return max(1, ageDays[c.rawValue] ?? d)
    }

    static func load(_ d: UserDefaults = .standard) -> CleanerSettings {
        guard let data = d.data(forKey: key), let s = try? JSONDecoder().decode(CleanerSettings.self, from: data) else {
            return CleanerSettings()
        }
        return s
    }

    func save(_ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key) }
    }
}

// MARK: - Yol güvenliği

enum PathGuard {
    /// Sondaki "/" atılmış, standartlaştırılmış yol.
    static func normalize(_ p: String) -> String {
        var s = (p as NSString).standardizingPath
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// `path`, `root`'un kendisi ya da altında mı?
    static func isPath(_ path: String, under root: String) -> Bool {
        let p = normalize(path), r = normalize(root)
        if r == "/" { return true }
        return p == r || p.hasPrefix(r + "/")
    }

    /// Ev klasöründe asla silinmeyecek adlar / yollar (göreli).
    static let protectedRelative: [String] = [
        ".ssh", ".gnupg", ".aws", ".config/gh", ".git-credentials", ".netrc", ".zshrc", ".zprofile", ".bashrc",
        "Library/Keychains", "Library/Mobile Documents", "Library/Mail", "Library/Messages", "Library/Photos",
        "Pictures", "Music", "Movies",
        ".claude/projects", ".claude/settings.json", ".claude/settings.local.json", ".claude/.credentials.json",
        ".claude/CLAUDE.md", ".claude/commands", ".claude/agents", ".claude/plugins",
        ".cursor/mcp.json", ".cursor/rules", ".codex/auth.json", ".codex/config.toml",
    ]

    static let protectedNames: Set<String> = [".git", "CLAUDE.md", "AGENTS.md", ".env", "credentials.json", ".credentials.json"]

    /// nil = silinebilir; aksi halde neden.
    static func check(_ rawPath: String, home: String, neverTouch: [String]) -> SkipReason? {
        let path = normalize(rawPath)
        let h = normalize(home)
        // Ev klasörünün dışı ve kökler: yalnızca araç komutları dokunabilir.
        guard isPath(path, under: h), path != h else { return .protectedPath }
        let rel = String(path.dropFirst(h.count + 1))
        let comps = rel.split(separator: "/").map(String.init)
        // Ev klasörünün birinci düzeyi (Library, Desktop, Documents, .npm …) asla bütün olarak silinmez.
        if comps.count < 2 && !rel.hasPrefix(".Trash/") { return .protectedPath }
        if comps.contains(where: { protectedNames.contains($0) }) { return .protectedPath }
        for p in protectedRelative where isPath(path, under: h + "/" + p) { return .protectedPath }
        // Library kökü ve birinci düzey (Library/Caches, Library/Developer …) bütün olarak silinmez.
        if comps.first == "Library" && comps.count < 3 { return .protectedPath }
        for raw in neverTouch {
            let n = normalize(expandTilde(raw, home: h))
            if !n.isEmpty, isPath(path, under: n) || isPath(n, under: path) { return .denyList }
        }
        return nil
    }

    static func expandTilde(_ p: String, home: String) -> String {
        if p == "~" { return home }
        if p.hasPrefix("~/") { return home + String(p.dropFirst(1)) }
        return p
    }

    static func display(_ p: String, home: String) -> String {
        let h = normalize(home)
        if isPath(p, under: h) { return "~" + String(normalize(p).dropFirst(h.count)) }
        return p
    }
}

// MARK: - Açık dosyalar ve çalışan programlar

/// `lsof -F pfn` çıktısından: açık dosyalar ve süreç çalışma klasörleri (sıralı; önek sorgusu ikili aramayla).
struct OpenFileIndex {
    private(set) var open: [String] = []
    private(set) var cwds: [String] = []
    var reliable: Bool

    init(open: [String], cwds: [String], reliable: Bool = true) {
        self.open = Array(Set(open.map(PathGuard.normalize))).sorted()
        self.cwds = Array(Set(cwds.map(PathGuard.normalize))).sorted()
        self.reliable = reliable
    }

    static let unavailable = OpenFileIndex(open: [], cwds: [], reliable: false)

    static func parse(lsofOutput: String, keepUnder roots: [String]) -> OpenFileIndex {
        var open: [String] = []
        var cwds: [String] = []
        var fd = ""
        for line in lsofOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tag = line.first else { continue }
            switch tag {
            case "p": fd = ""
            case "f": fd = String(line.dropFirst())
            case "n":
                let name = String(line.dropFirst())
                guard name.hasPrefix("/") else { continue }
                // lsof bazen " (deleted)" vb. ek yazar.
                let clean = name.components(separatedBy: " (").first ?? name
                guard roots.isEmpty || roots.contains(where: { PathGuard.isPath(clean, under: $0) }) else { continue }
                if fd == "cwd" { cwds.append(clean) } else { open.append(clean) }
            default: continue
            }
        }
        return OpenFileIndex(open: open, cwds: cwds)
    }

    private static func anyUnder(_ sorted: [String], _ root: String) -> String? {
        let r = PathGuard.normalize(root)
        // r'nin kendisi
        var lo = 0, hi = sorted.count
        while lo < hi { let mid = (lo + hi) / 2; if sorted[mid] < r { lo = mid + 1 } else { hi = mid } }
        var i = lo
        while i < sorted.count {
            let s = sorted[i]
            if s == r || s.hasPrefix(r + "/") { return s }
            // "r" ile başlamayan ilk eleman: r/ alt yolları da artık gelmez (r + "/" > r + "-" değil, bu yüzden biraz ilerle).
            if !s.hasPrefix(r) { break }
            i += 1
        }
        return nil
    }

    /// `root` altında açık dosya var mı?
    func hasOpenFile(under root: String) -> String? { OpenFileIndex.anyUnder(open, root) }
    /// Çalışma klasörü `root` altında olan bir süreç var mı?
    func hasProcessCwd(under root: String) -> String? { OpenFileIndex.anyUnder(cwds, root) }
}

/// `ps -axww -o pid=,args=` çıktısı.
struct ProcessList {
    struct Proc: Equatable { let pid: Int32; let args: String }
    var procs: [Proc]

    static func parse(_ output: String) -> ProcessList {
        var list: [Proc] = []
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let sp = line.firstIndex(of: " "), let pid = Int32(line[..<sp]) else { continue }
            list.append(Proc(pid: pid, args: line[sp...].trimmingCharacters(in: .whitespaces)))
        }
        return ProcessList(procs: list)
    }

    func any(_ predicate: (String) -> Bool) -> Bool { procs.contains { predicate($0.args) } }
    func contains(_ fragment: String) -> Bool { any { $0.contains(fragment) } }

    var xcodeRunning: Bool { any { $0.contains("/Contents/MacOS/Xcode") || $0.hasPrefix("xcodebuild") || $0.contains("/usr/bin/xcodebuild") || $0.contains("XCBBuildService") } }
    var gradleRunning: Bool { any { $0.contains("org.gradle.launcher") || $0.contains("GradleDaemon") || $0.contains("gradle-launcher") || $0.contains("GradleWrapperMain") } }
    var simulatorRunning: Bool { any { $0.contains("Simulator.app/Contents/MacOS/Simulator") || $0.contains("launchd_sim") } }
    var emulatorRunning: Bool { any { $0.contains("qemu-system") || $0.contains("/emulator/emulator") } }
    var packageManagerRunning: Bool { any { a in
        ["npm install", "npm ci", "pnpm install", "pnpm i ", "yarn install", "bun install", "pod install", "brew install", "brew upgrade"].contains { a.contains($0) }
    } }

    /// Çalışan bir uygulama paketinin kimliği / adı (önbellek klasörü eşlemesi için).
    func mentions(_ token: String) -> Bool {
        guard token.count >= 3 else { return false }
        let t = token.lowercased()
        return any { $0.lowercased().contains(t) }
    }
}

// MARK: - Saf yardımcılar

enum CleanerRules {
    /// "17.4 (21E219)", "iPhone15,2 17.4.1 (21E236)", "watchOS 10.2" → [17, 4, 1]
    static func version(in text: String) -> [Int]? {
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
        for t in tokens {
            let parts = t.split(separator: ".")
            guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { continue }
            return parts.compactMap { Int($0) }
        }
        // "gradle-8" gibi tek sayı
        for t in tokens where !t.isEmpty && t.allSatisfy(\.isNumber) { return [Int(t)!] }
        return nil
    }

    static func compareVersions(_ a: [Int], _ b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    /// gradle-wrapper.properties → "gradle-8.7-bin"
    static func gradleWrapperDist(fromProperties text: String) -> String? {
        for line in text.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("distributionUrl") else { continue }
            guard let slash = l.range(of: "/", options: .backwards) else { continue }
            var name = String(l[slash.upperBound...])
            if name.hasSuffix(".zip") { name.removeLast(4) }
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// "gradle-8.7-bin" → [8, 7]
    static func gradleVersion(_ dist: String) -> [Int]? {
        var s = dist
        if s.hasPrefix("gradle-") { s.removeFirst(7) }
        let v = s.split(separator: "-").first.map(String.init) ?? s
        let parts = v.split(separator: ".").compactMap { Int($0) }
        return parts.isEmpty ? nil : parts
    }

    /// Gruplar içinde en yeni `keep` öğeyi tutar; geri kalanları döner.
    static func olderThanNewest<T>(_ items: [T], keep: Int, group: (T) -> String, isNewer: (T, T) -> Bool) -> (old: [T], kept: [T]) {
        var byGroup: [String: [T]] = [:]
        var order: [String] = []
        for i in items {
            let g = group(i)
            if byGroup[g] == nil { order.append(g) }
            byGroup[g, default: []].append(i)
        }
        var old: [T] = [], kept: [T] = []
        for g in order {
            let sorted = byGroup[g]!.sorted(by: isNewer)
            kept += sorted.prefix(keep)
            old += sorted.dropFirst(keep)
        }
        return (old, kept)
    }

    static let lockfiles = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock", "npm-shrinkwrap.json"]

    /// Projenin "aktif" sayılıp sayılmadığı.
    static func isRecent(_ date: Date?, days: Int, now: Date) -> Bool {
        guard let d = date else { return false }
        return now.timeIntervalSince(d) < Double(days) * 86400
    }

    /// `brew cleanup -n` çıktısındaki "free approximately 1.2GB" → bayt.
    static func brewFreeBytes(_ output: String) -> Int64? {
        guard let r = output.range(of: "approximately ") else { return nil }
        let rest = output[r.upperBound...]
        let token = rest.split(separator: " ").first.map(String.init) ?? ""
        return parseSize(token)
    }

    /// "1.2GB", "512MB", "12.5kB", "3.4 GB", "0B" → bayt (ondalık birim).
    static func parseSize(_ raw: String) -> Int64? {
        let s = raw.replacingOccurrences(of: " ", with: "").uppercased()
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3), ("B", 1)]
        for (u, m) in units where s.hasSuffix(u) {
            guard let v = Double(s.dropLast(u.count)) else { return nil }
            return Int64(v * m)
        }
        return Double(s).map { Int64($0) }
    }

    /// `docker system df --format '{{.Type}}\t{{.Reclaimable}}'` → tür → bayt
    static func dockerReclaimable(_ output: String) -> [String: Int64] {
        var out: [String: Int64] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2 else { continue }
            let sizeToken = parts[1].split(separator: " ").first.map(String.init) ?? parts[1]
            if let b = parseSize(sizeToken) { out[parts[0]] = b }
        }
        return out
    }

    /// `pmset -g batt` → (yüzde, pilde mi). Pil yoksa nil.
    static func battery(_ output: String) -> (percent: Int, onBattery: Bool)? {
        guard output.contains("InternalBattery") || output.contains("%") else { return nil }
        let onBattery = output.contains("'Battery Power'")
        guard let pct = output.range(of: #"(\d{1,3})%"#, options: .regularExpression) else { return nil }
        let num = output[pct].dropLast()
        guard let p = Int(num) else { return nil }
        return (p, onBattery)
    }

    /// DerivedData/<Ad-hash>/info.plist → WorkspacePath
    static func workspacePath(infoPlist data: Data) -> String? {
        guard let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any] else { return nil }
        return dict["WorkspacePath"] as? String
    }

    /// Bir xcarchive Info.plist → (paket kimliği, oluşturma tarihi)
    static func archiveInfo(_ data: Data) -> (bundleID: String?, name: String?, date: Date?) {
        guard let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any] else { return (nil, nil, nil) }
        let app = dict["ApplicationProperties"] as? [String: Any]
        return (app?["CFBundleIdentifier"] as? String, dict["Name"] as? String, dict["CreationDate"] as? Date)
    }

    static func formatBytes(_ v: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var x = Double(v)
        var i = 0
        while x >= 1000 && i < units.count - 1 { x /= 1000; i += 1 }
        if i == 0 { return "\(v) B" }
        return String(format: x >= 100 ? "%.0f %@" : "%.1f %@", x, units[i])
    }

    static func ageText(_ date: Date?, now: Date = Date()) -> String {
        guard let d = date else { return "" }
        let days = Int(now.timeIntervalSince(d) / 86400)
        if days <= 0 { return L("bugün") }
        if days < 60 { return L("%@ gün", days) }
        if days < 730 { return L("%@ ay", days / 30) }
        return L("%@ yıl", days / 365)
    }
}

// MARK: - Otomatik mod kuralları

enum CleanerAutoPolicy {
    enum Trigger: String, Codable { case daily, lowSpace, manual, cli, url }

    static func nextDaily(after: Date, settings: CleanerSettings, calendar: Calendar = .current) -> Date? {
        guard settings.autoEnabled, settings.autoDaily else { return nil }
        let start = calendar.startOfDay(for: after)
        for off in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: off, to: start),
                  let fire = calendar.date(bySettingHour: settings.autoHour, minute: settings.autoMinute, second: 0, of: day) else { continue }
            if fire > after { return fire }
        }
        return nil
    }

    static let lowSpaceMinInterval: TimeInterval = 6 * 3600

    static func isLowSpace(free: Int64?, total: Int64?, settings: CleanerSettings) -> Bool {
        guard settings.autoLowSpace, let f = free, let t = total, t > 0 else { return false }
        if settings.autoLowSpaceGB > 0 && Double(f) < Double(settings.autoLowSpaceGB) * 1e9 { return true }
        if settings.autoLowSpacePercent > 0 && Double(f) / Double(t) * 100 < Double(settings.autoLowSpacePercent) { return true }
        return false
    }

    static func shouldRunLowSpace(free: Int64?, total: Int64?, settings: CleanerSettings, lastRun: Date?, now: Date) -> Bool {
        guard settings.autoEnabled, isLowSpace(free: free, total: total, settings: settings) else { return false }
        if let l = lastRun, now.timeIntervalSince(l) < lowSpaceMinInterval { return false }
        return true
    }

    /// Otomatik çalışmayı engelleyen durum (nil = çalışabilir).
    static func blocker(battery: (percent: Int, onBattery: Bool)?, cpuPercent: Double?, settings: CleanerSettings) -> String? {
        if let b = battery, b.onBattery, b.percent < settings.autoMinBatteryPercent { return L("pil %%@", b.percent) }
        if let c = cpuPercent, c > Double(settings.autoMaxCPUPercent) { return L("Mac meşgul (işlemci %%@)", Int(c)) }
        return nil
    }

    /// 1 dakikalık yük ortalamasından kabaca işlemci doluluğu (%).
    static func cpuBusyPercent() -> Double? {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) > 0 else { return nil }
        let n = Double(max(ProcessInfo.processInfo.activeProcessorCount, 1))
        return min(100, loads[0] / n * 100)
    }
}

// MARK: - Geçmiş

struct CleanRunRecord: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var category: CleanCategory
        var title: String
        var bytes: Int64
        var result: String   // "çöp", "silindi", "komut", "atlandı: …", "hata: …"
    }
    var date: Date
    var trigger: CleanerAutoPolicy.Trigger
    var reclaimed: Int64
    var trashed: Int64
    var entries: [Entry]
    var errors: Int
}

enum CleanHistory {
    static let maxRuns = 50

    /// Testler için.
    static var directoryOverride: URL?

    static var fileURL: URL {
        let dir = directoryOverride ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Workstation", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cleaner-history.json")
    }

    static func load(from url: URL = fileURL) -> [CleanRunRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([CleanRunRecord].self, from: data)) ?? []
    }

    static func append(_ r: CleanRunRecord, to url: URL = fileURL) {
        var list = load(from: url)
        list.append(r)
        if list.count > maxRuns { list.removeFirst(list.count - maxRuns) }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(list) { try? data.write(to: url, options: .atomic) }
    }

    static func totalReclaimed(_ list: [CleanRunRecord]) -> Int64 { list.reduce(0) { $0 + $1.reclaimed + $1.trashed } }
}

/// Aynı anda tek temizlik (uygulama + komut satırı): flock ile kilit dosyası.
final class CleanerLock {
    private var fd: Int32 = -1

    func acquire(path: String = CleanHistory.fileURL.deletingLastPathComponent().appendingPathComponent("cleaner.lock").path) -> Bool {
        fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return false }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); fd = -1; return false }
        return true
    }

    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}

/// İptal bayrağı (iş parçacığı güvenli).
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func cancel() { lock.lock(); flag = true; lock.unlock() }
}
