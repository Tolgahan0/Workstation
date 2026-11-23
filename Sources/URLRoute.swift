import Foundation

/// workstation:// URL yolları (Kestirmeler › "URL'yi Aç" ile kullanılabilir).
///   workstation://remote[?res=WxH|preset=mbp14] · workstation://sleep · workstation://desktop
///   workstation://profile/<ad>
///   workstation://fan/auto|half|max
///   workstation://keepawake/on|off[?hours=2|minutes=90] · workstation://keepawake/3h
enum URLRoute: Equatable {
    case mode(WorkMode, resolution: String?)
    case profile(String)
    case fan(FanMode)
    case keepAwake(on: Bool, seconds: TimeInterval?)

    static func parse(_ str: String, scheme: String = "workstation") -> URLRoute? {
        let full = str.contains("://") ? str : "\(scheme)://\(str)"
        guard let comps = URLComponents(string: full) ?? URLComponents(string: full.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") else {
            return nil
        }
        let host = (comps.host ?? "").lowercased()
        let pathParts = comps.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        let query = comps.queryItems ?? []
        func q(_ name: String) -> String? { query.first { $0.name.lowercased() == name }?.value }

        switch host {
        case "profile", "profil":
            guard let name = pathParts.first ?? q("name"), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return .profile(pathParts.isEmpty ? name : pathParts.joined(separator: "/"))
        case "fan":
            guard let raw = pathParts.first ?? q("mode"), let m = fanMode(raw) else { return nil }
            return .fan(m)
        case "keepawake", "awake", "uyanik":
            let arg = (pathParts.first ?? "on").lowercased()
            if arg == "off" || arg == "false" || arg == "kapat" { return .keepAwake(on: false, seconds: nil) }
            if let h = q("hours").flatMap(Double.init), h > 0 { return .keepAwake(on: true, seconds: h * 3600) }
            if let m = q("minutes").flatMap(Double.init), m > 0 { return .keepAwake(on: true, seconds: m * 60) }
            guard let secs = KeepAwake.Duration.seconds(argument: arg) else { return nil }
            return .keepAwake(on: true, seconds: secs)
        default:
            var candidate = host
            if candidate.isEmpty || candidate == "mode" { candidate = pathParts.last ?? "" }
            guard let mode = WorkMode(argument: candidate) else { return nil }
            var res: String?
            for item in query {
                guard let v = item.value else { continue }
                if item.name == "res" { res = RemotePreset.normalize(v) }
                if item.name == "preset", let p = RemotePreset.preset(id: v.lowercased()), p.id != "auto" { res = p.resolution }
            }
            return .mode(mode, resolution: res)
        }
    }

    static func fanMode(_ raw: String) -> FanMode? {
        switch raw.lowercased() {
        case "auto", "otomatik", "system": return .auto
        case "half", "yarim", "yarım", "50": return .half
        case "max", "full", "fullblast", "full-blast", "blast": return .max
        default: return nil
        }
    }
}
