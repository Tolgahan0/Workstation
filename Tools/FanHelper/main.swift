import Foundation

// wm-fanhelper — WorkstationMode fan yardımcısı (root olarak sudo ile çalışır).
// Kabul edilen komutlar YALNIZCA:
//   status                         → JSON durum
//   set <fanIndex|all> auto|half|max
//   reset                          → tüm fanlar otomatik, Ftst=0
// Başka hiçbir anahtar yazılmaz; hedef her zaman fanın [Mn, Mx] aralığına sıkıştırılır.
// Sources/SMC.swift ile birlikte derlenir.

func printJSON<T: Encodable>(_ value: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    if let data = try? enc.encode(value), let s = String(data: data, encoding: .utf8) { print(s) }
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

struct SetResult: Codable {
    var ok: Bool
    var mode: String
    var targets: [String: Double]
    var errors: [String]
}

let args = Array(CommandLine.arguments.dropFirst())
let usage = "Kullanım: wm-fanhelper status | set <fanIndex|all> auto|half|max | reset"

guard let command = args.first else { fail(usage, code: 2) }

#if os(macOS)
func openSMC() -> FanSMC {
    do { return try FanSMC() } catch { fail("SMC açılamadı: \(error)") }
}
let fans: FanSMC = openSMC()

switch command {
case "status":
    guard args.count == 1 else { fail(usage, code: 2) }
    printJSON(fans.status())

case "reset":
    guard args.count == 1 else { fail(usage, code: 2) }
    let errors = fans.resetAll()
    printJSON(SetResult(ok: errors.isEmpty, mode: "auto", targets: [:], errors: errors))
    exit(errors.isEmpty ? 0 : 1)

case "set":
    guard args.count == 3, let mode = FanMode(rawValue: args[2]) else { fail(usage, code: 2) }
    let count = fans.fanCount
    guard count > 0 else { fail("Bu Mac'te fan yok", code: 3) }
    let indices: [Int]
    if args[1] == "all" {
        indices = Array(0..<count)
    } else if let i = Int(args[1]), i >= 0, i < count {
        indices = [i]
    } else {
        fail("Geçersiz fan: \(args[1]) (0…\(count - 1) veya all)", code: 2)
    }
    var targets: [String: Double] = [:]
    var errors: [String] = []
    for i in indices {
        do {
            if let t = try fans.apply(mode, fan: i) { targets["F\(i)"] = t }
        } catch {
            errors.append("F\(i): \(error)")
        }
    }
    if !errors.isEmpty && mode != .auto {
        // Güvenlik: yarım kalan manuel durum bırakma.
        errors += fans.resetAll()
    } else if mode == .auto {
        errors += fans.resetAll()
    }
    printJSON(SetResult(ok: errors.isEmpty, mode: mode.rawValue, targets: targets, errors: errors))
    exit(errors.isEmpty ? 0 : 1)

default:
    fail(usage, code: 2)
}
#else
fail("Yalnızca macOS", code: 4)
#endif
