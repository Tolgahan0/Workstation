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
/// Genişlik sabit: metin satıra sığmazsa alta kayar, anahtar hep sağda durur (açıp kapatınca kart genişliği değişmez).
struct ToggleRow: View {
    let title: String
    let isOn: Binding<Bool>
    var disabled: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .fixedSize()
        }
        .frame(maxWidth: .infinity)
        .opacity(disabled ? 0.45 : 1)
        .disabled(disabled)
        .transaction { $0.animation = nil }
    }
}

/// Kart içindeki ikincil açıklama metni: her zaman sarar, genişlik istemez.
struct NoteText: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            CardTitleRow(icon: "dot.radiowaves.left.and.right", title: L("Otomatik mod geçişi"),
                         subtitle: L("Biri uzaktan bağlanınca Remote açılır, bağlantı bitince seçtiğin moda dönülür"))
            ToggleRow(title: L("Uzaktan bağlanınca Remote'a geç"), isOn: binding(\.enabled))
            if s.enabled {
                ToggleRow(title: L("Terminal (SSH) bağlantılarını da say"), isOn: binding(\.includeSSH))
                AutoSwitchAfterRow(model: model, after: binding(\.after), minutes: binding(\.idleMinutes))
                NoteText(text: model.autoSwitchStatus)
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
            Text(L("Oturum bitince")).font(.system(size: 11))
            Picker("", selection: after) {
                ForEach(AfterRemoteAction.allCases) { (a: AfterRemoteAction) in Text(a.title).tag(a) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            HStack {
                Text(L("Bekleme: %@ dk", model.autoSwitch.idleMinutes)).font(.system(size: 11)).monospacedDigit()
                Spacer(minLength: 8)
                Stepper("", value: minutes, in: 1...240, step: 5).labelsHidden().fixedSize()
            }
            .opacity(model.autoSwitch.after == .none ? 0.45 : 1)
            .disabled(model.autoSwitch.after == .none)
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
            CardTitleRow(icon: "calendar.badge.clock", title: L("Zamanlanmış modlar"),
                         subtitle: L("Seçtiğin gün ve saatlerde mod kendiliğinden değişir"))
            ForEach(rules) { (r: ScheduleRule) in
                ScheduleRuleRow(model: model, rule: r)
                Divider().opacity(0.2)
            }
            HStack(alignment: .firstTextBaseline) {
                Button(action: addRule) {
                    Label(L("Kural ekle"), systemImage: "plus.circle")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .fixedSize()
                Spacer(minLength: 8)
                Text(model.scheduleNext).font(.system(size: 10)).foregroundColor(.secondary)
                    .lineLimit(2).multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ToggleRow(title: L("Mac uyuyorsa o saatten biraz önce uyandır"), isOn: wakeBinding,
                      disabled: !rules.contains { $0.enabled && $0.mode != .sleep })
            if model.schedule.wakeEnabled && !rules.contains(where: { $0.enabled && $0.mode != .sleep }) {
                NoteText(text: L("Planlı uyanma için etkin bir Masaüstü ya da Remote kuralı gerekir."))
            }
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
        let on: Bool = rule.enabled
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("", isOn: enabled).labelsHidden().toggleStyle(.switch).controlSize(.mini).fixedSize()
                    .help(on ? L("Kuralı kapat") : L("Kuralı aç"))
                DatePicker("", selection: time, displayedComponents: [.hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .frame(width: 70)
                    .disabled(!on)
                Picker("", selection: mode) {
                    Text(L("Masaüstü")).tag(WorkMode.desktop)
                    Text(L("Uyku")).tag(WorkMode.sleep)
                    Text("Remote").tag(WorkMode.remote)
                }
                .labelsHidden()
                .frame(width: 100)
                .disabled(!on)
                Spacer(minLength: 4)
                if !on {
                    Text(L("Kapalı")).font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                        .foregroundColor(.secondary)
                        .fixedSize()
                }
                Button(action: delete) {
                    Image(systemName: "trash").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help(L("Kuralı sil"))
            }
            WeekdayStrip(rule: rule, toggle: { day in
                update { r in
                    if let i = r.weekdays.firstIndex(of: day) { r.weekdays.remove(at: i) } else { r.weekdays.append(day) }
                }
            })
            .disabled(!on)
        }
        .opacity(on ? 1 : 0.4)
        .saturation(on ? 1 : 0)
        .transaction { $0.animation = nil }
    }
}

private struct WeekdayStrip: View {
    let rule: ScheduleRule
    let toggle: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ScheduleRule.orderedWeekdays, id: \.self) { (day: Int) in
                WeekdayChip(title: ScheduleRule.shortName(day), on: rule.enabled && rule.weekdays.contains(day),
                            selected: rule.weekdays.contains(day), action: { toggle(day) })
            }
        }
    }
}

private struct WeekdayChip: View {
    let title: String
    /// Etkin kuralda seçili gün (mavi).
    let on: Bool
    /// Seçili gün (kural kapalıyken gri gösterilir).
    var selected: Bool = false
    let action: () -> Void

    var body: some View {
        let fill: Color = on ? Color.accentColor.opacity(0.85) : (selected ? Color.white.opacity(0.16) : Color.white.opacity(0.06))
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
            CardTitleRow(icon: "speaker.slash", title: L("Ses"),
                         subtitle: L("Remote'tayken Mac'in sesi kısılır, Masaüstüne dönünce geri gelir"))
            ToggleRow(title: L("Remote'ta sesi kapat"), isOn: binding)
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
            CardTitleRow(icon: "bell.badge", title: L("Bildirimler"),
                         subtitle: L("Önemli bir şey olunca Mac'te bildirim gelir"))
            ToggleRow(title: L("Mac çok ısınırsa"), isOn: binding(\.overheat))
            ToggleRow(title: L("Disk dolmak üzereyse"), isOn: binding(\.lowDisk))
            ToggleRow(title: L("Uygulama beklenmedik şekilde kapandıysa"), isOn: binding(\.unexpectedExit))
        }
        .cardStyle()
    }
}
