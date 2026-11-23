import Foundation

/// Profilde bir monitörün durumu.
struct ProfileMonitorState: Codable, Equatable {
    var enabled: Bool
    var brightness: Double?
    var name: String
}

/// Adlandırılmış çalışma alanı profili: monitör başına aç/kapa + parlaklık + fan modu.
/// (Pencere yerleşimi bilinçli olarak kaydedilmez.)
struct WorkspaceProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var monitors: [String: ProfileMonitorState]
    var fanMode: FanMode?
    var created = Date()

    var summary: String {
        let on = monitors.values.filter { $0.enabled }.count
        var parts = ["\(on)/\(monitors.count) monitör açık"]
        if let f = fanMode { parts.append("fan \(f.title)") }
        return parts.joined(separator: " · ")
    }

    static func make(name: String, desired: [String: DesiredMonitorState], fanMode: FanMode?) -> WorkspaceProfile {
        var m: [String: ProfileMonitorState] = [:]
        for (k, s) in desired {
            m[k] = ProfileMonitorState(enabled: s.enabled, brightness: s.brightness, name: s.name)
        }
        return WorkspaceProfile(name: name, monitors: m, fanMode: fanMode)
    }
}

enum ProfileStore {
    static let key = "workspaceProfiles"

    static func load(_ d: UserDefaults = .standard) -> [WorkspaceProfile] {
        guard let data = d.data(forKey: key),
              let list = try? JSONDecoder().decode([WorkspaceProfile].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [WorkspaceProfile], _ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(list) { d.set(data, forKey: key) }
    }

    /// URL/CLI için ad karşılaştırması: büyük/küçük harf, aksan, boşluk/-/_ farkı yok sayılır.
    static func normalized(_ s: String) -> String {
        // Türkçe noktasız/noktalı i aksan sayılmadığından elle eşlenir (ı/İ → i).
        let mapped = s.lowercased().replacingOccurrences(of: "ı", with: "i")
        let folded = mapped.folding(options: [.diacriticInsensitive], locale: nil)
        return String(folded.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    static func find(_ name: String, in list: [WorkspaceProfile]) -> WorkspaceProfile? {
        let n = normalized(name)
        guard !n.isEmpty else { return nil }
        return list.first { normalized($0.name) == n }
    }

    /// Aynı adlı profil varsa üzerine yazar (kimliği korur), yoksa ekler.
    static func upsert(_ p: WorkspaceProfile, into list: [WorkspaceProfile]) -> [WorkspaceProfile] {
        var out = list
        if let i = out.firstIndex(where: { normalized($0.name) == normalized(p.name) }) {
            var q = p
            q.id = out[i].id
            out[i] = q
        } else {
            out.append(p)
        }
        return out
    }
}
