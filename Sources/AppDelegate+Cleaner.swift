import Cocoa

// Geliştirici Temizleyici: tarama/temizlik akışı, otomatik mod (tek zamanlayıcı + 6 saatte bir ucuz boş alan kontrolü).
extension AppDelegate {

    func wireCleaner() {
        let c = panelModel.cleaner
        c.onScan = { [weak self] in self?.startCleanerScan(trigger: .manual) }
        c.onCancel = { [weak self] in self?.cleanerCancel?.cancel() }
        c.onClean = { [weak self] in self?.cleanSelected() }
        c.onOpenPage = { [weak self] in self?.panelModel.page = .cleaner }
        c.onSettings = { [weak self] s in
            guard let self = self else { return }
            let autoChanged = s.autoEnabled != c.settings.autoEnabled || s.autoDaily != c.settings.autoDaily
                || s.autoHour != c.settings.autoHour || s.autoMinute != c.settings.autoMinute || s.autoLowSpace != c.settings.autoLowSpace
            s.save()
            c.settings = s
            if autoChanged { self.configureCleanerAuto() }
        }
        refreshCleanerDisk()
    }

    func refreshCleanerDisk() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let d = SystemStatsSampler.disk(path: FileManager.default.homeDirectoryForCurrentUser.path)
            DispatchQueue.main.async {
                guard let c = self?.panelModel.cleaner else { return }
                if c.diskFree != d.0 { c.diskFree = d.0 }
                if c.diskTotal != d.1 { c.diskTotal = d.1 }
            }
        }
    }

    /// Tarar; `autoClean` ise seçili (güvenli) öğeleri hemen temizler.
    func startCleanerScan(trigger: CleanerAutoPolicy.Trigger, autoClean: Bool = false) {
        let c = panelModel.cleaner
        guard !c.busy else { return }
        let settings = c.settings
        let cats: [CleanCategory] = autoClean
            ? CleanCategory.allCases.filter { settings.isAuto($0) }
            : CleanCategory.allCases.filter { settings.isEnabled($0) }
        let token = CancelToken()
        cleanerCancel = token
        c.scanning = true
        c.confirming = false
        c.note = nil
        c.stage = L("Hazırlanıyor…")
        c.fraction = 0
        Log.info("Temizleyici taraması başladı (\(trigger.rawValue), \(cats.count) kategori)")
        cleanerQueue.async { [weak self] in
            let lock = CleanerLock()
            guard lock.acquire() else {
                DispatchQueue.main.async {
                    c.scanning = false
                    c.note = L("Başka bir temizlik zaten çalışıyor.")
                }
                return
            }
            defer { lock.release() }
            DispatchQueue.main.async { c.stage = L("Açık dosyalar ve çalışan programlar kontrol ediliyor…") }
            let scanner = CleanerScanner(settings: settings, cancel: token)
            scanner.progress = { stage, f in DispatchQueue.main.async { c.stage = stage; c.fraction = f } }
            let report = scanner.scan(cats)
            Log.info("Temizleyici taraması bitti: \(CleanerRules.formatBytes(report.selectedBytes)) temizlenebilir, \(Int(report.duration)) sn\(report.cancelled ? " (durduruldu)" : "")")
            var record: CleanRunRecord?
            if autoClean && !token.isCancelled && !report.selectedItems.isEmpty {
                DispatchQueue.main.async { c.scanning = false; c.cleaning = true; c.stage = L("Temizleniyor…") }
                let exec = CleanerExecutor(settings: settings, cancel: token)
                exec.progress = { stage, f in DispatchQueue.main.async { c.stage = stage; c.fraction = f } }
                record = exec.run(report.selectedItems, trigger: trigger)
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                c.scanning = false
                c.cleaning = false
                c.report = record == nil ? report : nil
                if let r = record {
                    c.lastRun = r
                    c.note = self.summary(r)
                    self.notifyCleaned(r)
                } else if report.cancelled {
                    c.note = L("Tarama durduruldu.")
                } else if trigger == .url {
                    self.notifier.notify(kind: "cleanerScan", title: L("Disk taraması bitti"),
                                         body: report.selectedBytes > 0
                                            ? L("%@ güvenle temizlenebilir. Tools › Disk'ten bakabilirsin.", CleanerRules.formatBytes(report.selectedBytes))
                                            : L("Temizlenecek bir şey bulunamadı."))
                }
                self.refreshCleanerDisk()
            }
        }
    }

    func cleanSelected() {
        let c = panelModel.cleaner
        guard !c.busy, let report = c.report, !report.selectedItems.isEmpty else { return }
        let items = report.selectedItems
        let settings = c.settings
        let token = CancelToken()
        cleanerCancel = token
        c.cleaning = true
        c.fraction = 0
        c.stage = L("Temizleniyor…")
        cleanerQueue.async { [weak self] in
            let lock = CleanerLock()
            guard lock.acquire() else {
                DispatchQueue.main.async { c.cleaning = false; c.note = L("Başka bir temizlik zaten çalışıyor.") }
                return
            }
            defer { lock.release() }
            let exec = CleanerExecutor(settings: settings, cancel: token)
            exec.progress = { stage, f in DispatchQueue.main.async { c.stage = stage; c.fraction = f } }
            let rec = exec.run(items, trigger: .manual)
            DispatchQueue.main.async {
                guard let self = self else { return }
                c.cleaning = false
                c.lastRun = rec
                c.report = nil
                c.note = self.summary(rec)
                self.refreshCleanerDisk()
            }
        }
    }

    func summary(_ r: CleanRunRecord) -> String {
        var parts: [String] = []
        if r.reclaimed > 0 { parts.append(L("%@ yer açıldı", CleanerRules.formatBytes(r.reclaimed))) }
        if r.trashed > 0 { parts.append(L("%@ Çöp Sepeti'ne taşındı", CleanerRules.formatBytes(r.trashed))) }
        let skipped = r.entries.filter { $0.result.hasPrefix(L("atlandı")) }.count
        if skipped > 0 { parts.append(L("%@ öğe o an kullanıldığı için atlandı", skipped)) }
        if r.errors > 0 { parts.append(L("%@ öğe silinemedi (ayrıntı günlükte)", r.errors)) }
        return parts.isEmpty ? L("Temizlenecek bir şey kalmamış.") : parts.joined(separator: " · ")
    }

    func notifyCleaned(_ r: CleanRunRecord) {
        let total = r.reclaimed + r.trashed
        guard total > 0 || r.errors > 0 else { return }
        notifier.notify(kind: "cleaner", title: L("Disk temizlendi: %@", CleanerRules.formatBytes(total)), body: summary(r))
    }
}
