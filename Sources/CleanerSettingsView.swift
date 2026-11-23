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
            CardTitleRow(icon: "sparkles", title: "Otomatik disk temizliği",
                         subtitle: "Sadece en güvenli kalemler; kullanılan hiçbir şeye dokunulmaz")
            ToggleRow(title: "Otomatik temizlik", isOn: binding(\.autoEnabled))
            if s.autoEnabled {
                ToggleRow(title: "Her gün belirli saatte", isOn: binding(\.autoDaily))
                if s.autoDaily { AutoTimeRow(cleaner: cleaner) }
                ToggleRow(title: "Disk dolmaya başlayınca", isOn: binding(\.autoLowSpace))
                if s.autoLowSpace {
                    StepperRow(label: "Boş alan \(s.autoLowSpaceGB) GB'ın altına inince", value: binding(\.autoLowSpaceGB), range: 0...500, step: 5)
                    StepperRow(label: "ya da %\(s.autoLowSpacePercent)'in altına inince", value: binding(\.autoLowSpacePercent), range: 0...50, step: 1)
                }
                Text("Mac meşgulken ya da pil azken beklenir.").font(.system(size: 10)).foregroundColor(.secondary)
                AutoCategoryList(cleaner: cleaner)
            }
            Divider().opacity(0.2)
            PathListEditor(cleaner: cleaner, title: "Asla dokunma", hint: "Bu klasörler ve içindekiler hiç silinmez",
                           list: \.neverTouch, newValue: \.newNeverTouch)
            PathListEditor(cleaner: cleaner, title: "Ek proje klasörleri", hint: "Ev klasörü zaten taranır; başka disk ya da klasör ekleyebilirsin",
                           list: \.extraRoots, newValue: \.newRoot)
        }
        .cardStyle()
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
            Text("Saat").font(.system(size: 11))
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
            Text(label).font(.system(size: 11))
            Spacer()
            Stepper("", value: value, in: range, step: step).labelsHidden().controlSize(.small)
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
            Text("Otomatik temizlenecekler").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
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
            Text(hint).font(.system(size: 10)).foregroundColor(.secondary)
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
                TextField("~/klasör", text: text, onCommit: add).textFieldStyle(.roundedBorder).font(.system(size: 10))
                Button(action: choose) { Image(systemName: "folder") }.buttonStyle(.plain)
                Button(action: add) { Image(systemName: "plus.circle.fill") }.buttonStyle(.plain).foregroundColor(.accentColor)
            }
        }
    }
}
