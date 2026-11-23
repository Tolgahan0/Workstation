import Foundation
#if canImport(Glibc)
import Glibc
#endif

// Geliştirici Temizleyici — tarama (yalnızca Foundation). Hiçbir şey silmez; yalnızca plan (ScanReport) üretir.

// MARK: - Disk kullanımı

enum DiskUsage {
    struct Result { var bytes: Int64; var files: Int; var newest: Date? }

    /// Klasörün diskte kapladığı alan (bağlantılar izlenmez). `filesOlderThan` verilirse yalnızca o tarihten eski dosyalar sayılır.
    static func measure(_ path: String, cancel: CancelToken? = nil, deadline: Date = .distantFuture, filesOlderThan: Date? = nil) -> Result {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        var r = Result(bytes: 0, files: 0, newest: nil)
        guard let rv = try? url.resourceValues(forKeys: Set(keys)) else { return r }
        if rv.isSymbolicLink == true { return r }
        if rv.isRegularFile == true {
            let m = rv.contentModificationDate
            if let cut = filesOlderThan, let mm = m, mm >= cut { return r }
            r.bytes = Int64(rv.totalFileAllocatedSize ?? rv.fileAllocatedSize ?? rv.fileSize ?? 0)
            r.files = 1
            r.newest = m
            return r
        }
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return r }
        var n = 0
        for case let f as URL in en {
            n += 1
            if n % 2000 == 0, cancel?.isCancelled == true || Date() > deadline { break }
            guard let v = try? f.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isSymbolicLink == true { continue }
            if let m = v.contentModificationDate, r.newest == nil || m > r.newest! { r.newest = m }
            guard v.isRegularFile == true else { continue }
            if let cut = filesOlderThan, let m = v.contentModificationDate, m >= cut { continue }
            r.bytes += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? v.fileSize ?? 0)
            r.files += 1
        }
        return r
    }

    /// Projenin en yeni değişiklik tarihi: hedef klasörler hariç, sığ ve sınırlı örnekleme.
    static func newestActivity(project: String, excluding: Set<String>, maxDepth: Int = 4, budget: Int = 4000) -> Date? {
        var newest: Date?
        func note(_ d: Date?) { if let d = d, newest == nil || d > newest! { newest = d } }
        let fm = FileManager.default
        // git: HEAD / index / logs (commit, checkout, add) güçlü bir sinyal.
        for g in [".git/index", ".git/HEAD", ".git/logs/HEAD", ".git/FETCH_HEAD"] {
            note((try? fm.attributesOfItem(atPath: project + "/" + g))?[.modificationDate] as? Date)
        }
        var queue: [(String, Int)] = [(project, 0)]
        var seen = 0
        var head = 0
        while head < queue.count && seen < budget {
            let (dir, depth) = queue[head]
            head += 1
            note((try? fm.attributesOfItem(atPath: dir))?[.modificationDate] as? Date)
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names {
                seen += 1
                if seen >= budget { break }
                if excluding.contains(name) || name == ".git" || name == ".DS_Store" { continue }
                let p = dir + "/" + name
                guard let attrs = try? fm.attributesOfItem(atPath: p) else { continue }
                if (attrs[.type] as? FileAttributeType) == .typeSymbolicLink { continue }
                note(attrs[.modificationDate] as? Date)
                if (attrs[.type] as? FileAttributeType) == .typeDirectory && depth + 1 < maxDepth {
                    queue.append((p, depth + 1))
                }
            }
        }
        return newest
    }
}

// MARK: - Araç bulucu (GUI uygulamalarında PATH kısıtlıdır)

struct ToolLocator {
    let home: String
    var searchDirs: [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin",
         home + "/.bun/bin", home + "/.cargo/bin", home + "/Library/pnpm", home + "/.local/share/pnpm",
         home + "/.local/bin", home + "/.volta/bin", "/usr/local/go/bin", "/opt/homebrew/opt/go/bin",
         "/Applications/Docker.app/Contents/Resources/bin", home + "/.docker/bin"]
            + nvmBins()
    }

    private func nvmBins() -> [String] {
        let base = home + "/.nvm/versions/node"
        guard let vs = try? FileManager.default.contentsOfDirectory(atPath: base) else { return [] }
        return vs.sorted().reversed().map { base + "/" + $0 + "/bin" }
    }

    func find(_ name: String) -> String? {
        for d in searchDirs {
            let p = d + "/" + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchDirs.joined(separator: ":")
        env["HOME"] = home
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["NO_COLOR"] = "1"
        return env
    }

    func run(_ tool: String, _ args: [String], timeout: TimeInterval = 30, cwd: String? = nil) -> CommandResult? {
        guard let path = find(tool) else { return nil }
        return Shell.run(path, args, timeout: timeout, environment: environment, currentDirectory: cwd)
    }
}

// MARK: - Projeler

struct DevProject {
    var root: String
    var hasPackageJSON = false
    var androidRoot: String?
    var podRoots: [String] = []
    var hasCargo = false
}

/// Ev klasöründe (ve ek köklerde) geliştirme projelerini bulur.
struct ProjectFinder {
    let home: String
    let roots: [String]
    let maxDepth: Int
    let deadline: Date
    let cancel: CancelToken?
    var maxDirs = 150_000

    static let skipNames: Set<String> = [
        "node_modules", ".git", "Pods", "build", ".gradle", "DerivedData", ".next", ".turbo", ".expo", "target", "dist",
        ".build", "venv", ".venv", "__pycache__", ".Trash", "Library", "Applications", ".cxx", ".svelte-kit", ".nuxt",
        "Photos Library.photoslibrary", "Music", "Movies", "Pictures", ".cache", ".npm", ".cargo", ".rustup", ".gradle",
        ".android", ".cocoapods", "go", ".pnpm-store", "bower_components", "vendor",
    ]
    static let skipExtensions: Set<String> = ["app", "photoslibrary", "xcarchive", "framework", "bundle", "musiclibrary",
                                             "tvlibrary", "photolibrary", "xcassets", "lproj", "imageset", "dSYM", "sparsebundle", "dmg"]

    func find() -> [DevProject] {
        let fm = FileManager.default
        var out: [String: DevProject] = [:]
        var visited = 0
        let homeDev = deviceID(home)
        var queue: [(String, Int)] = roots.map { ($0, 0) }
        var seenRoots = Set<String>()
        var head = 0
        while head < queue.count {
            let (dir, depth) = queue[head]
            head += 1
            guard seenRoots.insert(dir).inserted else { continue }
            visited += 1
            if visited > maxDirs || Date() > deadline || cancel?.isCancelled == true { break }
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            let set = Set(names)
            var proj = DevProject(root: dir)
            var isProject = false
            if set.contains("package.json") { proj.hasPackageJSON = true; isProject = true }
            if set.contains("Cargo.toml") { proj.hasCargo = true; isProject = true }
            if set.contains("Podfile") { proj.podRoots.append(dir); isProject = true }
            if set.contains("android"), isDir(dir + "/android/app") { proj.androidRoot = dir + "/android"; isProject = true }
            else if (set.contains("settings.gradle") || set.contains("settings.gradle.kts")) { proj.androidRoot = dir; isProject = true }
            if set.contains("ios"), fm.fileExists(atPath: dir + "/ios/Podfile") { proj.podRoots.append(dir + "/ios"); isProject = true }
            if isProject {
                // Üst klasör zaten aynı rolde bir projeyse (ör. android/ iç klasörü) yeni proje olarak sayma.
                if let a = proj.androidRoot, out.values.contains(where: { $0.androidRoot == a }) { proj.androidRoot = nil }
                out[dir] = proj
            }
            guard depth < maxDepth else { continue }
            for name in names {
                if name.hasPrefix(".") || Self.skipNames.contains(name) { continue }
                let ext = (name as NSString).pathExtension
                if !ext.isEmpty && Self.skipExtensions.contains(ext) { continue }
                let p = dir + "/" + name
                guard isDir(p, noFollow: true) else { continue }
                if let hd = homeDev, let d = deviceID(p), d != hd { continue } // başka disk/birim
                queue.append((p, depth + 1))
            }
        }
        return out.values.sorted { $0.root < $1.root }
    }

    private func isDir(_ p: String, noFollow: Bool = false) -> Bool {
        var st = stat()
        let rc = noFollow ? lstat(p, &st) : stat(p, &st)
        guard rc == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    private func deviceID(_ p: String) -> UInt64? {
        var st = stat()
        guard lstat(p, &st) == 0 else { return nil }
        return UInt64(st.st_dev)
    }
}

// MARK: - Git denetimi

enum GitGuard {
    /// Yukarı doğru .git arar.
    static func repoRoot(for path: String, stopAt home: String) -> String? {
        var cur = PathGuard.normalize(path)
        let fm = FileManager.default
        while cur.count > 1 {
            if fm.fileExists(atPath: cur + "/.git") { return cur }
            if cur == PathGuard.normalize(home) { break }
            cur = (cur as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// nil = güvenli. Hedef altında git'te kayıtlı dosya varsa .gitTracked; `requireIgnored` ise yok sayılmalı.
    static func check(target: String, home: String, requireIgnored: Bool) -> SkipReason? {
        guard let repo = repoRoot(for: target, stopAt: home) else { return requireIgnored ? .notIgnored : nil }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { return .unverified }
        let rel = String(PathGuard.normalize(target).dropFirst(PathGuard.normalize(repo).count + 1))
        if rel.isEmpty { return .gitTracked }
        let ls = Shell.run("/usr/bin/git", ["-C", repo, "ls-files", "--", rel], timeout: 15)
        guard ls.succeeded else { return .unverified }
        if !ls.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .gitTracked }
        if requireIgnored {
            let ci = Shell.run("/usr/bin/git", ["-C", repo, "check-ignore", "-q", rel], timeout: 10)
            if ci.status != 0 { return .notIgnored }
        }
        return nil
    }
}

// MARK: - Sistem anlık görüntüsü

struct SystemSnapshot {
    var openFiles: OpenFileIndex
    var processes: ProcessList

    static func capture(home: String) -> SystemSnapshot {
        let uid = String(getuid())
        var index = OpenFileIndex.unavailable
        for lsof in ["/usr/sbin/lsof", "/usr/bin/lsof", "/bin/lsof"] where FileManager.default.isExecutableFile(atPath: lsof) {
            let r = Shell.run(lsof, ["-w", "-n", "-P", "-F", "pfn", "-u", uid], timeout: 45)
            // lsof, bazı dosyalara erişemeyince 1 döner ama çıktı yine geçerlidir.
            if !r.timedOut && !r.stdout.isEmpty {
                index = OpenFileIndex.parse(lsofOutput: r.stdout, keepUnder: [home])
            }
            break
        }
        let ps = Shell.run("/bin/ps", ["-axww", "-o", "pid=,args="], timeout: 10)
        return SystemSnapshot(openFiles: index, processes: ProcessList.parse(ps.stdout))
    }
}

// MARK: - Tarayıcı

final class CleanerScanner {
    let settings: CleanerSettings
    let home: String
    let cancel: CancelToken
    let now: Date
    let deadline: Date
    let tools: ToolLocator
    var snapshot: SystemSnapshot
    /// (aşama metni, 0…1)
    var progress: (String, Double) -> Void = { _, _ in }
    /// Testler: araç komutlarını (brew, docker, xcrun…) çalıştırma.
    var runTools = true
    /// Testler: tarama kökleri.
    var rootsOverride: [String]?

    private var projects: [DevProject] = []
    private var activityCache: [String: Date?] = [:]

    init(settings: CleanerSettings, home: String = FileManager.default.homeDirectoryForCurrentUser.path,
         cancel: CancelToken = CancelToken(), now: Date = Date(), timeLimit: TimeInterval = 240,
         snapshot: SystemSnapshot? = nil) {
        self.settings = settings
        self.home = PathGuard.normalize(home)
        self.cancel = cancel
        self.now = now
        self.deadline = now.addingTimeInterval(timeLimit)
        self.tools = ToolLocator(home: PathGuard.normalize(home))
        self.snapshot = snapshot ?? SystemSnapshot(openFiles: .unavailable, processes: ProcessList(procs: []))
        if snapshot == nil { self.snapshot = SystemSnapshot.capture(home: self.home) }
    }

    static let projectCategories: Set<CleanCategory> = [.androidBuilds, .gradleWrapperDists, .gradleVersionCaches, .nodeModules,
                                                        .jsBuildOutputs, .podsDirs, .rustTargets]

    var projectRoots: [String] {
        if let r = rootsOverride { return r }
        var roots = [home]
        for r in settings.extraRoots {
            let p = PathGuard.normalize(PathGuard.expandTilde(r, home: home))
            if !p.isEmpty && !roots.contains(p) { roots.append(p) }
        }
        return roots
    }

    func scan(_ categories: [CleanCategory]) -> ScanReport {
        let start = Date()
        var results: [CategoryResult] = []
        if categories.contains(where: { Self.projectCategories.contains($0) }) {
            progress("Projeler aranıyor…", 0.02)
            projects = ProjectFinder(home: home, roots: projectRoots, maxDepth: settings.maxDepth,
                                     deadline: deadline, cancel: cancel).find()
            Log.info("Temizleyici: \(projects.count) proje bulundu")
        }
        for (i, c) in categories.enumerated() {
            if cancel.isCancelled || Date() > deadline { break }
            progress(c.title, 0.05 + 0.95 * Double(i) / Double(max(categories.count, 1)))
            var r = scanCategory(c)
            r.items = r.items.map { item in
                var it = item
                it.selected = it.isActionable
                return it
            }
            results.append(r)
        }
        progress("Bitti", 1)
        return ScanReport(date: now, results: results, duration: Date().timeIntervalSince(start),
                          inUseCheckOK: snapshot.openFiles.reliable, cancelled: cancel.isCancelled)
    }

    // MARK: Ortak denetimler

    private func activity(_ project: String) -> Date? {
        if let c = activityCache[project] { return c }
        let d = DiskUsage.newestActivity(project: project, excluding: Self.artifactNames)
        activityCache[project] = d
        return d
    }

    static let artifactNames: Set<String> = ["node_modules", "build", ".gradle", "Pods", ".next", "dist", "target", ".turbo",
                                             ".expo", ".cxx", "DerivedData", ".parcel-cache", ".svelte-kit", ".nuxt", ".angular", ".build"]

    /// Proje düzeyindeki bir hedef için tüm güvenlik denetimleri. nil = silinebilir.
    func projectSkip(target: String, project: String, days: Int, requireIgnored: Bool = false) -> SkipReason? {
        if let r = PathGuard.check(target, home: home, neverTouch: settings.neverTouch) { return r }
        if CleanerRules.isRecent(activity(project), days: days, now: now) { return .activeProject }
        if !snapshot.openFiles.reliable { return .unverified }
        if snapshot.openFiles.hasProcessCwd(under: project) != nil { return .runningProcess }
        if snapshot.openFiles.hasOpenFile(under: target) != nil { return .openFiles }
        if let g = GitGuard.check(target: target, home: home, requireIgnored: requireIgnored) { return g }
        return nil
    }

    /// Genel önbellek öğeleri için denetim.
    func cacheSkip(_ target: String) -> SkipReason? {
        if let r = PathGuard.check(target, home: home, neverTouch: settings.neverTouch) { return r }
        if !snapshot.openFiles.reliable { return .unverified }
        if snapshot.openFiles.hasOpenFile(under: target) != nil { return .openFiles }
        if snapshot.openFiles.hasProcessCwd(under: target) != nil { return .runningProcess }
        return nil
    }

    private func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }

    private func children(_ dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0 != ".DS_Store" }.sorted().map { dir + "/" + $0 }
    }

    private func mtime(_ p: String) -> Date? { (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date }

    private func measured(_ item: CleanItem) -> CleanItem {
        guard item.isActionable, let p = item.path else { return item }
        var it = item
        if case .pruneFiles(let days) = item.action {
            let m = DiskUsage.measure(p, cancel: cancel, deadline: deadline, filesOlderThan: now.addingTimeInterval(-Double(days) * 86400))
            it.bytes = m.bytes
            it.detail = "\(m.files) dosya"
            return it
        }
        if case .command = item.action { return it }
        let m = DiskUsage.measure(p, cancel: cancel, deadline: deadline)
        it.bytes = m.bytes
        if it.modified == nil { it.modified = m.newest }
        return it
    }

    private func item(_ c: CleanCategory, _ path: String, title: String? = nil, detail: String = "", skip: SkipReason? = nil,
                      project: String? = nil, inactive: Int? = nil, action: CleanAction = .delete, modified: Date? = nil) -> CleanItem {
        var it = CleanItem(id: c.rawValue + ":" + path, category: c, path: path,
                           title: title ?? PathGuard.display(path, home: home), detail: detail,
                           modified: modified, skip: skip, action: action, projectRoot: project, inactiveDays: inactive)
        it = measured(it)
        return it
    }

    // MARK: Kategoriler

    func scanCategory(_ c: CleanCategory) -> CategoryResult {
        switch c {
        case .derivedData: return derivedData()
        case .xcodeArchives: return archives()
        case .deviceSupport: return deviceSupport()
        case .unavailableSimulators: return unavailableSimulators()
        case .simulatorCaches: return simpleCacheChildren(c, home + "/Library/Developer/CoreSimulator/Caches", busy: snapshot.processes.simulatorRunning)
        case .simulatorRuntimes: return simulatorRuntimes()
        case .androidBuilds: return androidBuilds()
        case .gradleWrapperDists: return gradleWrapperDists()
        case .gradleVersionCaches: return gradleVersionCaches()
        case .gradleModuleCache: return wholeDir(c, home + "/.gradle/caches/modules-2", busy: snapshot.processes.gradleRunning)
        case .avdSnapshots: return avdSnapshots()
        case .androidSDK: return androidSDK()
        case .nodeModules: return nodeModules()
        case .npmCache: return npmCache()
        case .pnpmStore: return pnpmStore()
        case .yarnCache: return toolCache(c, tool: "yarn", dirArgs: ["cache", "dir"], cleanArgs: ["cache", "clean"], full: true)
        case .bunCache: return bunCache()
        case .jsBuildOutputs: return jsBuildOutputs()
        case .playwrightBrowsers: return playwright()
        case .cocoapodsCache: return cocoapodsCache()
        case .podsDirs: return podsDirs()
        case .homebrew: return homebrew()
        case .homebrewAutoremove: return homebrewAutoremove()
        case .dockerDangling, .dockerVolumes: return docker(c)
        case .pipCache: return pruneDirs(c, [home + "/Library/Caches/pip", home + "/.cache/pip"])
        case .uvCache: return uvCache()
        case .cargoCache: return pruneDirs(c, [home + "/.cargo/registry/cache"], busy: snapshot.processes.any { $0.contains("cargo ") })
        case .rustTargets: return rustTargets()
        case .goBuildCache: return goCache()
        case .editorServers: return editorServers()
        case .agentLogs: return agentLogs()
        case .trash: return trash()
        case .appCaches: return appCaches()
        }
    }

    private func derivedData() -> CategoryResult {
        var r = CategoryResult(category: .derivedData)
        let dir = home + "/Library/Developer/Xcode/DerivedData"
        let days = settings.age(.derivedData) ?? 7
        let xcode = snapshot.processes.xcodeRunning
        for p in children(dir) {
            if cancel.isCancelled { break }
            let name = (p as NSString).lastPathComponent
            if name == "ModuleCache.noindex" || name == "SymbolCache.noindex" || name == "CompilationCache.noindex" {
                if xcode { r.items.append(item(.derivedData, p, detail: "paylaşılan önbellek", skip: .toolRunning)); continue }
                let recent = CleanerRules.isRecent(mtime(p), days: days, now: now)
                r.items.append(item(.derivedData, p, detail: "paylaşılan önbellek", skip: recent ? .recent : cacheSkip(p)))
                continue
            }
            let ws = (try? Data(contentsOf: URL(fileURLWithPath: p + "/info.plist"))).flatMap(CleanerRules.workspacePath)
            var detail = ws.map { PathGuard.display($0, home: home) } ?? "proje bilinmiyor"
            var skip: SkipReason? = cacheSkip(p)
            let lastBuild = mtime(p + "/info.plist") ?? mtime(p)
            if skip == nil, CleanerRules.isRecent(lastBuild, days: days, now: now) { skip = .recent }
            if let w = ws {
                if exists(w) {
                    let projectDir = (w as NSString).deletingLastPathComponent
                    if skip == nil, CleanerRules.isRecent(activity(projectDir), days: days, now: now) { skip = .activeProject }
                    if skip == nil, snapshot.openFiles.hasProcessCwd(under: projectDir) != nil { skip = .runningProcess }
                } else {
                    detail += " (proje artık yok)"
                }
            }
            r.items.append(item(.derivedData, p, title: name.components(separatedBy: "-").dropLast().joined(separator: "-").nilIfEmpty ?? name,
                                detail: detail, skip: skip, modified: lastBuild))
        }
        return r
    }

    private func archives() -> CategoryResult {
        var r = CategoryResult(category: .xcodeArchives)
        let base = home + "/Library/Developer/Xcode/Archives"
        struct A { let path: String; let key: String; let name: String; let date: Date }
        var list: [A] = []
        for day in children(base) {
            for a in children(day) where a.hasSuffix(".xcarchive") {
                let info = (try? Data(contentsOf: URL(fileURLWithPath: a + "/Info.plist"))).map(CleanerRules.archiveInfo)
                let name = info?.name ?? ((a as NSString).lastPathComponent as NSString).deletingPathExtension
                list.append(A(path: a, key: info?.bundleID ?? name, name: name, date: info?.date ?? mtime(a) ?? .distantPast))
            }
        }
        let split = CleanerRules.olderThanNewest(list, keep: 2, group: { $0.key }, isNewer: { $0.date > $1.date })
        for a in split.kept { r.items.append(CleanItem(id: "xcodeArchives:" + a.path, category: .xcodeArchives, path: a.path, title: a.name, detail: a.key, modified: a.date, skip: .keptNewest)) }
        for a in split.old { r.items.append(item(.xcodeArchives, a.path, title: a.name, detail: a.key, skip: cacheSkip(a.path), modified: a.date)) }
        return r
    }

    private func deviceSupport() -> CategoryResult {
        var r = CategoryResult(category: .deviceSupport)
        let days = settings.age(.deviceSupport) ?? 90
        for platform in ["iOS", "watchOS", "tvOS", "visionOS"] {
            let base = home + "/Library/Developer/Xcode/\(platform) DeviceSupport"
            let dirs = children(base).filter { CleanerRules.version(in: ($0 as NSString).lastPathComponent) != nil }
            let split = CleanerRules.olderThanNewest(dirs, keep: 2, group: { _ in platform }, isNewer: {
                CleanerRules.compareVersions(CleanerRules.version(in: ($1 as NSString).lastPathComponent)!,
                                             CleanerRules.version(in: ($0 as NSString).lastPathComponent)!)
            })
            for d in split.kept { r.items.append(CleanItem(id: "deviceSupport:" + d, category: .deviceSupport, path: d, title: "\(platform) " + (d as NSString).lastPathComponent, skip: .keptNewest)) }
            for d in split.old {
                var skip = cacheSkip(d)
                if skip == nil, CleanerRules.isRecent(mtime(d), days: days, now: now) { skip = .recent }
                r.items.append(item(.deviceSupport, d, title: "\(platform) " + (d as NSString).lastPathComponent, skip: skip, modified: mtime(d)))
            }
        }
        return r
    }

    private func unavailableSimulators() -> CategoryResult {
        var r = CategoryResult(category: .unavailableSimulators)
        guard runTools, FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else { return r }
        let res = Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "unavailable", "-j"], timeout: 30)
        guard res.succeeded, let data = res.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: Any] else {
            r.note = "Xcode simülatör aracı bulunamadı"
            return r
        }
        var bytes: Int64 = 0
        var count = 0
        for (_, v) in devices {
            for d in (v as? [[String: Any]]) ?? [] {
                guard let udid = d["udid"] as? String else { continue }
                count += 1
                bytes += DiskUsage.measure(home + "/Library/Developer/CoreSimulator/Devices/" + udid, cancel: cancel, deadline: deadline).bytes
            }
        }
        guard count > 0 else { return r }
        r.items.append(CleanItem(id: "unavailableSimulators", category: .unavailableSimulators, path: nil,
                                 title: "\(count) kullanılamayan simülatör", detail: "Xcode'un kendi komutuyla", bytes: bytes,
                                 action: .command("/usr/bin/xcrun", ["simctl", "delete", "unavailable"])))
        return r
    }

    private func simulatorRuntimes() -> CategoryResult {
        var r = CategoryResult(category: .simulatorRuntimes)
        guard runTools, FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else { return r }
        let res = Shell.run("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"], timeout: 30)
        guard res.succeeded, let data = res.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return r }
        for (id, v) in json {
            guard let d = v as? [String: Any] else { continue }
            let ver = d["version"] as? String ?? ""
            let plat = (d["platformIdentifier"] as? String)?.components(separatedBy: ".").last ?? ""
            let size = (d["sizeBytes"] as? NSNumber)?.int64Value ?? 0
            r.items.append(CleanItem(id: "simulatorRuntimes:" + id, category: .simulatorRuntimes, path: nil,
                                     title: "\(plat) \(ver)".trimmingCharacters(in: .whitespaces), detail: "Xcode › Ayarlar › Platformlar'dan kaldırılabilir",
                                     bytes: size, action: .suggest))
        }
        r.items.sort { $0.bytes > $1.bytes }
        return r
    }

    private func androidBuilds() -> CategoryResult {
        var r = CategoryResult(category: .androidBuilds)
        let days = settings.age(.androidBuilds) ?? 7
        for p in projects {
            guard let a = p.androidRoot else { continue }
            for t in [a + "/app/build", a + "/build", a + "/.gradle", a + "/app/.cxx"] where exists(t) {
                let skip = projectSkip(target: t, project: p.root, days: days)
                r.items.append(item(.androidBuilds, t, detail: (p.root as NSString).lastPathComponent, skip: skip, project: p.root, inactive: days))
            }
        }
        return r
    }

    private var referencedGradleDists: Set<String> {
        var set = Set<String>()
        for p in projects {
            guard let a = p.androidRoot,
                  let text = try? String(contentsOfFile: a + "/gradle/wrapper/gradle-wrapper.properties", encoding: .utf8),
                  let d = CleanerRules.gradleWrapperDist(fromProperties: text) else { continue }
            set.insert(d)
        }
        return set
    }

    private func gradleWrapperDists() -> CategoryResult {
        var r = CategoryResult(category: .gradleWrapperDists)
        let dists = children(home + "/.gradle/wrapper/dists")
        let referenced = referencedGradleDists
        let newest = dists.max { CleanerRules.compareVersions(CleanerRules.gradleVersion(($0 as NSString).lastPathComponent) ?? [], CleanerRules.gradleVersion(($1 as NSString).lastPathComponent) ?? []) }
        for d in dists {
            let name = (d as NSString).lastPathComponent
            var skip: SkipReason?
            if referenced.contains(name) { skip = .referenced }
            else if d == newest { skip = .keptNewest }
            else if snapshot.processes.gradleRunning { skip = .toolRunning }
            else { skip = cacheSkip(d) }
            if skip == .referenced || skip == .keptNewest {
                r.items.append(CleanItem(id: "gradleWrapperDists:" + d, category: .gradleWrapperDists, path: d, title: name, skip: skip))
            } else {
                r.items.append(item(.gradleWrapperDists, d, title: name, skip: skip))
            }
        }
        if projects.isEmpty && !dists.isEmpty { r.note = "Hiç Android projesi bulunamadı; güvenlik için en yeni sürüm tutulur." }
        return r
    }

    private func gradleVersionCaches() -> CategoryResult {
        var r = CategoryResult(category: .gradleVersionCaches)
        let refVersions = Set(referencedGradleDists.compactMap { CleanerRules.gradleVersion($0) }.map { $0.map(String.init).joined(separator: ".") })
        let days = settings.age(.gradleVersionCaches) ?? 60
        for base in [home + "/.gradle/caches", home + "/.gradle/daemon"] {
            let dirs = children(base).filter { d in
                let n = (d as NSString).lastPathComponent
                return n.first?.isNumber == true && CleanerRules.gradleVersion(n) != nil
            }
            let newest = dirs.max { CleanerRules.compareVersions(CleanerRules.gradleVersion(($0 as NSString).lastPathComponent)!, CleanerRules.gradleVersion(($1 as NSString).lastPathComponent)!) }
            for d in dirs {
                let n = (d as NSString).lastPathComponent
                let title = (base.hasSuffix("daemon") ? "daemon " : "caches ") + n
                var skip: SkipReason?
                if refVersions.contains(n) { skip = .referenced }
                else if d == newest { skip = .keptNewest }
                else if snapshot.processes.gradleRunning { skip = .toolRunning }
                else if CleanerRules.isRecent(mtime(d), days: days, now: now) { skip = .recent }
                else { skip = cacheSkip(d) }
                if skip == .referenced || skip == .keptNewest {
                    r.items.append(CleanItem(id: "gradleVersionCaches:" + d, category: .gradleVersionCaches, path: d, title: title, skip: skip))
                } else {
                    r.items.append(item(.gradleVersionCaches, d, title: title, skip: skip))
                }
            }
        }
        return r
    }

    private func avdSnapshots() -> CategoryResult {
        var r = CategoryResult(category: .avdSnapshots)
        let days = settings.age(.avdSnapshots) ?? 30
        for avd in children(home + "/.android/avd") where avd.hasSuffix(".avd") {
            let s = avd + "/snapshots"
            guard exists(s) else { continue }
            var skip: SkipReason? = snapshot.processes.emulatorRunning ? .toolRunning : cacheSkip(s)
            if skip == nil, CleanerRules.isRecent(mtime(s), days: days, now: now) { skip = .recent }
            r.items.append(item(.avdSnapshots, s, title: ((avd as NSString).lastPathComponent as NSString).deletingPathExtension, skip: skip))
        }
        return r
    }

    private func androidSDK() -> CategoryResult {
        var r = CategoryResult(category: .androidSDK)
        let env = ProcessInfo.processInfo.environment
        let sdk = env["ANDROID_HOME"] ?? env["ANDROID_SDK_ROOT"] ?? home + "/Library/Android/sdk"
        func suggestOld(_ dir: String, keep: Int, label: String) {
            let vs = children(dir).filter { CleanerRules.version(in: ($0 as NSString).lastPathComponent.replacingOccurrences(of: "android-", with: "")) != nil }
            let split = CleanerRules.olderThanNewest(vs, keep: keep, group: { _ in "" }, isNewer: {
                CleanerRules.compareVersions(CleanerRules.version(in: ($1 as NSString).lastPathComponent.replacingOccurrences(of: "android-", with: ""))!,
                                             CleanerRules.version(in: ($0 as NSString).lastPathComponent.replacingOccurrences(of: "android-", with: ""))!)
            })
            for d in split.old {
                var it = CleanItem(id: "androidSDK:" + d, category: .androidSDK, path: d, title: "\(label) \((d as NSString).lastPathComponent)",
                                   detail: "Android Studio › SDK Manager'dan kaldırılabilir", action: .suggest)
                it.bytes = DiskUsage.measure(d, cancel: cancel, deadline: deadline).bytes
                r.items.append(it)
            }
        }
        suggestOld(sdk + "/build-tools", keep: 2, label: "build-tools")
        suggestOld(sdk + "/platforms", keep: 3, label: "platform")
        suggestOld(sdk + "/ndk", keep: 1, label: "NDK")
        return r
    }

    private func hasLockfile(_ dir: String) -> Bool {
        var cur = dir
        for _ in 0..<4 {
            if CleanerRules.lockfiles.contains(where: { exists(cur + "/" + $0) }) { return true }
            if exists(cur + "/.git") || cur == home { break }
            cur = (cur as NSString).deletingLastPathComponent
        }
        return false
    }

    private func nodeModules() -> CategoryResult {
        var r = CategoryResult(category: .nodeModules)
        let days = settings.age(.nodeModules) ?? 14
        let pmBusy = snapshot.processes.packageManagerRunning
        for p in projects where p.hasPackageJSON {
            let t = p.root + "/node_modules"
            guard exists(t) else { continue }
            var skip: SkipReason? = pmBusy ? .toolRunning : nil
            if skip == nil, !hasLockfile(p.root) { skip = .noLockfile }
            if skip == nil { skip = projectSkip(target: t, project: p.root, days: days) }
            r.items.append(item(.nodeModules, t, detail: (p.root as NSString).lastPathComponent, skip: skip, project: p.root, inactive: days))
        }
        return r
    }

    private func npmCache() -> CategoryResult {
        var r = CategoryResult(category: .npmCache)
        let days = settings.age(.npmCache) ?? 30
        let cacache = home + "/.npm/_cacache"
        if exists(cacache), tools.find("npm") != nil {
            let size = DiskUsage.measure(cacache, cancel: cancel, deadline: deadline).bytes
            r.items.append(CleanItem(id: "npmCache:verify", category: .npmCache, path: cacache, title: "npm önbelleğini ayıkla",
                                     detail: "önbellek \(CleanerRules.formatBytes(size)) · npm kendisi temizler",
                                     action: .command(tools.find("npm")!, ["cache", "verify"])))
        }
        for d in children(home + "/.npm/_npx") {
            var skip = cacheSkip(d)
            let m = DiskUsage.measure(d, cancel: cancel, deadline: deadline)
            if skip == nil, CleanerRules.isRecent(m.newest ?? mtime(d), days: days, now: now) { skip = .recent }
            var it = CleanItem(id: "npmCache:" + d, category: .npmCache, path: d, title: "npx: " + npxName(d), detail: PathGuard.display(d, home: home),
                               modified: m.newest, skip: skip)
            it.bytes = skip == nil ? m.bytes : 0
            r.items.append(it)
        }
        return r
    }

    private func npxName(_ dir: String) -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: dir + "/package.json")),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deps = j["dependencies"] as? [String: Any], let first = deps.keys.sorted().first else {
            return (dir as NSString).lastPathComponent
        }
        return first
    }

    private func pnpmStore() -> CategoryResult {
        var r = CategoryResult(category: .pnpmStore)
        guard runTools, let pnpm = tools.find("pnpm") else { return r }
        let res = tools.run("pnpm", ["store", "path"], timeout: 20)
        let path = res?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, exists(path) else { return r }
        let size = DiskUsage.measure(path, cancel: cancel, deadline: deadline).bytes
        let skip: SkipReason? = snapshot.processes.packageManagerRunning ? .toolRunning : nil
        r.items.append(CleanItem(id: "pnpmStore", category: .pnpmStore, path: path, title: "pnpm store prune",
                                 detail: "depo \(CleanerRules.formatBytes(size)) · kullanılmayan paketler silinir",
                                 skip: skip, action: .command(pnpm, ["store", "prune"])))
        return r
    }

    private func toolCache(_ c: CleanCategory, tool: String, dirArgs: [String], cleanArgs: [String], full: Bool) -> CategoryResult {
        var r = CategoryResult(category: c)
        guard runTools, let exe = tools.find(tool), let res = tools.run(tool, dirArgs, timeout: 20) else { return r }
        let path = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? ""
        guard !path.isEmpty, exists(path) else { return r }
        let size = DiskUsage.measure(path, cancel: cancel, deadline: deadline).bytes
        guard size > 0 else { return r }
        let skip: SkipReason? = snapshot.processes.packageManagerRunning ? .toolRunning : nil
        r.items.append(CleanItem(id: c.rawValue, category: c, path: path, title: "\(tool) \(cleanArgs.joined(separator: " "))",
                                 detail: PathGuard.display(path, home: home), bytes: full ? size : 0, skip: skip, action: .command(exe, cleanArgs)))
        return r
    }

    private func bunCache() -> CategoryResult {
        var r = CategoryResult(category: .bunCache)
        let path = home + "/.bun/install/cache"
        guard exists(path), let bun = tools.find("bun") else { return r }
        let size = DiskUsage.measure(path, cancel: cancel, deadline: deadline).bytes
        r.items.append(CleanItem(id: "bunCache", category: .bunCache, path: path, title: "bun pm cache rm", detail: PathGuard.display(path, home: home),
                                 bytes: size, skip: snapshot.processes.packageManagerRunning ? .toolRunning : nil, action: .command(bun, ["pm", "cache", "rm"])))
        return r
    }

    static let jsOutputs = [".next", ".turbo", ".expo", ".parcel-cache", ".svelte-kit", ".nuxt", ".angular/cache", "dist"]

    private func jsBuildOutputs() -> CategoryResult {
        var r = CategoryResult(category: .jsBuildOutputs)
        let days = settings.age(.jsBuildOutputs) ?? 7
        for p in projects where p.hasPackageJSON {
            for name in Self.jsOutputs {
                let t = p.root + "/" + name
                guard exists(t) else { continue }
                let skip = projectSkip(target: t, project: p.root, days: days, requireIgnored: name == "dist")
                r.items.append(item(.jsBuildOutputs, t, detail: (p.root as NSString).lastPathComponent, skip: skip, project: p.root, inactive: days))
            }
        }
        return r
    }

    private func playwright() -> CategoryResult {
        var r = CategoryResult(category: .playwrightBrowsers)
        for base in [home + "/Library/Caches/ms-playwright", home + "/.cache/ms-playwright"] {
            let dirs = children(base).filter { ($0 as NSString).lastPathComponent.contains("-") && !($0 as NSString).lastPathComponent.hasPrefix(".") }
            func kind(_ d: String) -> String { ((d as NSString).lastPathComponent).components(separatedBy: "-").dropLast().joined(separator: "-") }
            func rev(_ d: String) -> Int { Int(((d as NSString).lastPathComponent).components(separatedBy: "-").last ?? "") ?? 0 }
            let split = CleanerRules.olderThanNewest(dirs, keep: 1, group: kind, isNewer: { rev($0) > rev($1) })
            for d in split.kept { r.items.append(CleanItem(id: "pw:" + d, category: .playwrightBrowsers, path: d, title: (d as NSString).lastPathComponent, skip: .keptNewest)) }
            for d in split.old { r.items.append(item(.playwrightBrowsers, d, title: (d as NSString).lastPathComponent, skip: cacheSkip(d))) }
        }
        // Puppeteer: ~/.cache/puppeteer/<tarayıcı>/<platform-sürüm>
        for browser in children(home + "/.cache/puppeteer") {
            let vs = children(browser)
            let split = CleanerRules.olderThanNewest(vs, keep: 1, group: { _ in "" }, isNewer: { (self.mtime($0) ?? .distantPast) > (self.mtime($1) ?? .distantPast) })
            for d in split.old { r.items.append(item(.playwrightBrowsers, d, title: "puppeteer " + (d as NSString).lastPathComponent, skip: cacheSkip(d))) }
        }
        return r
    }

    private func cocoapodsCache() -> CategoryResult {
        var r = CategoryResult(category: .cocoapodsCache)
        let path = home + "/Library/Caches/CocoaPods"
        guard exists(path) else { return r }
        let size = DiskUsage.measure(path, cancel: cancel, deadline: deadline).bytes
        let busy = snapshot.processes.any { $0.contains("pod install") || $0.contains("pod update") }
        if let pod = tools.find("pod") {
            r.items.append(CleanItem(id: "cocoapodsCache", category: .cocoapodsCache, path: path, title: "pod cache clean --all",
                                     detail: PathGuard.display(path, home: home), bytes: size, skip: busy ? .toolRunning : nil,
                                     action: .command(pod, ["cache", "clean", "--all"])))
        } else {
            r.items.append(item(.cocoapodsCache, path, skip: busy ? .toolRunning : cacheSkip(path)))
        }
        return r
    }

    private func podsDirs() -> CategoryResult {
        var r = CategoryResult(category: .podsDirs)
        let days = settings.age(.podsDirs) ?? 7
        for p in projects {
            for pr in p.podRoots {
                let t = pr + "/Pods"
                guard exists(t) else { continue }
                var skip: SkipReason? = exists(pr + "/Podfile.lock") ? nil : .noLockfile
                if skip == nil { skip = projectSkip(target: t, project: p.root, days: days) }
                r.items.append(item(.podsDirs, t, detail: (p.root as NSString).lastPathComponent, skip: skip, project: p.root, inactive: days))
            }
        }
        return r
    }

    private func homebrew() -> CategoryResult {
        var r = CategoryResult(category: .homebrew)
        guard runTools, let brew = tools.find("brew") else { return r }
        guard let res = tools.run("brew", ["cleanup", "-n", "--prune=30"], timeout: 120) else { return r }
        let bytes = CleanerRules.brewFreeBytes(res.stdout + res.stderr) ?? 0
        let lines = res.stdout.split(separator: "\n").filter { $0.hasPrefix("Would remove") }.count
        guard bytes > 0 || lines > 0 else { return r }
        let busy = snapshot.processes.any { $0.contains("/brew ") && ($0.contains(" install") || $0.contains(" upgrade")) }
        r.items.append(CleanItem(id: "homebrew", category: .homebrew, path: nil, title: "brew cleanup --prune=30",
                                 detail: "\(lines) eski dosya", bytes: bytes, skip: busy ? .toolRunning : nil,
                                 action: .command(brew, ["cleanup", "--prune=30"])))
        return r
    }

    private func homebrewAutoremove() -> CategoryResult {
        var r = CategoryResult(category: .homebrewAutoremove)
        guard runTools, let res = tools.run("brew", ["autoremove", "-n"], timeout: 60) else { return r }
        for line in res.stdout.split(separator: "\n") where !line.hasPrefix("==>") && !line.isEmpty {
            let name = line.trimmingCharacters(in: .whitespaces)
            r.items.append(CleanItem(id: "brewAR:" + name, category: .homebrewAutoremove, path: nil, title: name,
                                     detail: "brew autoremove ile kaldırılabilir", action: .suggest))
        }
        return r
    }

    private func docker(_ c: CleanCategory) -> CategoryResult {
        var r = CategoryResult(category: c)
        guard runTools, let docker = tools.find("docker") else { return r }
        guard let info = tools.run("docker", ["info", "--format", "{{.ServerVersion}}"], timeout: 8), info.succeeded else {
            r.note = "Docker çalışmıyor"
            return r
        }
        let df = tools.run("docker", ["system", "df", "--format", "{{.Type}}\t{{.Reclaimable}}"], timeout: 30)
        let rec = CleanerRules.dockerReclaimable(df?.stdout ?? "")
        if c == .dockerDangling {
            let dangling = tools.run("docker", ["images", "-f", "dangling=true", "-q"], timeout: 20)?.stdout
                .split(separator: "\n").count ?? 0
            if dangling > 0 {
                r.items.append(CleanItem(id: "docker:images", category: c, path: nil, title: "\(dangling) etiketsiz imaj",
                                         detail: "docker image prune", action: .command(docker, ["image", "prune", "-f"])))
            }
            if let b = rec["Build Cache"], b > 0 {
                r.items.append(CleanItem(id: "docker:builder", category: c, path: nil, title: "Kullanılmayan derleme önbelleği",
                                         detail: "docker builder prune", bytes: b, action: .command(docker, ["builder", "prune", "-f"])))
            }
        } else if let b = rec["Local Volumes"], b > 0 {
            r.items.append(CleanItem(id: "docker:volumes", category: c, path: nil, title: "Kullanılmayan birimler",
                                     detail: "docker volume prune — içindeki veri silinir", bytes: b,
                                     action: .command(docker, ["volume", "prune", "-f"])))
        }
        return r
    }

    private func uvCache() -> CategoryResult {
        var r = CategoryResult(category: .uvCache)
        guard runTools, let uv = tools.find("uv") else { return r }
        let path = tools.run("uv", ["cache", "dir"], timeout: 10)?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, exists(path) else { return r }
        let size = DiskUsage.measure(path, cancel: cancel, deadline: deadline).bytes
        r.items.append(CleanItem(id: "uvCache", category: .uvCache, path: path, title: "uv cache prune",
                                 detail: "önbellek \(CleanerRules.formatBytes(size)) · kullanılmayanlar silinir",
                                 action: .command(uv, ["cache", "prune"])))
        return r
    }

    private func rustTargets() -> CategoryResult {
        var r = CategoryResult(category: .rustTargets)
        let days = settings.age(.rustTargets) ?? 7
        for p in projects where p.hasCargo {
            let t = p.root + "/target"
            guard exists(t) else { continue }
            let skip = projectSkip(target: t, project: p.root, days: days)
            r.items.append(item(.rustTargets, t, detail: (p.root as NSString).lastPathComponent, skip: skip, project: p.root, inactive: days))
        }
        return r
    }

    private func goCache() -> CategoryResult {
        var r = CategoryResult(category: .goBuildCache)
        guard runTools, let go = tools.find("go") else { return r }
        let path = tools.run("go", ["env", "GOCACHE"], timeout: 10)?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, exists(path) else { return r }
        let size = DiskUsage.measure(path, cancel: cancel, deadline: deadline).bytes
        r.items.append(CleanItem(id: "goBuildCache", category: .goBuildCache, path: path, title: "go clean -cache",
                                 detail: PathGuard.display(path, home: home), bytes: size, action: .command(go, ["clean", "-cache"])))
        return r
    }

    private func editorServers() -> CategoryResult {
        var r = CategoryResult(category: .editorServers)
        for base in [".cursor-server/bin", ".cursor-server/cli/servers", ".vscode-server/bin", ".vscode-server/cli/servers"] {
            let dirs = children(home + "/" + base)
            guard !dirs.isEmpty else { continue }
            let newest = dirs.max { (mtime($0) ?? .distantPast) < (mtime($1) ?? .distantPast) }
            for d in dirs {
                let name = (d as NSString).lastPathComponent
                var skip: SkipReason?
                if d == newest { skip = .keptNewest }
                else if snapshot.processes.contains(d) || snapshot.processes.contains(name) { skip = .runningProcess }
                else { skip = cacheSkip(d) }
                if skip == .keptNewest {
                    r.items.append(CleanItem(id: "editor:" + d, category: .editorServers, path: d, title: PathGuard.display(d, home: home), skip: skip))
                } else {
                    r.items.append(item(.editorServers, d, skip: skip, modified: mtime(d)))
                }
            }
        }
        return r
    }

    private func agentLogs() -> CategoryResult {
        var r = CategoryResult(category: .agentLogs)
        let days = settings.age(.agentLogs) ?? 30
        var dirs = [home + "/.claude/shell-snapshots", home + "/.claude/todos", home + "/.claude/debug",
                    home + "/.codex/log", home + "/.cursor/cli-logs"]
        for p in children(home + "/.cursor/projects") {
            dirs += [p + "/terminals", p + "/agent-tools"]
        }
        for d in dirs where exists(d) {
            let skip = cacheSkipForPrune(d)
            var it = item(.agentLogs, d, skip: skip, action: .pruneFiles(days))
            if it.isActionable && it.bytes == 0 { continue }
            it.title = PathGuard.display(d, home: home)
            r.items.append(it)
        }
        return r
    }

    /// pruneFiles için: klasördeki açık dosyalar silme anında tek tek atlanır; burada yalnızca yol denetlenir.
    private func cacheSkipForPrune(_ d: String) -> SkipReason? {
        if let r = PathGuard.check(d, home: home, neverTouch: settings.neverTouch) { return r }
        if !snapshot.openFiles.reliable { return .unverified }
        return nil
    }

    private func pruneDirs(_ c: CleanCategory, _ dirs: [String], busy: Bool = false) -> CategoryResult {
        var r = CategoryResult(category: c)
        let days = settings.age(c) ?? 30
        for d in dirs where exists(d) {
            let skip: SkipReason? = busy ? .toolRunning : cacheSkipForPrune(d)
            let it = item(c, d, skip: skip, action: .pruneFiles(days))
            if it.isActionable && it.bytes == 0 { continue }
            r.items.append(it)
        }
        return r
    }

    private func simpleCacheChildren(_ c: CleanCategory, _ dir: String, busy: Bool) -> CategoryResult {
        var r = CategoryResult(category: c)
        let days = settings.age(c) ?? 30
        for d in children(dir) {
            var skip: SkipReason? = busy ? .toolRunning : cacheSkip(d)
            if skip == nil, CleanerRules.isRecent(mtime(d), days: days, now: now) { skip = .recent }
            r.items.append(item(c, d, skip: skip, modified: mtime(d)))
        }
        return r
    }

    private func wholeDir(_ c: CleanCategory, _ dir: String, busy: Bool) -> CategoryResult {
        var r = CategoryResult(category: c)
        guard exists(dir) else { return r }
        r.items.append(item(c, dir, skip: busy ? .toolRunning : cacheSkip(dir)))
        return r
    }

    private func ctime(_ p: String) -> Date? {
        var st = stat()
        guard lstat(p, &st) == 0 else { return nil }
        #if os(Linux)
        return Date(timeIntervalSince1970: TimeInterval(st.st_ctim.tv_sec))
        #else
        return Date(timeIntervalSince1970: TimeInterval(st.st_ctimespec.tv_sec))
        #endif
    }

    private func trash() -> CategoryResult {
        var r = CategoryResult(category: .trash)
        let dir = home + "/.Trash"
        let days = settings.age(.trash) ?? 30
        guard (try? FileManager.default.contentsOfDirectory(atPath: dir)) != nil else {
            if exists(dir) { r.note = "Çöp Sepeti'ni okumak için Tam Disk Erişimi izni gerekiyor" }
            return r
        }
        for p in children(dir) {
            // Çöp'e atılma zamanı ≈ durum değişikliği zamanı (taşıma ctime'ı günceller).
            let put = ctime(p)
            var skip = cacheSkip(p)
            if skip == nil, CleanerRules.isRecent(put, days: days, now: now) { skip = .recent }
            r.items.append(item(.trash, p, title: (p as NSString).lastPathComponent, skip: skip, modified: put))
        }
        return r
    }

    static let appCacheSkip: Set<String> = ["CocoaPods", "ms-playwright", "pip", "Yarn", "Homebrew", "node-gyp", "CloudKit",
                                            "com.apple.bird", "FamilyCircle", "GeoServices", "familycircled"]

    private func appCaches() -> CategoryResult {
        var r = CategoryResult(category: .appCaches)
        let days = settings.age(.appCaches) ?? 30
        for p in children(home + "/Library/Caches") {
            let name = (p as NSString).lastPathComponent
            if name.hasPrefix("com.apple.") || name.hasPrefix(".") || Self.appCacheSkip.contains(name) { continue }
            let short = name.components(separatedBy: ".").last ?? name
            var skip: SkipReason?
            if snapshot.processes.mentions(name) || (short.count >= 4 && snapshot.processes.mentions("/" + short)) { skip = .runningProcess }
            else { skip = cacheSkip(p) }
            let m = DiskUsage.measure(p, cancel: cancel, deadline: deadline)
            if skip == nil, CleanerRules.isRecent(m.newest ?? mtime(p), days: days, now: now) { skip = .recent }
            var it = CleanItem(id: "appCaches:" + p, category: .appCaches, path: p, title: name, modified: m.newest, skip: skip)
            it.bytes = m.bytes
            if m.bytes < 1_000_000 { continue } // küçükleri listeleme
            r.items.append(it)
        }
        r.items.sort { $0.bytes > $1.bytes }
        return r
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
