import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Güncelleyici — saf parçalar (Linux'ta test edilir): sürüm karşılaştırma, GitHub yanıtı, latest.json.

struct SemVer: Comparable, CustomStringConvertible {
    var major: Int, minor: Int, patch: Int
    var pre: [String]

    init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        if let plus = s.firstIndex(of: "+") { s = String(s[..<plus]) }
        var preText = ""
        if let dash = s.firstIndex(of: "-") {
            preText = String(s[s.index(after: dash)...])
            s = String(s[..<dash])
        }
        let nums = s.split(separator: ".").map { Int($0) }
        guard !nums.isEmpty, nums.count <= 3, nums.allSatisfy({ $0 != nil }) else { return nil }
        let n = nums.map { $0! }
        major = n[0]; minor = n.count > 1 ? n[1] : 0; patch = n.count > 2 ? n[2] : 0
        pre = preText.isEmpty ? [] : preText.split(separator: ".").map(String.init)
    }

    var isPrerelease: Bool { !pre.isEmpty }
    var description: String { "\(major).\(minor).\(patch)" + (pre.isEmpty ? "" : "-" + pre.joined(separator: ".")) }

    static func < (a: SemVer, b: SemVer) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        if a.patch != b.patch { return a.patch < b.patch }
        // Ön sürüm, aynı numaralı kararlı sürümden küçüktür.
        if a.pre.isEmpty != b.pre.isEmpty { return !a.pre.isEmpty }
        for (x, y) in zip(a.pre, b.pre) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): return i < j
            case (_?, nil): return true
            case (nil, _?): return false
            default: return x < y
            }
        }
        return a.pre.count < b.pre.count
    }

    static func == (a: SemVer, b: SemVer) -> Bool { !(a < b) && !(b < a) }
}

struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        var name: String
        var url: String                    // API adresi (özel depo + token: Accept: application/octet-stream)
        var browser_download_url: String
        var size: Int?
    }
    var tag_name: String
    var name: String?
    var body: String?
    var draft: Bool?
    var prerelease: Bool?
    var html_url: String?
    var assets: [Asset]

    var version: SemVer? { SemVer(tag_name) }
    func asset(named n: String) -> Asset? { assets.first { $0.name == n } }
    var zipAsset: Asset? { assets.first { $0.name.hasPrefix("Workstation-") && $0.name.hasSuffix(".zip") } }
}

struct UpdateManifest: Decodable, Equatable {
    var version: String
    var build: String?
    var zip_name: String?
    var zip_url: String?
    var dmg_url: String?
    var sha256: String
    var helper_version: String?
    var notes: String?
}

struct UpdateSettings: Codable, Equatable {
    /// false = sadece haber ver (varsayılan)
    var autoInstall = false
    var beta = false
    var repo = "Tolgahan0/Workstation"

    static let key = "updateSettings"
    static let canonicalRepo = "Tolgahan0/Workstation"
    static func load(_ d: UserDefaults = .standard) -> UpdateSettings {
        guard let data = d.data(forKey: key), var s = try? JSONDecoder().decode(UpdateSettings.self, from: data) else { return UpdateSettings() }
        // Depo adı değişti (workstation → Workstation): yönlendirme çalışsa da asıl adı kullan.
        if s.repo.lowercased() == canonicalRepo.lowercased() { s.repo = canonicalRepo }
        return s
    }
    func save(_ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key) }
    }
}

enum UpdatePolicy {
    /// Açılışta + saatte bir (tek zamanlayıcı, yoklama yok).
    static let checkInterval: TimeInterval = 3600

    /// Aynı sürüm için yalnızca bir kez bildirim.
    static func shouldNotify(version: String, lastNotified: String?) -> Bool { version != lastNotified }

    /// Test/geliştirme: UserDefaults "updateFeedURL" ya da WORKSTATION_UPDATE_FEED → doğrudan bir latest.json.
    static func feedOverride(_ d: UserDefaults = .standard, env: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let raw = env["WORKSTATION_UPDATE_FEED"] ?? d.string(forKey: "updateFeedURL")
        guard let r = raw?.trimmingCharacters(in: .whitespaces), !r.isEmpty else { return nil }
        if r.hasPrefix("/") { return URL(fileURLWithPath: r) }
        return URL(string: r)
    }

    /// Yayın listesinden kurulacak en yeni sürüm (taslaklar hariç; beta kapalıysa ön sürümler hariç).
    static func pick(_ releases: [GitHubRelease], current: SemVer, beta: Bool) -> GitHubRelease? {
        releases
            .filter { $0.draft != true }
            .filter { beta || ($0.prerelease != true && $0.version?.isPrerelease == false) }
            .compactMap { r in r.version.map { (r, $0) } }
            .filter { $0.1 > current }
            .max { $0.1 < $1.1 }?.0
    }

    static func isValidSHA256(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { $0.isHexDigit }
    }

    /// Sürüm notlarını panel için kısalt (Markdown başlıkları/işaretleri sadeleştirilir).
    static func shortNotes(_ text: String?, maxLines: Int = 12) -> String {
        guard let t = text, !t.isEmpty else { return "" }
        let lines = t.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("**Kurulum") }
            .map { l -> String in
                var x = l
                while x.hasPrefix("#") { x.removeFirst() }
                if x.hasPrefix("- ") || x.hasPrefix("* ") { x = "• " + x.dropFirst(2) }
                return x.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
        let head = lines.prefix(maxLines).joined(separator: "\n")
        return lines.count > maxLines ? head + "\n…" : head
    }
}
