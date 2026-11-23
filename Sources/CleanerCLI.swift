import Foundation

// `Workstation --clean [--dry-run|--auto|--yes]` (ve `workstation clean …`): arayüz olmadan tarama/temizlik.

enum CleanerCLI {
    enum Mode { case dryRun, auto, yes }

    static func mode(from args: [String]) -> Mode {
        if args.contains("--yes") || args.contains("-y") { return .yes }
        if args.contains("--auto") { return .auto }
        return .dryRun
    }

    static func categories(for mode: Mode, settings: CleanerSettings) -> [CleanCategory] {
        switch mode {
        case .auto: return CleanCategory.allCases.filter { settings.isAuto($0) }
        case .dryRun, .yes: return CleanCategory.allCases.filter { settings.isEnabled($0) }
        }
    }

    static func render(_ report: ScanReport, home: String, verbose: Bool) -> String {
        var out: [String] = []
        if !report.inUseCheckOK { out.append(L("⚠ Açık dosya denetimi yapılamadı: güvenlik için proje ve önbellek silmeleri atlanacak.")) }
        for r in report.results where !r.items.isEmpty || r.note != nil {
            let head = "\(r.category.title) — \(CleanerRules.formatBytes(r.selectedBytes))"
            out.append("\n▸ " + head)
            if let n = r.note { out.append("    (\(n))") }
            for i in r.items {
                if i.skip != nil && !verbose { continue }
                let mark = i.skip != nil ? "  ·" : (i.action == .suggest ? "  ?" : "  ✓")
                var line = "\(mark) \(i.path.map { PathGuard.display($0, home: home) } ?? i.title)"
                if i.bytes > 0 { line += "  \(CleanerRules.formatBytes(i.bytes))" }
                if let m = i.modified { line += "  \(CleanerRules.ageText(m))" }
                if let s = i.skip { line += "  [\(s.text)]" }
                else if !i.detail.isEmpty && i.path != nil { line += "  (\(i.detail))" }
                out.append(line)
            }
            let skipped = r.items.filter { $0.skip != nil }.count
            if skipped > 0 && !verbose { out.append(L("    + %@ öğe güvenlik nedeniyle atlandı (--verbose ile göster)", skipped)) }
        }
        out.append(L("\nToplam temizlenebilir: %@ · %@ öğe · tarama %@ sn", CleanerRules.formatBytes(report.selectedBytes), report.selectedItems.count, Int(report.duration)))
        return out.joined(separator: "\n")
    }

    static func run(_ args: [String]) -> Int32 {
        let m = mode(from: args)
        let verbose = args.contains("--verbose") || args.contains("-v")
        let settings = CleanerSettings.load()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let lock = CleanerLock()
        guard lock.acquire() else {
            FileHandle.standardError.write(L("Başka bir temizlik zaten çalışıyor.\n").data(using: .utf8)!)
            return 2
        }
        defer { lock.release() }
        let cats = categories(for: m, settings: settings)
        print(L("Taranıyor (%@ kategori)… açık dosyalar ve çalışan programlar kontrol ediliyor.", cats.count))
        let scanner = CleanerScanner(settings: settings, home: home)
        var lastStage = ""
        scanner.progress = { stage, _ in
            if stage != lastStage { lastStage = stage; FileHandle.standardError.write("  · \(stage)\n".data(using: .utf8)!) }
        }
        let report = scanner.scan(cats)
        print(render(report, home: home, verbose: verbose))
        guard m != .dryRun else {
            print(L("\nBu bir deneme taramasıydı; hiçbir şey silinmedi. Silmek için: workstation clean --yes (otomatik küme: --auto)"))
            return 0
        }
        guard !report.selectedItems.isEmpty else { print(L("Temizlenecek bir şey yok.")); return 0 }
        let exec = CleanerExecutor(settings: settings, home: home)
        let rec = exec.run(report.selectedItems, trigger: .cli)
        print(L("\nSilindi: %@ · Çöp'e taşındı: %@ · hata: %@", CleanerRules.formatBytes(rec.reclaimed), CleanerRules.formatBytes(rec.trashed), rec.errors))
        for e in rec.entries where e.result.hasPrefix(L("atlandı")) || e.result.hasPrefix(L("hata")) {
            print("  \(e.title): \(e.result)")
        }
        return rec.errors > 0 ? 1 : 0
    }
}
