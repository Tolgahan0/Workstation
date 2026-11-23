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
                         subtitle: "Ekran Paylaşımı bağlanınca Remote; oturum bitince seçilen moda dön")
            ToggleRow(title: "Uzak oturumda otomatik Remote", isOn: binding(\.enabled))
            if s.enabled {
                ToggleRow(title: "SSH oturumlarını da say", isOn: binding(\.includeSSH))
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
