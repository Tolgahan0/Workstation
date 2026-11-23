import SwiftUI
import AppKit

// Güncelleme: başlık rozeti + Ayarlar kartı. Makro yok; durum UpdateModel'de (@Published).

final class UpdateModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case working(String)
        case failed(String)
    }

    @Published var settings = UpdateSettings.load()
    @Published var phase: Phase = .idle
    @Published var candidate: Updater.Candidate?
    @Published var lastChecked: Date? = UserDefaults.standard.object(forKey: "updateLastChecked") as? Date
    @Published var hasToken = false
    @Published var tokenDraft = ""
    @Published var showToken = false

    var onCheck: () -> Void = {}
    var onInstall: () -> Void = {}
    var onSettings: (UpdateSettings) -> Void = { _ in }
    var onSaveToken: (String?) -> Void = { _ in }
    var onOpenSettings: () -> Void = {}

    var busy: Bool {
        if case .working = phase { return true }
        return phase == .checking
    }
}

/// Başlıkta "Güncelleme var" rozeti (yalnızca yeni sürüm varken çizilir).
struct UpdateBadge: View {
    @ObservedObject var updater: UpdateModel

    var body: some View {
        if let c = updater.candidate, updater.phase == .available {
            Button(action: updater.onOpenSettings) {
                Label("Güncelleme var: \(c.version)", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.85)))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .help("Yeni sürümü görmek için tıkla")
        }
    }
}

struct UpdateSettingsCard: View {
    @ObservedObject var updater: UpdateModel
    let currentVersion: String

    private func binding(_ path: WritableKeyPath<UpdateSettings, Bool>) -> Binding<Bool> {
        let u: UpdateModel = updater
        return Binding<Bool>(get: { u.settings[keyPath: path] },
                             set: { v in
                                 var s = u.settings
                                 s[keyPath: path] = v
                                 u.onSettings(s)
                             })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitleRow(icon: "arrow.down.circle", title: "Güncellemeler",
                         subtitle: "Şu an \(currentVersion) kullanıyorsun. Günde bir kez yeni sürüm var mı diye bakılır.")
            UpdateStatusRow(updater: updater)
            if let c = updater.candidate, updater.phase == .available || isWorking {
                UpdateNotesBox(candidate: c)
            }
            ToggleRow(title: "Otomatik güncelle (kapalıyken sadece haber verir)", isOn: binding(\.autoInstall))
            ToggleRow(title: "Beta sürümleri de göster", isOn: binding(\.beta))
            UpdateTokenRow(updater: updater)
        }
        .cardStyle()
    }

    private var isWorking: Bool {
        if case .working = updater.phase { return true }
        return false
    }
}

private struct UpdateStatusRow: View {
    @ObservedObject var updater: UpdateModel

    private var text: String {
        switch updater.phase {
        case .idle:
            if let d = updater.lastChecked { return "Son kontrol: " + Self.format(d) }
            return "Henüz kontrol edilmedi"
        case .checking: return "Kontrol ediliyor…"
        case .upToDate: return "En güncel sürümü kullanıyorsun"
        case .available: return "Yeni sürüm hazır: \(updater.candidate?.version ?? "")"
        case .working(let s): return s
        case .failed(let s): return s
        }
    }

    static func format(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: d)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(isError ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if updater.busy {
                ProgressView().controlSize(.small)
            } else if updater.phase == .available {
                SmallButton(title: "Güncelle", icon: "arrow.down.circle", prominent: true, action: updater.onInstall)
            } else {
                SmallButton(title: "Kontrol et", icon: "arrow.clockwise", prominent: false, action: updater.onCheck)
            }
        }
    }

    private var isError: Bool {
        if case .failed = updater.phase { return true }
        return false
    }
}

private struct UpdateNotesBox: View {
    let candidate: Updater.Candidate
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bu sürümde neler var").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
            Text(candidate.notes.isEmpty ? "Not eklenmemiş." : candidate.notes)
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
            Text("Güncelleme sırasında uygulama birkaç saniye kapanıp yeniden açılır.")
                .font(.system(size: 9)).foregroundColor(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
    }
}

/// Özel depo için GitHub anahtarı (Anahtar Zinciri'nde saklanır, ekranda gösterilmez).
private struct UpdateTokenRow: View {
    @ObservedObject var updater: UpdateModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(updater.hasToken ? "GitHub anahtarı kayıtlı (Anahtar Zinciri'nde)" : "Depo gizliyse GitHub anahtarı gerekir")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
                Button(updater.showToken ? "Vazgeç" : (updater.hasToken ? "Değiştir" : "Ekle")) {
                    updater.showToken.toggle()
                    updater.tokenDraft = ""
                }
                .buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).foregroundColor(.accentColor)
                if updater.hasToken && !updater.showToken {
                    Button("Sil") { updater.onSaveToken(nil) }
                        .buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).foregroundColor(.orange)
                }
            }
            if updater.showToken {
                HStack(spacing: 6) {
                    SecureField("ghp_… (yalnızca okuma izni yeterli)", text: $updater.tokenDraft)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11))
                    SmallButton(title: "Kaydet", icon: "key.fill", prominent: true) {
                        updater.onSaveToken(updater.tokenDraft)
                    }
                }
            }
        }
    }
}
