import SwiftUI
import AppKit

// Ayarlar › Disk temizliği: otomatik mod, dokunma listesi, ek proje klasörleri. Makro yok.

// MARK: - Ayarlar kartı

struct CleanerSettingsCard: View {
    @ObservedObject var cleaner: CleanerModel

    private func binding<T>(_ path: WritableKeyPath<CleanerSettings, T>) -> Binding<T> {
        let c = cleaner
        return Binding<T>(get: { c.settings[keyPath: path] }, set: { v in c.update { $0[keyPath: path] = v } })
    }

    var body: some View {
        let s: CleanerSettings = cleaner.settings
        return VStack(alignment: .leading, spacing: 8) {
            CardTitleRow(icon: "sparkles", title: L("Otomatik disk temizliği"),
                         subtitle: L("Sadece en güvenli kalemler; kullanılan hiçbir şeye dokunulmaz"))
            ToggleRow(title: L("Otomatik temizlik"), isOn: binding(\.autoEnabled))
            if s.autoEnabled {
                ToggleRow(title: L("Her gün belirli saatte"), isOn: binding(\.autoDaily))
                if s.autoDaily { AutoTimeRow(cleaner: cleaner) }
                ToggleRow(title: L("Disk dolmaya başlayınca"), isOn: binding(\.autoLowSpace))
                if s.autoLowSpace {
                    StepperRow(label: L("Boş alan %@ GB'ın altına inince", s.autoLowSpaceGB), value: binding(\.autoLowSpaceGB), range: 0...500, step: 5)
                    StepperRow(label: L("ya da %%@'in altına inince", s.autoLowSpacePercent), value: binding(\.autoLowSpacePercent), range: 0...50, step: 1)
                }
                NoteText(text: L("Mac meşgulken ya da pil azken beklenir."))
                AutoCategoryList(cleaner: cleaner)
            }
            Divider().opacity(0.2)
            PathListEditor(cleaner: cleaner, title: L("Asla dokunma"), hint: L("Bu klasörler ve içindekiler hiç silinmez"),
                           list: \.neverTouch, newValue: \.newNeverTouch)
            PathListEditor(cleaner: cleaner, title: L("Ek proje klasörleri"), hint: L("Ev klasörü zaten taranır; başka disk ya da klasör ekleyebilirsin"),
                           list: \.extraRoots, newValue: \.newRoot)
        }
        .cardStyle()
    }
}

// MARK: - Tools › Otomatik temizlik kartı (hızlı ayar)

struct AutoCleanQuickCard: View {
    @ObservedObject var cleaner: CleanerModel
    let openSettings: () -> Void

    private func binding<T>(_ path: WritableKeyPath<CleanerSettings, T>) -> Binding<T> {
        let c = cleaner
        return Binding<T>(get: { c.settings[keyPath: path] }, set: { v in c.update { $0[keyPath: path] = v } })
    }

    private var summary: String {
        let s = cleaner.settings
        guard s.autoEnabled else { return L("Kapalı · açınca sadece en güvenli kalemler temizlenir") }
        var parts: [String] = []
        if s.autoDaily { parts.append(L("her gün %@", String(format: "%02d:%02d", s.autoHour, s.autoMinute))) }
        if s.autoLowSpace { parts.append(L("boş alan %@ GB altına inince", s.autoLowSpaceGB)) }
        if parts.isEmpty { return L("Açık · bir tetikleyici seç") }
        return L("Açık · %@", parts.joined(separator: " · "))
    }

    var body: some View {
        let s: CleanerSettings = cleaner.settings
        return VStack(alignment: .leading, spacing: 8) {
            CardTitleRow(icon: s.autoEnabled ? "sparkles" : "sparkles.rectangle.stack", title: L("Otomatik temizlik"), subtitle: summary)
            ToggleRow(title: L("Otomatik temizliği aç"), isOn: binding(\.autoEnabled))
            if s.autoEnabled {
                ToggleRow(title: L("Her gün belirli saatte"), isOn: binding(\.autoDaily))
                if s.autoDaily { AutoTimeRow(cleaner: cleaner) }
                ToggleRow(title: L("Disk dolmaya başlayınca"), isOn: binding(\.autoLowSpace))
                if s.autoLowSpace {
                    StepperRow(label: L("Boş alan %@ GB'ın altına inince", s.autoLowSpaceGB), value: binding(\.autoLowSpaceGB), range: 0...500, step: 5)
                }
                NoteText(text: L("Mac meşgulken ya da pil azken beklenir."))
            }
            Button(action: openSettings) {
                Label(L("Neler temizlensin, nelere dokunulmasın? Ayarlar"), systemImage: "gearshape")
                    .font(.system(size: 10, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
        }
        .cardStyle()
        .transaction { $0.animation = nil }
    }
}

private struct AutoTimeRow: View {
    @ObservedObject var cleaner: CleanerModel
    private var date: Binding<Date> {
        let c = cleaner
        return Binding<Date>(get: {
            Calendar.current.date(bySettingHour: c.settings.autoHour, minute: c.settings.autoMinute, second: 0, of: Date()) ?? Date()
        }, set: { d in
            let comps = Calendar.current.dateComponents([.hour, .minute], from: d)
            c.update { $0.autoHour = comps.hour ?? 4; $0.autoMinute = comps.minute ?? 0 }
        })
    }
    var body: some View {
        HStack {
            Text(L("Saat")).font(.system(size: 11))
            Spacer()
            DatePicker("", selection: date, displayedComponents: .hourAndMinute).labelsHidden().controlSize(.small)
        }
    }
}

private struct StepperRow: View {
    let label: String
    let value: Binding<Int>
    let range: ClosedRange<Int>
    let step: Int
    var body: some View {
        HStack {
            Text(label).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Stepper("", value: value, in: range, step: step).labelsHidden().controlSize(.small).fixedSize()
        }
    }
}

private struct AutoCategoryList: View {
    @ObservedObject var cleaner: CleanerModel
    private func binding(_ c: CleanCategory) -> Binding<Bool> {
        let m = cleaner
        return Binding<Bool>(get: { m.settings.isAuto(c) }, set: { v in m.update { $0.autoCategories[c.rawValue] = v } })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Otomatik temizlenecekler")).font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
            ForEach(CleanCategory.allCases.filter { $0.autoEligible }) { (c: CleanCategory) in
                ToggleRow(title: c.title, isOn: binding(c))
            }
        }
    }
}

private struct PathListEditor: View {
    @ObservedObject var cleaner: CleanerModel
    let title: String
    let hint: String
    let list: WritableKeyPath<CleanerSettings, [String]>
    let newValue: ReferenceWritableKeyPath<CleanerModel, String>

    private var text: Binding<String> {
        let c = cleaner, k = newValue
        return Binding<String>(get: { c[keyPath: k] }, set: { c[keyPath: k] = $0 })
    }

    private func add() {
        let v = cleaner[keyPath: newValue].trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return }
        let k = list
        cleaner.update { s in if !s[keyPath: k].contains(v) { s[keyPath: k].append(v) } }
        cleaner[keyPath: newValue] = ""
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            cleaner[keyPath: newValue] = PathGuard.display(url.path, home: home)
            add()
        }
    }

    var body: some View {
        let items: [String] = cleaner.settings[keyPath: list]
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .medium))
            NoteText(text: hint)
            ForEach(items, id: \.self) { (p: String) in
                HStack {
                    Text(p).font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(action: {
                        let k = list
                        cleaner.update { $0[keyPath: k].removeAll { $0 == p } }
                    }) { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundColor(.secondary)
                }
            }
            HStack(spacing: 6) {
                TextField(L("~/klasör"), text: text, onCommit: add).textFieldStyle(.roundedBorder).font(.system(size: 10))
                Button(action: choose) { Image(systemName: "folder") }.buttonStyle(.plain)
                Button(action: add) { Image(systemName: "plus.circle.fill") }.buttonStyle(.plain).foregroundColor(.accentColor)
            }
        }
    }
}
