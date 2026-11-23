import Foundation

// Geliştirici Temizleyici — uygulama. Her öğe silinmeden HEMEN önce yeniden denetlenir.

final class CleanerExecutor {
    let settings: CleanerSettings
    let home: String
    let cancel: CancelToken
    let tools: ToolLocator
    var progress: (String, Double) -> Void = { _, _ in }
    /// Testler: sistem anlık görüntüsü ve Çöp davranışı.
    var snapshotProvider: () -> SystemSnapshot
    var trashHandler: (URL) throws -> Void
    var now: () -> Date = { Date() }

    init(settings: CleanerSettings, home: String = FileManager.default.homeDirectoryForCurrentUser.path, cancel: CancelToken = CancelToken()) {
        self.settings = settings
        self.home = PathGuard.normalize(home)
        self.cancel = cancel
        self.tools = ToolLocator(home: PathGuard.normalize(home))
        let h = PathGuard.normalize(home)
        self.snapshotProvider = { SystemSnapshot.capture(home: h) }
        self.trashHandler = { url in
            #if os(macOS)
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            #else
            let trash = URL(fileURLWithPath: h + "/.local/share/Trash/files", isDirectory: true)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent + "-" + UUID().uuidString.prefix(6)))
            #endif
        }
    }

    enum Outcome: Equatable {
        case trashed(Int64), removed(Int64), command(Int64), skipped(String), failed(String)
    }

    func run(_ items: [CleanItem], trigger: CleanerAutoPolicy.Trigger) -> CleanRunRecord {
        let snap = snapshotProvider()
        var record = CleanRunRecord(date: now(), trigger: trigger, reclaimed: 0, trashed: 0, entries: [], errors: 0)
        let work = items.filter { $0.isActionable && $0.selected }
        Log.info("Temizleyici başladı (\(trigger.rawValue)): \(work.count) öğe, açık dosya denetimi: \(snap.openFiles.reliable ? "tamam" : "YAPILAMADI")")
        for (i, item) in work.enumerated() {
            if cancel.isCancelled { break }
            progress(item.title, Double(i) / Double(max(work.count, 1)))
            let outcome = execute(item, snapshot: snap)
            var result = ""
            switch outcome {
            case .trashed(let b): record.trashed += b; result = L("çöp")
            case .removed(let b): record.reclaimed += b; result = L("silindi")
            case .command(let b): record.reclaimed += b; result = L("komut")
            case .skipped(let why): result = L("atlandı: ") + why
            case .failed(let why): record.errors += 1; result = L("hata: ") + why
            }
            let bytes: Int64
            switch outcome {
            case .trashed(let b), .removed(let b), .command(let b): bytes = b
            default: bytes = 0
            }
            record.entries.append(.init(category: item.category, title: item.path.map { PathGuard.display($0, home: home) } ?? item.title, bytes: bytes, result: result))
            let line = "Temizleyici: \(item.path.map { PathGuard.display($0, home: home) } ?? item.title) → \(result) (\(CleanerRules.formatBytes(bytes)))"
            if case .failed = outcome { Log.warn(line) } else { Log.info(line) }
        }
        progress(L("Bitti"), 1)
        Log.info("Temizleyici bitti: \(CleanerRules.formatBytes(record.reclaimed)) silindi, \(CleanerRules.formatBytes(record.trashed)) Çöp'e taşındı, \(record.errors) hata")
        CleanHistory.append(record)
        return record
    }

    func deleteStyle(for c: CleanCategory) -> DeleteStyle {
        switch c.deleteStyle {
        case .cache: return settings.permanentForCaches ? .permanent : .trash
        default: return c.deleteStyle
        }
    }

    func execute(_ item: CleanItem, snapshot snap: SystemSnapshot) -> Outcome {
        switch item.action {
        case .suggest:
            return .skipped(L("yalnızca öneri"))
        case .command(let exe, let args):
            return runCommand(item, exe: exe, args: args)
        case .delete:
            guard let path = item.path else { return .skipped(L("yol yok")) }
            if let why = recheck(path: path, item: item, snapshot: snap) { return .skipped(why) }
            let bytes = item.bytes
            let url = URL(fileURLWithPath: path)
            do {
                if deleteStyle(for: item.category) == .permanent {
                    try FileManager.default.removeItem(at: url)
                    return .removed(bytes)
                }
                try trashHandler(url)
                return .trashed(bytes)
            } catch {
                return .failed(error.localizedDescription)
            }
        case .pruneFiles(let days):
            guard let path = item.path else { return .skipped(L("yol yok")) }
            if let r = PathGuard.check(path, home: home, neverTouch: settings.neverTouch) { return .skipped(r.text) }
            guard snap.openFiles.reliable else { return .skipped(SkipReason.unverified.text) }
            return .removed(pruneFiles(in: path, olderThanDays: days, snapshot: snap))
        }
    }

    /// Silmeden hemen önce: var mı, bağlantı mı, korunuyor mu, açık dosya/çalışma klasörü, proje yeniden aktif mi?
    func recheck(path: String, item: CleanItem, snapshot snap: SystemSnapshot) -> String? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return L("artık yok") }
        if (st.st_mode & S_IFMT) == S_IFLNK { return L("sembolik bağlantı") }
        // Gerçek yol (üst klasörlerde bağlantı varsa) yine ev klasörü içinde ve korunmayan yerde olmalı.
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        for p in Set([path, real]) {
            if let r = PathGuard.check(p, home: home, neverTouch: settings.neverTouch) { return r.text }
        }
        guard snap.openFiles.reliable else { return SkipReason.unverified.text }
        if snap.openFiles.hasOpenFile(under: path) != nil { return SkipReason.openFiles.text }
        if snap.openFiles.hasProcessCwd(under: path) != nil { return SkipReason.runningProcess.text }
        if let project = item.projectRoot {
            if snap.openFiles.hasProcessCwd(under: project) != nil { return SkipReason.runningProcess.text }
            if let days = item.inactiveDays {
                let newest = DiskUsage.newestActivity(project: project, excluding: CleanerScanner.artifactNames)
                if CleanerRules.isRecent(newest, days: days, now: now()) { return SkipReason.activeProject.text }
            }
        }
        return nil
    }

    /// Klasörde `days` günden eski, açık olmayan dosyaları siler; boşalan alt klasörleri kaldırır.
    func pruneFiles(in dir: String, olderThanDays days: Int, snapshot snap: SystemSnapshot) -> Int64 {
        let cutoff = now().addingTimeInterval(-Double(days) * 86400)
        let url = URL(fileURLWithPath: dir)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .contentModificationDateKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return 0 }
        var freed: Int64 = 0
        var dirs: [URL] = []
        for case let f as URL in en {
            if cancel.isCancelled { break }
            guard let v = try? f.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true && v.isSymbolicLink != true { dirs.append(f); continue }
            guard v.isRegularFile == true || v.isSymbolicLink == true, let m = v.contentModificationDate, m < cutoff else { continue }
            let p = f.path
            if snap.openFiles.hasOpenFile(under: p) != nil { continue }
            if PathGuard.check(p, home: home, neverTouch: settings.neverTouch) != nil { continue }
            let size = Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
            if (try? FileManager.default.removeItem(at: f)) != nil { freed += size }
        }
        // Boşalan klasörler (en derinden başlayarak); kök klasör kalır.
        for d in dirs.sorted(by: { $0.path.count > $1.path.count }) {
            if let c = try? FileManager.default.contentsOfDirectory(atPath: d.path), c.isEmpty {
                try? FileManager.default.removeItem(at: d)
            }
        }
        return freed
    }

    private func runCommand(_ item: CleanItem, exe: String, args: [String]) -> Outcome {
        guard FileManager.default.isExecutableFile(atPath: exe) else { return .failed(L("araç bulunamadı: %@", exe)) }
        let before = item.path.map { DiskUsage.measure($0, cancel: cancel).bytes }
        let res = Shell.run(exe, args, timeout: 900, environment: tools.environment)
        guard res.succeeded else {
            let msg = (res.stderr.isEmpty ? res.stdout : res.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(res.timedOut ? L("zaman aşımı") : String(msg.suffix(200)))
        }
        if let b = before, let p = item.path {
            let after = FileManager.default.fileExists(atPath: p) ? DiskUsage.measure(p, cancel: cancel).bytes : 0
            return .command(max(0, b - after))
        }
        if exe.hasSuffix("/brew"), let b = CleanerRules.brewFreeBytes(res.stdout) { return .command(b) }
        return .command(item.bytes)
    }
}
