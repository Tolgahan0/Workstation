import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(macOS)
import Security
#endif

// Güncelleyici (Sparkle yok). GitHub Releases'tan latest.json + zip indirir, SHA-256 / paket kimliği / imza
// doğrular, küçük bir betikle uygulama kapandıktan sonra /Applications/Workstation.app'i değiştirip yeniden açar.

enum UpdateToken {
    static let service = "com.tolgahanayaz.workstation.github"
    static let account = "token"

    static func read() -> String? {
        #if os(macOS)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
              let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
        return s
        #else
        return ProcessInfo.processInfo.environment["WORKSTATION_GITHUB_TOKEN"]
        #endif
    }

    @discardableResult
    static func save(_ token: String?) -> Bool {
        #if os(macOS)
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let t = token?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(t.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        #else
        return false
        #endif
    }
}

final class Updater {
    enum UpdateError: LocalizedError {
        case http(Int), noManifest, badManifest, noZip, checksum, badBundle(String), signature, io(String)
        var errorDescription: String? {
            switch self {
            case .http(let c): return c == 404 ? L("Yayın bulunamadı (depo özelse anahtar gerekir)") : L("Sunucu hatası (%@)", c)
            case .noManifest: return L("Yayında latest.json yok")
            case .badManifest: return L("latest.json okunamadı")
            case .noZip: return L("Yayında uygulama dosyası yok")
            case .checksum: return L("İndirilen dosya doğrulanamadı (SHA-256 uyuşmuyor)")
            case .badBundle(let w): return L("İndirilen uygulama beklenen uygulama değil: %@", w)
            case .signature: return L("Uygulama imzası doğrulanamadı")
            case .io(let m): return m
            }
        }
    }

    struct Candidate: Equatable {
        var version: String
        var notes: String
        var manifest: UpdateManifest
        var zipAPIURL: String?
        var zipURL: String
        var pageURL: String?
    }

    let bundleID: String
    let currentVersion: String
    var settings: UpdateSettings
    private let session: URLSession

    init(bundleID: String, currentVersion: String, settings: UpdateSettings) {
        self.bundleID = bundleID
        self.currentVersion = currentVersion
        self.settings = settings
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: cfg)
    }

    private func request(_ url: URL, accept: String) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(accept, forHTTPHeaderField: "Accept")
        r.setValue("Workstation/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let t = UpdateToken.read() { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        return r
    }

    private func fetch(_ req: URLRequest) throws -> Data {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(UpdateError.io(L("zaman aşımı")))
        session.dataTask(with: req) { data, resp, err in
            if let e = err { result = .failure(e) }
            else if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { result = .failure(UpdateError.http(h.statusCode)) }
            else { result = .success(data ?? Data()) }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 620)
        return try result.get()
    }

    private func download(_ req: URLRequest, to dest: URL) throws {
        let sem = DispatchSemaphore(value: 0)
        var failure: Error?
        session.downloadTask(with: req) { tmp, resp, err in
            if let e = err { failure = e }
            else if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { failure = UpdateError.http(h.statusCode) }
            else if let t = tmp {
                try? FileManager.default.removeItem(at: dest)
                do { try FileManager.default.moveItem(at: t, to: dest) } catch { failure = error }
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 620)
        if let f = failure { throw f }
    }

    /// Asset: token varsa API adresinden (özel depolar), yoksa tarayıcı adresinden.
    private func assetRequest(apiURL: String?, browserURL: String) -> URLRequest? {
        if UpdateToken.read() != nil, let a = apiURL, let u = URL(string: a) { return request(u, accept: "application/octet-stream") }
        guard let u = URL(string: browserURL) else { return nil }
        return request(u, accept: "application/octet-stream")
    }

    /// Arka planda çağrılır. nil = güncel.
    func check() throws -> Candidate? {
        guard let current = SemVer(currentVersion) else { return nil }
        let base = "https://api.github.com/repos/\(settings.repo)/releases"
        let url = URL(string: settings.beta ? base + "?per_page=15" : base + "/latest")!
        let data = try fetch(request(url, accept: "application/vnd.github+json"))
        let releases: [GitHubRelease]
        if settings.beta { releases = try JSONDecoder().decode([GitHubRelease].self, from: data) }
        else { releases = [try JSONDecoder().decode(GitHubRelease.self, from: data)] }
        guard let rel = UpdatePolicy.pick(releases, current: current, beta: settings.beta) else { return nil }
        guard let m = rel.asset(named: "latest.json"), let req = assetRequest(apiURL: m.url, browserURL: m.browser_download_url) else {
            throw UpdateError.noManifest
        }
        guard let manifest = try? JSONDecoder().decode(UpdateManifest.self, from: try fetch(req)),
              UpdatePolicy.isValidSHA256(manifest.sha256) else { throw UpdateError.badManifest }
        let zip = manifest.zip_name.flatMap { rel.asset(named: $0) } ?? rel.zipAsset
        guard let z = zip else { throw UpdateError.noZip }
        let notes = UpdatePolicy.shortNotes(manifest.notes?.isEmpty == false ? manifest.notes : rel.body)
        return Candidate(version: rel.version?.description ?? manifest.version, notes: notes, manifest: manifest,
                         zipAPIURL: z.url, zipURL: z.browser_download_url, pageURL: rel.html_url)
    }

    // MARK: Kurulum (yalnızca macOS)

    /// İndir + doğrula; hazır .app yolunu döner.
    func prepare(_ c: Candidate, progress: (String) -> Void) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("workstation-update-\(c.version)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent("Workstation.zip")
        progress(L("İndiriliyor…"))
        guard let req = assetRequest(apiURL: c.zipAPIURL, browserURL: c.zipURL) else { throw UpdateError.noZip }
        try download(req, to: zip)
        progress(L("Doğrulanıyor…"))
        let sum = Shell.run("/usr/bin/shasum", ["-a", "256", zip.path], timeout: 60)
        let got = sum.stdout.split(separator: " ").first.map(String.init)?.lowercased() ?? ""
        guard sum.succeeded, got == c.manifest.sha256.lowercased() else { throw UpdateError.checksum }
        let unz = Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path], timeout: 120)
        guard unz.succeeded else { throw UpdateError.io(L("Arşiv açılamadı")) }
        let app = dir.appendingPathComponent("Workstation.app")
        guard let plist = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let info = (try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: Any] else {
            throw UpdateError.badBundle(L("Info.plist yok"))
        }
        guard (info["CFBundleIdentifier"] as? String) == bundleID else { throw UpdateError.badBundle(L("paket kimliği farklı")) }
        guard let v = (info["CFBundleShortVersionString"] as? String).flatMap(SemVer.init), let cur = SemVer(currentVersion), v > cur else {
            throw UpdateError.badBundle(L("sürüm daha yeni değil"))
        }
        let cs = Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], timeout: 60)
        guard cs.succeeded else { throw UpdateError.signature }
        return app
    }

    /// Yardımcı (fan) yeniden kurulmalı mı?
    static func helperChanged(newApp: URL) -> Bool {
        let newV = (try? String(contentsOf: newApp.appendingPathComponent("Contents/Resources/helper-version"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !newV.isEmpty else { return false }
        let installed = (try? String(contentsOfFile: "/usr/local/libexec/wm-fanhelper.version", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return newV != installed
    }

    /// Değiştirme betiği: $1=PID $2=yeni .app $3=hedef $4=yardımcı güncellensin mi (1/0)
    static let swapScript = """
        #!/bin/bash
        # Workstation güncelleme: uygulama kapanınca değiştir, karantinayı kaldır, yeniden aç.
        PID="$1"; NEW="$2"; DEST="$3"; HELPER="$4"; USER_NAME="$(id -un)"
        LOG="$HOME/Library/Logs/Workstation.log"
        log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Güncelleyici: $*" >> "$LOG"; }
        for i in $(seq 1 120); do kill -0 "$PID" 2>/dev/null || break; sleep 0.5; done
        BACKUP="$DEST.eski-$$"
        swap() {
          mv "$DEST" "$BACKUP" || return 1
          if /usr/bin/ditto "$NEW" "$DEST"; then rm -rf "$BACKUP"; else rm -rf "$DEST"; mv "$BACKUP" "$DEST"; return 1; fi
        }
        if swap 2>/dev/null; then
          log "uygulama değiştirildi"
        else
          log "yetki gerekiyor, yönetici olarak değiştiriliyor"
          /usr/bin/osascript -e "do shell script \\"mv '$DEST' '$BACKUP' && /usr/bin/ditto '$NEW' '$DEST' && rm -rf '$BACKUP' && chown -R $USER_NAME:staff '$DEST'\\" with administrator privileges" \\
            || { [[ -d "$BACKUP" && ! -d "$DEST" ]] && mv "$BACKUP" "$DEST"; log "değiştirilemedi, eski sürüm geri yüklendi"; open "$DEST"; exit 1; }
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        # Eski adla kurulmuş kopya ve giriş öğesi (WorkstationMode → Workstation)
        if [[ -d /Applications/WorkstationMode.app && "$DEST" != /Applications/WorkstationMode.app ]]; then
          rm -rf /Applications/WorkstationMode.app 2>/dev/null && log "eski WorkstationMode.app kaldırıldı"
          /usr/bin/osascript -e 'tell application "System Events" to delete (every login item whose name is "WorkstationMode")' >/dev/null 2>&1
        fi
        if [[ "$HELPER" == "1" ]]; then
          log "fan yardımcısı güncelleniyor"
          sudo -n "$DEST/Contents/Resources/install-helper.sh" "$DEST" "$USER_NAME" >/dev/null 2>&1 || \\
          /usr/bin/osascript -e "do shell script quoted form of \\"$DEST/Contents/Resources/install-helper.sh\\" & \\" \\" & quoted form of \\"$DEST\\" & \\" $USER_NAME\\" with administrator privileges" >/dev/null 2>&1 \\
            || log "fan yardımcısı güncellenemedi (kurulumu tekrar çalıştırabilirsin)"
        fi
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1
        open "$DEST"
        log "yeni sürüm açıldı"
        """

    /// Uygulama kapandıktan sonra değiştirip yeniden açan betiği başlatır. Çağıran hemen ardından uygulamayı kapatmalı.
    func launchSwap(newApp: URL, destination: String = "/Applications/Workstation.app") throws {
        let helper = Self.helperChanged(newApp: newApp) ? "1" : "0"
        let script = newApp.deletingLastPathComponent().appendingPathComponent("swap.sh")
        let text = Self.swapScript
        try text.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "nohup /bin/bash \"$0\" \"$1\" \"$2\" \"$3\" \"$4\" >/dev/null 2>&1 &",
                       script.path, String(ProcessInfo.processInfo.processIdentifier), newApp.path, destination, helper]
        try p.run()
        p.waitUntilExit()
    }
}
