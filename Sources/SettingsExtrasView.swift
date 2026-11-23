import SwiftUI
import AppKit

// Ayarlar sayfasındaki 1.7.0 kartları. Makro yok: durum PanelModel'de (@Published), görünümler küçük.

/// Simge + başlık + alt başlık satırı (kart başlığı).
struct CardTitleRow: View {
    let icon: String
    let title: String
    let subtitle: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 18).foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                if let s = subtitle {
                    Text(s).font(.system(size: 10)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
    }
}

/// Küçük anahtar satırı.
struct ToggleRow: View {
    let title: String
    let isOn: Binding<Bool>

    var body: some View {
        Toggle(isOn: isOn) {
            Text(title).font(.system(size: 11))
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }
}

// MARK: - Otomatik mod geçişi

struct AutoSwitchCard: View {
    @ObservedObject var model: PanelModel

    private func binding<T>(_ path: WritableKeyPath<AutoSwitchSettings, T>) -> Binding<T> {
        let m: PanelModel = model
        return Binding<T>(get: { m.autoSwitch[keyPath: path] },
                          set: { v in
                              var s = m.autoSwitch
                              s[keyPath: path] = v
                              m.onAutoSwitch(s)
                          })
    }

    var body: some View {
        let s: AutoSwitchSettings = model.autoSwitch
        return VStack(alignment: .leading, spacing: 8) {
            CardTitleRow(icon: "dot.radiowaves.left.and.right", title: "Otomatik mod geçişi",
                         subtitle: "Biri uzaktan bağlanınca Remote açılır, bağlantı bitince seçtiğin moda dönülür")
            ToggleRow(title: "Uzaktan bağlanınca Remote'a geç", isOn: binding(\.enabled))
            if s.enabled {
                ToggleRow(title: "Terminal (SSH) bağlantılarını da say", isOn: binding(\.includeSSH))
                AutoSwitchAfterRow(model: model, after: binding(\.after), minutes: binding(\.idleMinutes))
                Text(model.autoSwitchStatus)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .cardStyle()
    }
}

private struct AutoSwitchAfterRow: View {
    @ObservedObject var model: PanelModel
    let after: Binding<AfterRemoteAction>
    let minutes: Binding<Int>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Oturum bitince").font(.system(size: 11))
                Spacer()
                Picker("", selection: after) {
                    ForEach(AfterRemoteAction.allCases) { (a: AfterRemoteAction) in Text(a.title).tag(a) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
            }
            if model.autoSwitch.after != .none {
                HStack {
                    Text("Bekleme: \(model.autoSwitch.idleMinutes) dk").font(.system(size: 11))
                    Spacer()
                    Stepper("", value: minutes, in: 1...240, step: 5).labelsHidden()
                }
            }
        }
    }
}

// MARK: - Zamanlanmış modlar

struct ScheduleCard: View {
    @ObservedObject var model: PanelModel

    private var wakeBinding: Binding<Bool> {
        let m: PanelModel = model
        return Binding<Bool>(get: { m.schedule.wakeEnabled }, set: { v in
            var s = m.schedule
            s.wakeEnabled = v
            m.onSchedule(s)
        })
    }

    private func addRule() {
        var s = model.schedule
        var r = ScheduleRule()
        r.hour = 23
        r.minute = 30
        r.mode = .sleep
        s.rules.append(r)
        model.onSchedule(s)
    }

    var body: some View {
        let rules: [ScheduleRule] = model.schedule.rules
        return VStack(alignment: .leading, spacing: 8) {
            CardTitleRow(icon: "calendar.badge.clock", title: "Zamanlanmış modlar",
                         subtitle: "Seçtiğin gün ve saatlerde mod kendiliğinden değişir")
            ForEach(rules) { (r: ScheduleRule) in
                ScheduleRuleRow(model: model, rule: r)
                Divider().opacity(0.2)
            }
            HStack {
                Button(action: addRule) {
                    Label("Kural ekle", systemImage: "plus.circle")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                Spacer()
                Text(model.scheduleNext).font(.system(size: 10)).foregroundColor(.secondary)
            }
            ToggleRow(title: "Mac uyuyorsa o saatten biraz önce uyandır", isOn: wakeBinding)
        }
        .cardStyle()
    }
}

private struct ScheduleRuleRow: View {
    @ObservedObject var model: PanelModel
    let rule: ScheduleRule

    private func update(_ change: @escaping (inout ScheduleRule) -> Void) {
        var s = model.schedule
        guard let i = s.rules.firstIndex(where: { $0.id == rule.id }) else { return }
        change(&s.rules[i])
        model.onSchedule(s)
    }

    private var enabled: Binding<Bool> {
        Binding<Bool>(get: { rule.enabled }, set: { v in update { $0.enabled = v } })
    }

    private var time: Binding<Date> {
        let r: ScheduleRule = rule
        return Binding<Date>(
            get: { Calendar.current.date(bySettingHour: r.hour, minute: r.minute, second: 0, of: Date()) ?? Date() },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                update { $0.hour = c.hour ?? 0; $0.minute = c.minute ?? 0 }
            })
    }

    private var mode: Binding<WorkMode> {
        Binding<WorkMode>(get: { rule.mode }, set: { v in update { $0.mode = v } })
    }

    private func delete() {
        var s = model.schedule
        s.rules.removeAll { $0.id == rule.id }
        model.onSchedule(s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("", isOn: enabled).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                DatePicker("", selection: time, displayedComponents: [.hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .frame(width: 70)
                Picker("", selection: mode) {
                    Text("Masaüstü").tag(WorkMode.desktop)
                    Text("Uyku").tag(WorkMode.sleep)
                    Text("Remote").tag(WorkMode.remote)
                }
                .labelsHidden()
                .frame(width: 100)
                Spacer()
                Button(action: delete) {
                    Image(systemName: "trash").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Kuralı sil")
            }
            WeekdayStrip(rule: rule, toggle: { day in
                update { r in
                    if let i = r.weekdays.firstIndex(of: day) { r.weekdays.remove(at: i) } else { r.weekdays.append(day) }
                }
            })
        }
        .opacity(rule.enabled ? 1 : 0.5)
    }
}

private struct WeekdayStrip: View {
    let rule: ScheduleRule
    let toggle: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ScheduleRule.orderedWeekdays, id: \.self) { (day: Int) in
                WeekdayChip(title: ScheduleRule.shortName(day), on: rule.weekdays.contains(day), action: { toggle(day) })
            }
        }
    }
}

private struct WeekdayChip: View {
    let title: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        let fill: Color = on ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.06)
        return Button(action: action) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 34, height: 18)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(fill))
                .foregroundColor(on ? .white : .secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Ses

struct AudioCard: View {
    @ObservedObject var model: PanelModel

    private var binding: Binding<Bool> {
        let m: PanelModel = model
        return Binding<Bool>(get: { m.muteInRemote }, set: { m.onMuteInRemote($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitleRow(icon: "speaker.slash", title: "Ses",
                         subtitle: "Remote'tayken Mac'in sesi kısılır, Masaüstüne dönünce geri gelir")
            ToggleRow(title: "Remote'ta sesi kapat", isOn: binding)
        }
        .cardStyle()
    }
}

// MARK: - Bildirimler

struct NotificationsCard: View {
    @ObservedObject var model: PanelModel

    private func binding(_ path: WritableKeyPath<NotificationSettings, Bool>) -> Binding<Bool> {
        let m: PanelModel = model
        return Binding<Bool>(get: { m.notifySettings[keyPath: path] }, set: { v in
            var s = m.notifySettings
            s[keyPath: path] = v
            m.onNotifySettings(s)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitleRow(icon: "bell.badge", title: "Bildirimler",
                         subtitle: "Önemli bir şey olunca Mac'te bildirim gelir")
            ToggleRow(title: "Mac çok ısınırsa", isOn: binding(\.overheat))
            ToggleRow(title: "Disk dolmak üzereyse", isOn: binding(\.lowDisk))
            ToggleRow(title: "Uygulama beklenmedik şekilde kapandıysa", isOn: binding(\.unexpectedExit))
        }
        .cardStyle()
    }
}
