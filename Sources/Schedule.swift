import Foundation

extension WorkMode: Codable {}

/// Zamanlanmış mod kuralı: saat:dakika, haftanın günleri, mod.
struct ScheduleRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var enabled = true
    var hour = 23
    var minute = 0
    /// Calendar.weekday değerleri (1 = Pazar … 7 = Cumartesi).
    var weekdays: [Int] = [1, 2, 3, 4, 5, 6, 7]
    var mode: WorkMode = .sleep

    var timeText: String { String(format: "%02d:%02d", hour, minute) }

    /// Pazartesi'den başlayan sıralama ve kısa adlar.
    static let orderedWeekdays: [Int] = [2, 3, 4, 5, 6, 7, 1]
    static func shortName(_ weekday: Int) -> String {
        switch weekday {
        case 1: return L("Paz")
        case 2: return L("Pzt")
        case 3: return L("Sal")
        case 4: return L("Çar")
        case 5: return L("Per")
        case 6: return L("Cum")
        case 7: return L("Cmt")
        default: return "?"
        }
    }

    var daysText: String {
        let set = Set(weekdays)
        if set.count == 7 { return L("Her gün") }
        if set == [2, 3, 4, 5, 6] { return L("Hafta içi") }
        if set == [1, 7] { return L("Hafta sonu") }
        if set.isEmpty { return L("Gün seçilmedi") }
        return Self.orderedWeekdays.filter { set.contains($0) }.map(Self.shortName).joined(separator: " ")
    }
}

struct ScheduleSettings: Codable, Equatable {
    var rules: [ScheduleRule] = []
    /// `pmset repeat wakeorpoweron`: ilk (Uyku olmayan) kuraldan 2 dk önce Mac'i uyandır.
    var wakeEnabled = false

    static let key = "scheduleSettings"

    static func load(_ d: UserDefaults = .standard) -> ScheduleSettings {
        guard let data = d.data(forKey: key), let s = try? JSONDecoder().decode(ScheduleSettings.self, from: data) else {
            return ScheduleSettings()
        }
        return s
    }

    func save(_ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key) }
    }
}

/// Saf zamanlama hesapları (Linux'ta test edilir).
enum ScheduleEngine {
    /// `after`'dan KESİNLİKLE sonraki ilk tetiklenme.
    static func nextFire(after: Date, rules: [ScheduleRule], calendar: Calendar = .current) -> (date: Date, rule: ScheduleRule)? {
        var best: (date: Date, rule: ScheduleRule)?
        let startOfDay = calendar.startOfDay(for: after)
        for rule in rules where rule.enabled && !rule.weekdays.isEmpty {
            for dayOffset in 0...7 {
                guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfDay),
                      calendar.component(.weekday, from: day) != 0,
                      rule.weekdays.contains(calendar.component(.weekday, from: day)),
                      let fire = calendar.date(bySettingHour: rule.hour, minute: rule.minute, second: 0, of: day),
                      fire > after else { continue }
                if best == nil || fire < best!.date { best = (fire, rule) }
                break
            }
        }
        return best
    }

    /// (from, to] aralığında tetiklenmesi gereken kurallar (zamana göre sıralı).
    static func due(from: Date, to: Date, rules: [ScheduleRule], calendar: Calendar = .current) -> [(date: Date, rule: ScheduleRule)] {
        var out: [(date: Date, rule: ScheduleRule)] = []
        var cursor = from
        while let n = nextFire(after: cursor, rules: rules, calendar: calendar), n.date <= to {
            // Aynı dakikadaki diğer kurallar da gelsin.
            for r in rules where r.enabled && r.id != n.rule.id {
                if r.hour == n.rule.hour && r.minute == n.rule.minute,
                   r.weekdays.contains(calendar.component(.weekday, from: n.date)),
                   !out.contains(where: { $0.rule.id == r.id && $0.date == n.date }) {
                    out.append((n.date, r))
                }
            }
            out.append(n)
            cursor = n.date
            if out.count > 50 { break }
        }
        return out
    }

    /// pmset gün harfleri: M T W R F S U.
    static func pmsetLetter(_ weekday: Int) -> String {
        switch weekday {
        case 1: return "U"
        case 2: return "M"
        case 3: return "T"
        case 4: return "W"
        case 5: return "R"
        case 6: return "F"
        case 7: return "S"
        default: return ""
        }
    }

    /// `pmset repeat wakeorpoweron <günler> <SS:DD:00>` argümanları. Uyku olmayan etkin kurallardan
    /// günün en erken saatlisi seçilir (pmset tek bir tekrar eden uyanma tutar); 2 dk önce uyandırır.
    /// nil = uygun kural yok (→ `pmset repeat cancel`).
    static func pmsetRepeatArgs(rules: [ScheduleRule], leadMinutes: Int = 2) -> [String]? {
        let candidates = rules.filter { $0.enabled && $0.mode != .sleep && !$0.weekdays.isEmpty }
        guard let first = candidates.min(by: { ($0.hour * 60 + $0.minute) < ($1.hour * 60 + $1.minute) }) else { return nil }
        let sameTime = candidates.filter { $0.hour == first.hour && $0.minute == first.minute }
        var days = Set(sameTime.flatMap { $0.weekdays })
        var total = first.hour * 60 + first.minute - leadMinutes
        if total < 0 {
            // Gece yarısını geçer: bir önceki güne kaydır.
            total += 24 * 60
            days = Set(days.map { $0 == 1 ? 7 : $0 - 1 })
        }
        let letters = [2, 3, 4, 5, 6, 7, 1].filter { days.contains($0) }.map(pmsetLetter).joined()
        let time = String(format: "%02d:%02d:00", total / 60, total % 60)
        return ["repeat", "wakeorpoweron", letters, time]
    }
}
