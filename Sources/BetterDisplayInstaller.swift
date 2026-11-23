import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// BetterDisplay yoksa otomatik kurar:
///  1) Homebrew varsa: `brew install --cask betterdisplay`
///  2) yoksa (veya başarısızsa): GitHub'daki son sürüm DMG'si (waydabber/BetterDisplay) URLSession ile
///     indirilir, hdiutil ile bağlanır, /Applications'a kopyalanır ve ayrılır.
/// İlerleme `onProgress` ile ana kuyrukta bildirilir. `installSync` arka plan kuyruğundan çağrılmalıdır.
final class BetterDisplayInstaller: NSObject, URLSessionDownloadDelegate {
    enum Progress: Equatable {
        case idle
        case working(String)                 // belirsiz ilerleme
        case downloading(Double, String)     // 0…1
        case done
        case failed(String)
    }

    static let appPath = "/Applications/BetterDisplay.app"
    static let releasesAPI = URL(string: "https://api.github.com/repos/waydabber/BetterDisplay/releases/latest")!

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: appPath) }

    /// Kurulu BetterDisplay sürümü (Info.plist CFBundleShortVersionString).
    static var installedVersion: String? {
        let plist = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    var onProgress: ((Progress) -> Void)?

    private var downloadDone = DispatchSemaphore(value: 0)
    private var downloadedFile: URL?
    private var downloadError: String?
    private var lastReported = -1.0

    private func report(_ p: Progress) {
        if let cb = onProgress { DispatchQueue.main.async { cb(p) } }
    }

    /// Kurulum yapar; başarıda nil, hatada açıklama döndürür.
    func installSync() -> String? {
        if Self.isInstalled { report(.done); return nil }
        Log.info("BetterDisplay kurulu değil; otomatik kurulum başlıyor.")

        for brew in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] where FileManager.default.isExecutableFile(atPath: brew) {
            report(.working(L("Homebrew ile kuruluyor…")))
            let r = Shell.run(brew, ["install", "--cask", "betterdisplay"], timeout: 900)
            if Self.isInstalled {
                Log.info("BetterDisplay Homebrew ile kuruldu.")
                return finish()
            }
            Log.warn("brew install --cask betterdisplay başarısız (\(r.status)): \(r.stderr.suffix(300))")
            break
        }
        return installFromGitHub()
    }

    private func finish() -> String? {
        report(.working(L("BetterDisplay başlatılıyor…")))
        Shell.run("/usr/bin/open", ["-g", "-a", Self.appPath], timeout: 15)
        report(.done)
        return nil
    }

    private func fail(_ message: String) -> String {
        Log.error("BetterDisplay kurulumu: \(message)")
        report(.failed(message))
        return message
    }

    private func installFromGitHub() -> String? {
        report(.working(L("Son sürüm aranıyor (GitHub)…")))
        guard let dmgURL = latestDMGURL() else { return fail(L("GitHub'da DMG bulunamadı")) }

        report(.downloading(0, dmgURL.lastPathComponent))
        downloadDone = DispatchSemaphore(value: 0)
        downloadedFile = nil
        downloadError = nil
        lastReported = -1
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        session.downloadTask(with: dmgURL).resume()
        if downloadDone.wait(timeout: .now() + 900) == .timedOut {
            session.invalidateAndCancel()
            return fail(L("İndirme zaman aşımı"))
        }
        session.finishTasksAndInvalidate()
        guard let dmg = downloadedFile else { return fail(downloadError ?? L("İndirme başarısız")) }
        defer { try? FileManager.default.removeItem(at: dmg) }

        report(.working(L("DMG bağlanıyor…")))
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("bd-mount-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let attach = Shell.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                                   "-mountpoint", mount.path, dmg.path], timeout: 120)
        guard attach.succeeded else { return fail("hdiutil attach: \(attach.stderr.prefix(200))") }
        defer {
            Shell.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"], timeout: 60)
            try? FileManager.default.removeItem(at: mount)
        }

        let apps = (try? FileManager.default.contentsOfDirectory(atPath: mount.path))?.filter { $0.hasSuffix(".app") } ?? []
        guard let appName = apps.first(where: { $0.lowercased().contains("betterdisplay") }) ?? apps.first else {
            return fail(L("DMG içinde uygulama bulunamadı"))
        }

        report(.working(L("/Applications'a kopyalanıyor…")))
        let copy = Shell.run("/usr/bin/ditto", [mount.appendingPathComponent(appName).path, Self.appPath], timeout: 300)
        guard copy.succeeded, Self.isInstalled else {
            return fail(L("Kopyalama başarısız (yönetici izni?): %@", copy.stderr.prefix(200)))
        }
        Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", Self.appPath], timeout: 30)
        Log.info("BetterDisplay GitHub sürümünden kuruldu (\(dmgURL.lastPathComponent)).")
        return finish()
    }

    /// GitHub API: son sürümdeki ilk .dmg varlığının indirme adresi.
    private func latestDMGURL() -> URL? {
        var request = URLRequest(url: Self.releasesAPI, timeoutInterval: 30)
        request.setValue("Workstation", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let done = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var url: URL? }
        let box = Box()
        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { done.signal() }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let assets = json["assets"] as? [[String: Any]] else { return }
            for a in assets {
                if let name = a["name"] as? String, name.lowercased().hasSuffix(".dmg"),
                   let s = a["browser_download_url"] as? String, let u = URL(string: s) {
                    box.url = u
                    return
                }
            }
        }
        task.resume()
        _ = done.wait(timeout: .now() + 40)
        return box.url
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Geçici dosya bu metottan dönünce silinir: hemen taşı.
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("BetterDisplay-\(UUID().uuidString).dmg")
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            downloadedFile = dest
        } catch {
            downloadError = L("İndirilen dosya taşınamadı: %@", error.localizedDescription)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        if fraction - lastReported >= 0.02 || fraction >= 1 {   // UI'ı her baytta güncelleme
            lastReported = fraction
            report(.downloading(fraction, "\(totalBytesWritten / 1_000_000) / \(totalBytesExpectedToWrite / 1_000_000) MB"))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error { downloadError = e.localizedDescription }
        downloadDone.signal()
    }
}
