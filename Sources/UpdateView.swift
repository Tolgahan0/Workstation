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
    /// İndirme ilerlemesi (0…1); bilinmiyorsa nil.
    @Published var progress: Double?
    /// Kurulu fan yardımcısı / workstation komutu bu sürümden eski.
    @Published var helpersOutdated = false
    @Published var helpersBusy = false
    /// "Yardımcılar güncellendi" / "İptal edildi" gibi sonuç metinleri de 5 sn sonra kaybolur.
    @Published var helpersNote: String? {
        didSet {
            guard helpersNote != nil else { return }
            helpersNoteGeneration += 1
            let g = helpersNoteGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + PanelModel.noteLifetime) { [weak self] in
                guard let self = self, self.helpersNoteGeneration == g else { return }
                self.helpersNote = nil
            }
        }
    }
    private var helpersNoteGeneration = 0
    var onUpdateHelpers: () -> Void = {}

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

/// Panelin üstünde (başlığın altında) büyük "Yeni sürüm" şeridi: tek tıkla indir → doğrula → kur → yeniden aç.
struct UpdateBanner: View {
    @ObservedObject var updater: UpdateModel
    let currentVersion: String

    private var working: String? {
        if case .working(let s) = updater.phase { return s }
        return nil
    }
    private var failure: String? {
        if case .failed(let s) = updater.phase { return s }
        return nil
    }

    var body: some View {
        if let c = updater.candidate {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(Color(nsColor: IconRenderer.updateTint))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("Yeni sürüm %@", c.version)).font(.system(size: 13, weight: .semibold))
                        Text(working ?? L("Şu an %@ · tek tıkla güncellenir", currentVersion))
                            .font(.system(size: 10)).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if working == nil {
                        Button(action: updater.onInstall) {
                            Text(failure == nil ? L("Güncelle") : L("Tekrar dene"))
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .background(Capsule().fill(Color(nsColor: IconRenderer.updateTint)))
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)
                        .fixedSize()
                        .help(L("İndirir, SHA-256 ile doğrular, kurar ve yeniden açar"))
                    }
                }
                if working != nil {
                    if let p = updater.progress, p > 0, p < 1 {
                        ProgressView(value: p).progressViewStyle(.linear)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                if let f = failure {
                    Text(f).font(.system(size: 10)).foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: IconRenderer.updateTint).opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: IconRenderer.updateTint).opacity(0.45), lineWidth: 1))
            .transaction { $0.animation = nil }
        }
    }
}

/// Yardımcılar eskiyse: tek tıkla macOS'un yönetici parolası penceresiyle güncelle.
struct HelpersBanner: View {
    @ObservedObject var updater: UpdateModel

    var body: some View {
        if updater.helpersOutdated || updater.helpersNote != nil {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: updater.helpersOutdated ? "wrench.and.screwdriver.fill" : "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(updater.helpersOutdated ? .orange : .green)
                    Text(updater.helpersOutdated ? L("Yardımcılar güncel değil") : (updater.helpersNote ?? ""))
                        .font(.system(size: 12, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if updater.helpersOutdated {
                    Text(updater.helpersNote ?? L("Fan kontrolü ve workstation komutu için; parolan bir kez sorulur."))
                        .font(.system(size: 10)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Spacer(minLength: 0)
                        if updater.helpersBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            SmallButton(title: L("Yardımcıları güncelle"), icon: "lock.open", prominent: true, action: updater.onUpdateHelpers)
                                .fixedSize()
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(updater.helpersOutdated ? 0.12 : 0.0)))
            .transaction { $0.animation = nil }
        }
    }
}

/// Başlıkta "Güncelleme var" rozeti (yalnızca yeni sürüm varken çizilir).
struct UpdateBadge: View {
    @ObservedObject var updater: UpdateModel

    var body: some View {
        if let c = updater.candidate, updater.phase == .available {
            Button(action: updater.onOpenSettings) {
                Label(L("Güncelleme var: %@", c.version), systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.85)))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .help(L("Yeni sürümü görmek için tıkla"))
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
            CardTitleRow(icon: "arrow.down.circle", title: L("Güncellemeler"),
                         subtitle: L("Şu an %@ kullanıyorsun. Açılışta ve 6 saatte bir yeni sürüm var mı diye bakılır.", currentVersion))
            UpdateStatusRow(updater: updater)
            if let c = updater.candidate, updater.phase == .available || isWorking {
                UpdateNotesBox(candidate: c)
            }
            ToggleRow(title: L("Otomatik güncelle (kapalıyken sadece haber verir)"), isOn: binding(\.autoInstall))
            ToggleRow(title: L("Beta sürümleri de göster"), isOn: binding(\.beta))
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
            if let d = updater.lastChecked { return L("Son kontrol: ") + Self.format(d) }
            return L("Henüz kontrol edilmedi")
        case .checking: return L("Kontrol ediliyor…")
        case .upToDate: return L("En güncel sürümü kullanıyorsun")
        case .available: return L("Yeni sürüm hazır: %@", updater.candidate?.version ?? "")
        case .working(let s): return s
        case .failed(let s): return s
        }
    }

    static func format(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = L10n.locale
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
                SmallButton(title: L("Güncelle"), icon: "arrow.down.circle", prominent: true, action: updater.onInstall)
            } else {
                SmallButton(title: L("Kontrol et"), icon: "arrow.clockwise", prominent: false, action: updater.onCheck)
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
            Text(L("Bu sürümde neler var")).font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
            Text(candidate.notes.isEmpty ? L("Not eklenmemiş.") : candidate.notes)
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
            Text(L("Güncelleme sırasında uygulama birkaç saniye kapanıp yeniden açılır."))
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
                Text(updater.hasToken ? L("GitHub anahtarı kayıtlı (Anahtar Zinciri'nde)") : L("GitHub anahtarı gerekmez (isteğe bağlı)"))
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
                Button(updater.showToken ? L("Vazgeç") : (updater.hasToken ? L("Değiştir") : L("Ekle"))) {
                    updater.showToken.toggle()
                    updater.tokenDraft = ""
                }
                .buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).foregroundColor(.accentColor)
                if updater.hasToken && !updater.showToken {
                    Button(L("Sil")) { updater.onSaveToken(nil) }
                        .buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).foregroundColor(.orange)
                }
            }
            if updater.showToken {
                HStack(spacing: 6) {
                    SecureField(L("ghp_… (yalnızca okuma izni yeterli)"), text: $updater.tokenDraft)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11))
                    SmallButton(title: L("Kaydet"), icon: "key.fill", prominent: true) {
                        updater.onSaveToken(updater.tokenDraft)
                    }
                }
            }
        }
    }
}
