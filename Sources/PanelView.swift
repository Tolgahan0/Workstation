import SwiftUI
import AppKit

// NOT: Bu dosyada SwiftUI makro tabanlı öznitelikler (@State, @Observable, @Bindable, #Preview, @Entry)
// KULLANILMAZ — yalnızca Command Line Tools ile derlerken SwiftUIMacros eklentisi bulunmuyor.
// Durum ObservableObject + @Published + @ObservedObject ile tutulur (bunlar makro değildir).
// Gövdeler küçük alt görünümlere bölünmüştür (tür denetimi zaman aşımını önlemek için).

// MARK: - Görünüm modelleri

enum PanelPage { case main, settings, cleaner }

/// Üst sekmeler: üç mod + Araçlar.
enum PanelTab: Hashable {
    case desktop, sleep, remote, tools
    init(_ mode: WorkMode) {
        switch mode {
        case .desktop: self = .desktop
        case .sleep: self = .sleep
        case .remote: self = .remote
        }
    }
}

/// Tek bir monitör kartının kaydırıcı durumu. Kaydırıcı sürüklenirken yalnızca bu nesne yayın yapar,
/// böylece yalnızca o kart yeniden çizilir.
final class BrightnessCardModel: ObservableObject {
    let key: String
    @Published var level: Double
    var editing = false

    init(key: String, level: Double) {
        self.key = key
        self.level = level
    }
}

/// Popover panelinin durumu. Yalnızca ana iş parçacığında değiştirilir.
final class PanelModel: ObservableObject {
    @Published var mode: WorkMode = .desktop
    @Published var selectedTab: PanelTab = .desktop {
        didSet {
            if selectedTab != oldValue {
                onToolsVisible(selectedTab == .tools && page == .main)
                if selectedTab == .remote { onRemoteShown() }
            }
        }
    }
    @Published var page: PanelPage = .main {
        didSet {
            if page != oldValue {
                onSettingsShown(page == .settings)
                onToolsVisible(selectedTab == .tools && page == .main)
            }
        }
    }
    @Published var transitioning = false
    @Published var statusNote: String?
    @Published var monitors: [MonitorSnapshot] = [] {
        didSet { syncCardModels() }
    }
    @Published var loadingMonitors = false

    // Remote
    @Published var presetID: String = RemoteResolution.selectedPresetID
    @Published var bdInstalled: Bool = BetterDisplayInstaller.isInstalled
    @Published var installProgress: BetterDisplayInstaller.Progress = .idle

    // Ayarlar
    @Published var methodPreference: PhysicalMethod = PhysicalMethod.preference
    @Published var settingsInfo = SettingsInfo()
    @Published var memoryText: String = "—"

    var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    // Geri sayım ayarı (sn, 0 = kapalı)
    @Published var countdownSeconds: Int = CountdownSettings.seconds

    // Araçlar → Fan
    @Published var fanStatus: FanStatus?
    @Published var fanMode: FanMode = .auto
    @Published var fanApplying = false
    @Published var fanNote: String?
    @Published var fanHelperInstalled: Bool = FanController.helperInstalled
    /// Popover açık mı (kapalıyken fan animasyonu durdurulur).
    @Published var panelOpen = false

    // Remote → Wake-on-LAN bilgisi (Remote sekmesi açılınca bir kez okunur)
    @Published var netInfo: NetworkInfo?

    // Ayarlar → otomatik mod geçişi
    @Published var autoSwitch = AutoSwitchSettings.load()
    @Published var autoSwitchStatus = "—"

    // Ayarlar → zamanlanmış modlar
    @Published var schedule = ScheduleSettings.load()
    @Published var scheduleNext = ""

    // Masaüstü → profiller
    @Published var profiles: [WorkspaceProfile] = ProfileStore.load()
    @Published var newProfileName = ""
    @Published var profileNote: String?

    // Ayarlar → ses
    @Published var muteInRemote: Bool = AudioControl.enabled

    // Tools → sistem + uyanık tut
    @Published var stats: SystemStatsSnapshot?
    @Published var keepAwakeOn = false
    @Published var keepAwakeUntil: Date?
    @Published var keepAwakeDuration: KeepAwake.Duration = .oneHour

    // Ayarlar → bildirimler
    @Published var notifySettings = NotificationSettings.load()
    /// Geliştirici Temizleyici (kendi yayınları olan ayrı model: tarama ilerlemesi tüm paneli yeniden çizmez).
    let cleaner = CleanerModel()
    /// Güncelleyici (ayrı model: indirme durumu tüm paneli yeniden çizmez).
    let updater = UpdateModel()
    var toolsVisible: Bool { selectedTab == .tools && page == .main }

    /// Kart başına kaydırıcı modelleri (monitör anahtarına göre).
    private(set) var cardModels: [String: BrightnessCardModel] = [:]

    var effectiveResolution: String { RemoteResolution.effective() }
    var lastClientResolution: String? { RemoteResolution.lastClientResolution }

    // Eylemler (AppDelegate bağlar; hepsi [weak self] ile)
    var onStart: (WorkMode) -> Void = { _ in }
    var onToggleMonitor: (String, Bool) -> Void = { _, _ in }
    var onBrightness: (String, Double, Bool) -> Void = { _, _, _ in }
    var onForceSoftware: (String, Bool) -> Void = { _, _ in }
    var onRescan: () -> Void = {}
    var onRepairVirtual: () -> Void = {}
    var onOpenLog: () -> Void = {}
    var onInstallBD: () -> Void = {}
    var onQuit: () -> Void = {}
    var onSelectMethod: (PhysicalMethod) -> Void = { _ in }
    var onSettingsShown: (Bool) -> Void = { _ in }
    var onToolsVisible: (Bool) -> Void = { _ in }
    var onRemoteShown: () -> Void = {}
    var onAutoSwitch: (AutoSwitchSettings) -> Void = { _ in }
    var onSchedule: (ScheduleSettings) -> Void = { _ in }
    var onApplyProfile: (UUID) -> Void = { _ in }
    var onSaveProfile: (String) -> Void = { _ in }
    var onDeleteProfile: (UUID) -> Void = { _ in }
    var onMuteInRemote: (Bool) -> Void = { _ in }
    var onKeepAwake: (Bool, KeepAwake.Duration) -> Void = { _, _ in }
    var onNotifySettings: (NotificationSettings) -> Void = { _ in }
    var onFanMode: (FanMode) -> Void = { _ in }

    func selectPreset(_ id: String) {
        presetID = id
        RemoteResolution.selectedPresetID = id
    }

    func setCountdownSeconds(_ value: Int) {
        let v = max(0, min(10, value))
        countdownSeconds = v
        CountdownSettings.seconds = v
    }

    var isInstalling: Bool {
        switch installProgress {
        case .working, .downloading: return true
        default: return false
        }
    }

    func cardModel(for monitor: MonitorSnapshot) -> BrightnessCardModel {
        if let m = cardModels[monitor.key] { return m }
        let m = BrightnessCardModel(key: monitor.key, level: monitor.brightness)
        cardModels[monitor.key] = m
        return m
    }

    private func syncCardModels() {
        var keep: [String: BrightnessCardModel] = [:]
        for mon in monitors {
            if let m = cardModels[mon.key] {
                if !m.editing && abs(m.level - mon.brightness) > 0.5 { m.level = mon.brightness }
                keep[mon.key] = m
            }
        }
        cardModels = keep
    }
}

// MARK: - Arka plan (NSVisualEffectView)

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Renkler

enum Palette {
    static let sleepTint: Color = Color(red: 0.35, green: 0.45, blue: 0.95)
    static let remoteTint: Color = Color(red: 0.55, green: 0.32, blue: 0.95)
    static let cardFill: Color = Color.white.opacity(0.06)
    static let cardStroke: Color = Color.white.opacity(0.08)
}

// MARK: - Ana panel

struct PanelView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        let content: AnyView
        switch model.page {
        case .settings: content = AnyView(SettingsPage(model: model))
        case .cleaner: content = AnyView(CleanerPage(model: model))
        case .main: content = AnyView(MainPage(model: model))
        }
        return VStack(alignment: .leading, spacing: 14) {
            PanelHeader(model: model)
            content
        }
        .padding(16)
        .frame(width: 360)
        .background(VisualEffectBackground().ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

private struct MainPage: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TabPicker(model: model)
            StatusNoteView(note: model.statusNote)
            TabContent(model: model)
            Divider().opacity(0.3)
            PanelFooter(model: model)
        }
    }
}

private struct PanelHeader: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        HStack(spacing: 12) {
            AppIconView()
            HeaderTitle(subtitle: model.mode.title)
            Spacer()
            UpdateBadge(updater: model.updater)
            StatusPill(transitioning: model.transitioning)
        }
    }
}

private struct AppIconView: View {
    var body: some View {
        let image: NSImage = NSApp.applicationIconImage ?? NSImage()
        return Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: 40, height: 40)
    }
}

private struct HeaderTitle: View {
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Workstation").font(.system(size: 15, weight: .bold))
            Text(subtitle).font(.system(size: 12)).foregroundColor(.secondary)
        }
    }
}

private struct TabPicker: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        Picker("", selection: $model.selectedTab) {
            Text("Masaüstü").tag(PanelTab.desktop)
            Text("Uyku").tag(PanelTab.sleep)
            Text("Remote").tag(PanelTab.remote)
            Text("Tools").tag(PanelTab.tools)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

private struct StatusNoteView: View {
    let note: String?
    var body: some View {
        if let text = note {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct TabContent: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        switch model.selectedTab {
        case .desktop: DesktopTab(model: model)
        case .sleep: SleepTab(model: model)
        case .remote: RemoteTab(model: model)
        case .tools: ToolsTab(model: model)
        }
    }
}

private struct PanelFooter: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        HStack {
            Button(action: { model.page = .settings }) {
                Label("Ayarlar", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            Spacer()
            QuitButton(model: model)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.secondary)
    }
}

private struct QuitButton: View {
    @ObservedObject var model: PanelModel
    var body: some View {
        Button(action: { model.onQuit() }) {
            Label("Workstation'dan çık", systemImage: "power")
        }
        .buttonStyle(.plain)
        .foregroundColor(Color.red.opacity(0.9))
        .font(.system(size: 12, weight: .medium))
    }
}

private struct StatusPill: View {
    let transitioning: Bool

    var body: some View {
        let text: String = transitioning ? "GEÇİŞ" : "AKTİF"
        let color: Color = transitioning ? .yellow : .green
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 10, weight: .bold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.18)))
        .foregroundColor(color)
    }
}

// MARK: - Ortak parçalar

struct StartButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        let fill: Color = tint.opacity(disabled ? 0.25 : 0.9)
        return Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill))
                .foregroundColor(.white)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

struct InfoRow: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).frame(width: 16).foregroundColor(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
    }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.cardFill))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.cardStroke, lineWidth: 0.5))
    }
}

extension View {
    func cardStyle() -> some View { modifier(CardBackground()) }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
    }
}

// MARK: - Masaüstü sekmesi

private struct DesktopTab: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DesktopReturnButton(model: model)
            ProfilesCard(model: model)
            MonitorListHeader(model: model)
            DesktopModeHint(mode: model.mode)
            MonitorList(model: model)
        }
    }
}

private struct DesktopReturnButton: View {
    @ObservedObject var model: PanelModel
    var body: some View {
        if model.mode != .desktop {
            StartButton(title: "Masaüstüne dön",
                        systemImage: WorkMode.desktop.symbolName,
                        tint: .accentColor,
                        disabled: model.transitioning,
                        action: { model.onStart(.desktop) })
        }
    }
}

private struct MonitorListHeader: View {
    @ObservedObject var model: PanelModel
    var body: some View {
        HStack {
            SectionTitle(text: "MONİTÖRLER")
            if model.loadingMonitors {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
            Spacer()
            Button(action: { model.onRescan() }) {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Monitörleri yeniden tara")
        }
    }
}

private struct DesktopModeHint: View {
    let mode: WorkMode
    var body: some View {
        if mode != .desktop {
            let text: String = "Şu an \(mode.title) açık, monitörler kapalı. Burada yaptığın ayarlar saklanır, Masaüstüne dönünce uygulanır."
            Text(text)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MonitorList: View {
    @ObservedObject var model: PanelModel
    var body: some View {
        if model.monitors.isEmpty && !model.loadingMonitors {
            Text("Bağlı monitör bulunamadı")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .cardStyle()
        }
        ForEach(model.monitors) { (m: MonitorSnapshot) in
            MonitorCard(monitor: m, card: model.cardModel(for: m), panel: model)
        }
    }
}

// MARK: - Uyku sekmesi

private struct SleepTab: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SleepInfoCard()
            SleepStartButton(model: model)
        }
    }
}

private struct SleepInfoCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Uyku", systemImage: WorkMode.sleep.symbolName)
                .font(.system(size: 13, weight: .semibold))
            InfoRow(icon: "display", text: "Monitörler tamamen kapanır, Mac en az enerjiyle uyur.")
            InfoRow(icon: "moon.zzz", text: "Bir dakika sonra Mac uykuya geçer.")
            InfoRow(icon: "hand.tap", text: "Klavye ya da fareye dokunduğunda her şey kaldığı gibi geri gelir.")
        }
        .cardStyle()
    }
}

private struct SleepStartButton: View {
    @ObservedObject var model: PanelModel
    var body: some View {
        if model.mode == .sleep {
            StartButton(title: "Uyku açık", systemImage: "checkmark", tint: .gray, disabled: true, action: {})
        } else {
            StartButton(title: "Başlat", systemImage: "play.fill", tint: Palette.sleepTint,
                        disabled: model.transitioning, action: { model.onStart(.sleep) })
        }
    }
}

// MARK: - Remote sekmesi

private struct RemoteTab: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RemoteInfoCard(resolution: model.effectiveResolution)
            PresetCard(model: model)
            BetterDisplayStatusCard(model: model)
            WakeConnectCard(model: model)
            RemoteStartButton(model: model)
        }
    }
}

private struct RemoteInfoCard: View {
    let resolution: String
    var body: some View {
        let line: String = "Monitörler kapanır, sadece uzaktan bağlanan Mac için bir sanal ekran açık kalır."
        return VStack(alignment: .leading, spacing: 8) {
            Label("Remote", systemImage: WorkMode.remote.symbolName)
                .font(.system(size: 13, weight: .semibold))
            InfoRow(icon: "rectangle.on.rectangle", text: line)
            InfoRow(icon: "bolt", text: "Sen bağlıyken Mac asla uyumaz, elektrik kesilip gelirse kendi açılır.")
            InfoRow(icon: "display", text: "Monitörler sadece Masaüstüne dönünce açılır.")
        }
        .cardStyle()
    }
}

private struct PresetCard: View {
    @ObservedObject var model: PanelModel

    private var selection: Binding<String> {
        Binding<String>(get: { model.presetID }, set: { model.selectPreset($0) })
    }

    private var autoHint: String {
        let tail: String = " Bağlanan Mac'te bağlanma komutunu çalıştırınca ekran boyutu kendiliğinden ayarlanır."
        if let last = model.lastClientResolution {
            let text: String = "Son bağlanan Mac'in ekranı: \(last).\(tail)"
            return text
        }
        let text: String = "Henüz bağlanan olmadı, şimdilik 14 inç MacBook Pro boyutu kullanılır.\(tail)"
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Bağlanan Mac").font(.system(size: 11, weight: .semibold))
                Spacer()
                Picker("", selection: selection) {
                    ForEach(RemotePreset.all) { (p: RemotePreset) in
                        Text(PresetCard.label(for: p)).tag(p.id)
                    }
                }
                .labelsHidden()
                .frame(width: 210)
            }
            if model.presetID == "auto" {
                Text(autoHint)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .cardStyle()
    }

    static func label(for p: RemotePreset) -> String {
        if p.id == "auto" { return "Otomatik" }
        return p.title
    }
}

private struct BetterDisplayStatusCard: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        BetterDisplayStatusContent(model: model).cardStyle()
    }
}

private struct BetterDisplayStatusContent: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        switch model.installProgress {
        case .working(let text):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).font(.system(size: 11))
            }
        case .downloading(let fraction, let text):
            VStack(alignment: .leading, spacing: 4) {
                Text("Sanal ekran aracı (BetterDisplay) indiriliyor… " + text).font(.system(size: 11))
                ProgressView(value: fraction).progressViewStyle(.linear)
            }
        case .failed(let message):
            HStack {
                Label("Kurulamadı: " + message, systemImage: "xmark.octagon.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                Spacer()
                Button("Tekrar dene", action: { model.onInstallBD() }).font(.system(size: 11))
            }
        default:
            BetterDisplayIdleStatus(model: model)
        }
    }
}

private struct BetterDisplayIdleStatus: View {
    @ObservedObject var model: PanelModel
    var body: some View {
        if model.bdInstalled {
            Label("Sanal ekran aracı hazır", systemImage: "checkmark.seal.fill")
                .font(.system(size: 11))
                .foregroundColor(.green)
        } else {
            HStack {
                Label("Sanal ekran aracı yok, Başlat'a basınca kendisi kurulur", systemImage: "arrow.down.circle")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                Spacer()
                Button("Şimdi kur", action: { model.onInstallBD() }).font(.system(size: 11))
            }
        }
    }
}

private struct RemoteStartButton: View {
    @ObservedObject var model: PanelModel
    var body: some View {
        let isRemote: Bool = model.mode == .remote
        let busy: Bool = model.transitioning || model.isInstalling
        return StartButton(title: isRemote ? "Yeniden uygula" : "Başlat",
                           systemImage: isRemote ? "arrow.clockwise" : "play.fill",
                           tint: Palette.remoteTint,
                           disabled: busy,
                           action: { model.onStart(.remote) })
    }
}

// MARK: - Ayarlar sayfası

private struct SettingsPage: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: { model.page = .main }) {
                Label("Geri", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .font(.system(size: 12, weight: .medium))
            // Kart sayısı arttığı için kaydırılabilir; sabit yükseklik popover boyutunu kararlı tutar.
            ScrollView(.vertical, showsIndicators: true) {
                SettingsCards(model: model)
                    .padding(.trailing, 4)
            }
            .frame(height: 540)
        }
    }
}

private struct SettingsCards: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "AYARLAR")
            SettingsActionsCard(model: model)
            MethodCard(model: model)
            CountdownSettingCard(model: model)
            SectionTitle(text: "OTOMASYON")
            AutoSwitchCard(model: model)
            ScheduleCard(model: model)
            AudioCard(model: model)
            NotificationsCard(model: model)
            SectionTitle(text: "DİSK TEMİZLİĞİ")
            CleanerSettingsCard(cleaner: model.cleaner)
            SectionTitle(text: "GÜNCELLEME")
            UpdateSettingsCard(updater: model.updater, currentVersion: model.appVersion)
            SectionTitle(text: "DURUM")
            StatusGridCard(model: model)
            HStack {
                Spacer()
                QuitButton(model: model)
            }
        }
    }
}

private struct SettingsRow: View {
    let icon: String
    let title: String
    let subtitle: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 18).foregroundColor(.accentColor)
                SettingsRowText(title: title, subtitle: subtitle)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsRowText: View {
    let title: String
    let subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 12, weight: .medium))
            if let s = subtitle {
                Text(s).font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
    }
}

private struct SettingsActionsCard: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        let bdTitle: String = model.bdInstalled ? "Sanal ekran aracını aç" : "Sanal ekran aracını kur"
        let bdSubtitle: String = model.bdInstalled ? "BetterDisplay kurulu" : "BetterDisplay indirilip kurulur"
        return VStack(alignment: .leading, spacing: 8) {
            SettingsRow(icon: "doc.text.magnifyingglass", title: "Günlük",
                        subtitle: "Uygulamanın yaptığı her şeyin kaydı", action: { model.onOpenLog() })
            Divider().opacity(0.2)
            SettingsRow(icon: "arrow.clockwise", title: "Monitörleri yeniden tara",
                        subtitle: nil, action: { model.onRescan() })
            Divider().opacity(0.2)
            SettingsRow(icon: "rectangle.badge.plus", title: "Sanal ekranı onar",
                        subtitle: "Remote'ta ekran gelmezse dene", action: { model.onRepairVirtual() })
            Divider().opacity(0.2)
            SettingsRow(icon: "arrow.down.app", title: bdTitle,
                        subtitle: bdSubtitle, action: { model.onInstallBD() })
        }
        .cardStyle()
    }
}

private struct CountdownSettingCard: View {
    @ObservedObject var model: PanelModel

    private var value: Binding<Int> {
        Binding<Int>(get: { model.countdownSeconds }, set: { model.setCountdownSeconds($0) })
    }

    var body: some View {
        let label: String = model.countdownSeconds == 0
            ? "Geri sayım: kapalı"
            : "Geri sayım: \(model.countdownSeconds) sn"
        return HStack {
            Image(systemName: "timer").frame(width: 18).foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 12, weight: .medium))
                Text("Uyku ve Remote başlamadan önce bekleme (0 = hemen)").font(.system(size: 10)).foregroundColor(.secondary)
            }
            Spacer()
            Stepper("", value: value, in: 0...10).labelsHidden()
        }
        .cardStyle()
    }
}

private struct MethodCard: View {
    @ObservedObject var model: PanelModel

    private var selection: Binding<PhysicalMethod> {
        let m: PanelModel = model
        return Binding<PhysicalMethod>(get: { m.methodPreference }, set: { m.onSelectMethod($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.on.rectangle.slash").frame(width: 18).foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Monitör kapatma yöntemi").font(.system(size: 12, weight: .medium))
                    Text("Emin değilsen Otomatik'te bırak").font(.system(size: 10)).foregroundColor(.secondary)
                }
                Spacer()
            }
            Picker("", selection: selection) {
                ForEach(PhysicalMethod.allCases) { (m: PhysicalMethod) in
                    Text(m.title).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .cardStyle()
    }
}

/// Etiket : değer satırı (ızgara görünümü).
private struct StatusRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 14)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private struct StatusGridCard: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        let info: SettingsInfo = model.settingsInfo
        return VStack(alignment: .leading, spacing: 7) {
            StatusRow(icon: "switch.2", label: "Monitör kontrolü", value: info.method)
            StatusRow(icon: "display", label: "Monitörler", value: info.monitors)
            StatusRow(icon: "rectangle.dashed", label: "Sanal ekran", value: info.virtualScreen)
            StatusRow(icon: "app.badge", label: "Sanal ekran aracı", value: info.betterDisplay)
            StatusRow(icon: "bolt", label: "Enerji", value: info.power)
            Divider().opacity(0.2)
            StatusRow(icon: "memorychip", label: "Bellek", value: model.memoryText)
            StatusRow(icon: "info.circle", label: "Sürüm", value: model.appVersion)
        }
        .cardStyle()
    }
}

// MARK: - Monitör kartı

private struct MonitorCard: View {
    let monitor: MonitorSnapshot
    @ObservedObject var card: BrightnessCardModel
    let panel: PanelModel

    var body: some View {
        let dimmed: Bool = !(monitor.isActive || monitor.desiredEnabled)
        let menuTitle: String = monitor.forceSoftware ? "Monitörün kendi parlaklığını tekrar dene" : "Ekranı yazılımla karart"
        return VStack(alignment: .leading, spacing: 10) {
            MonitorCardHeader(monitor: monitor, panel: panel)
            MonitorBrightnessRow(monitor: monitor, card: card, panel: panel)
        }
        .cardStyle()
        .opacity(dimmed ? 0.7 : 1)
        .contextMenu {
            Button(menuTitle, action: { panel.onForceSoftware(monitor.key, !monitor.forceSoftware) })
        }
    }
}

private struct MonitorCardHeader: View {
    let monitor: MonitorSnapshot
    let panel: PanelModel

    private var enabled: Binding<Bool> {
        let key: String = monitor.key
        let current: Bool = monitor.desiredEnabled
        let p: PanelModel = panel
        return Binding<Bool>(get: { current }, set: { p.onToggleMonitor(key, $0) })
    }

    var body: some View {
        let iconColor: Color = monitor.isActive ? .accentColor : .secondary
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "display")
                .font(.system(size: 18))
                .foregroundColor(iconColor)
                .frame(width: 22)
            MonitorTitleBlock(monitor: monitor)
            Spacer()
            Toggle("", isOn: enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
    }
}

private struct MonitorTitleBlock: View {
    let monitor: MonitorSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(monitor.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Label(monitor.port, systemImage: "cable.connector")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text(monitor.resolution)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }
}

private struct MonitorBrightnessRow: View {
    let monitor: MonitorSnapshot
    @ObservedObject var card: BrightnessCardModel
    let panel: PanelModel

    /// Değer değişince (sürüklenirken) birleştiriciye gönderilir; bırakınca final=true.
    private var level: Binding<Double> {
        let c: BrightnessCardModel = card
        let p: PanelModel = panel
        return Binding<Double>(
            get: { c.level },
            set: { (v: Double) in
                c.level = v
                if c.editing { p.onBrightness(c.key, v, false) }
            })
    }

    private func editingChanged(_ isEditing: Bool) {
        card.editing = isEditing
        if !isEditing { panel.onBrightness(card.key, card.level, true) }
    }

    var body: some View {
        let percentValue: Int = Int(card.level.rounded())
        let percent: String = "\(percentValue)%"
        return HStack(spacing: 8) {
            Image(systemName: "sun.min").font(.system(size: 11)).foregroundColor(.secondary)
            Slider(value: level, in: 0...100, onEditingChanged: editingChanged)
                .controlSize(.small)
                .disabled(!monitor.isActive)
            Image(systemName: "sun.max.fill").font(.system(size: 11)).foregroundColor(.secondary)
            Text(percent)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .frame(width: 32, alignment: .trailing)
                .foregroundColor(.secondary)
            MethodBadge(monitor: monitor)
        }
    }
}

private struct MethodBadge: View {
    let monitor: MonitorSnapshot

    private var text: String {
        switch monitor.brightnessMethod {
        case .ddc: return "monitör"
        case .software: return "karartma"
        case .unknown: return "?"
        }
    }

    private var color: Color {
        switch monitor.brightnessMethod {
        case .ddc: return .green
        case .software: return .orange
        case .unknown: return .gray
        }
    }

    private var tooltip: String {
        if monitor.autoSoftware {
            return "Bu monitör parlaklık komutuna yanıt vermedi (çoğu zaman dock ya da adaptör yüzünden), bu yüzden görüntü yazılımla karartılıyor. Sağ tıklayıp tekrar deneyebilirsin."
        }
        if monitor.brightnessMethod == .software { return "Görüntü yazılımla karartılıyor. Sağ tıklayıp monitörün kendi parlaklığını deneyebilirsin." }
        return "Monitörün kendi parlaklığı değişiyor. Sağ tıklayıp yazılımla karartmaya geçebilirsin."
    }

    var body: some View {
        let c: Color = color
        return Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(c.opacity(0.18)))
            .foregroundColor(c)
            .help(tooltip)
    }
}

// MARK: - Araçlar (Tools) → Fan kontrolü

private struct ToolsTab: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "FAN KONTROLÜ")
            FanToolCard(model: model)
            SectionTitle(text: "SİSTEM")
            SystemStatsCard(model: model)
            KeepAwakeCard(model: model)
            SectionTitle(text: "DİSK")
            DiskCleanerCard(cleaner: model.cleaner)
        }
    }
}

private struct FanToolCard: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FanHeader(model: model)
            FanCardBody(model: model)
        }
        .cardStyle()
    }
}

private struct FanHeader: View {
    @ObservedObject var model: PanelModel

    private var fans: [FanInfo] { model.fanStatus?.fans ?? [] }

    private var spinRPM: Double {
        let list = fans
        guard !list.isEmpty else { return 0 }
        return list.map { $0.actual }.reduce(0, +) / Double(list.count)
    }

    private var spinMax: Double { fans.map { $0.maximum }.max() ?? 0 }

    private var subtitle: String {
        guard let st = model.fanStatus else { return "Okunuyor…" }
        if st.fans.isEmpty { return st.error ?? "Bu Mac'te fan yok" }
        let n = st.fans.count
        let rpm = Int(spinRPM.rounded())
        return "\(n) fan · \(rpm) RPM · \(model.fanMode.title)"
    }

    var body: some View {
        let rpm: Double = (model.panelOpen && model.toolsVisible) ? spinRPM : 0
        return HStack(spacing: 12) {
            SpinningFanView(rpm: rpm, maxRPM: spinMax, tintKey: model.fanMode.rawValue)
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text("Fanlar").font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
            TempColumn(cpu: model.fanStatus?.cpuTemp, gpu: model.fanStatus?.gpuTemp)
        }
    }
}

private struct TempColumn: View {
    let cpu: Double?
    let gpu: Double?
    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            TempChip(label: "CPU", value: cpu)
            TempChip(label: "GPU", value: gpu)
        }
    }
}

private struct TempChip: View {
    let label: String
    let value: Double?

    var body: some View {
        let text: String = value.map { "\(Int($0.rounded()))°" } ?? "—"
        let v: Double = value ?? 0
        let color: Color = v >= 90 ? .red : (v >= 75 ? .orange : .secondary)
        return HStack(spacing: 4) {
            Text(label).font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
            Text(text).font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundColor(color)
        }
    }
}

private struct FanCardBody: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        let st: FanStatus? = model.fanStatus
        if st == nil {
            HStack { ProgressView().controlSize(.small); Text("Fanlar okunuyor…").font(.system(size: 11)).foregroundColor(.secondary) }
        } else if let s = st, s.fans.isEmpty {
            InfoRow(icon: "wind", text: s.error.map { _ in "Fan bilgisi okunamadı" } ?? "Bu Mac'te fan yok")
        } else {
            FanControls(model: model)
        }
    }
}

private struct FanControls: View {
    @ObservedObject var model: PanelModel

    private var binding: Binding<FanMode> {
        Binding<FanMode>(get: { model.fanMode }, set: { newValue in model.onFanMode(newValue) })
    }

    var body: some View {
        let fans: [FanInfo] = model.fanStatus?.fans ?? []
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("", selection: binding) {
                    ForEach(FanMode.allCases) { m in Text(m.title).tag(m) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(model.fanApplying || !model.fanHelperInstalled)
                if model.fanApplying { ProgressView().controlSize(.small).scaleEffect(0.7) }
            }
            ForEach(fans, id: \.index) { fan in FanRow(fan: fan) }
            FanNoteView(model: model)
        }
    }
}

private struct FanRow: View {
    let fan: FanInfo

    var body: some View {
        let span: Double = max(1, fan.maximum)
        let fraction: Double = max(0, min(1, fan.actual / span))
        let rpm: String = "\(Int(fan.actual.rounded())) RPM"
        let range: String = "\(Int(fan.minimum))–\(Int(fan.maximum))"
        let tint: Color = fraction > 0.85 ? .red : (fraction > 0.55 ? .orange : .accentColor)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Fan \(fan.index + 1)").font(.system(size: 11, weight: .medium))
                if fan.manual {
                    Text("ELLE").font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                        .foregroundColor(.orange)
                }
                Spacer()
                Text(rpm).font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(tint)
                .animation(.easeInOut(duration: 0.8), value: fraction)
            Text(range + " RPM").font(.system(size: 9)).foregroundColor(.secondary)
        }
    }
}

private struct FanNoteView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        let text: String
        if !model.fanHelperInstalled {
            text = "Fan hızını değiştirmek için kurulumu bir kez daha çalıştır. Şimdilik sadece izleyebilirsin."
        } else if let n = model.fanNote {
            text = n
        } else {
            switch model.fanMode {
            case .auto: text = "Fanları Mac kendisi yönetiyor."
            case .half: text = "Fanlar yarı hızda döner. Mac çok ısınırsa kendiliğinden tam hıza çıkar."
            case .max: text = "Fanlar tam hızda döner. Mac uyuyunca ya da uygulama kapanınca normale döner."
            }
        }
        return Text(text)
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Dönen fan ikonu: Core Animation ile döner (CPU maliyeti yok); hız RPM'e göre layer.speed ile
/// kesintisiz değiştirilir. Panel kapanınca görünüm yok edilir → sıfır maliyet.
struct SpinningFanView: NSViewRepresentable {
    let rpm: Double
    let maxRPM: Double
    let tintKey: String

    func makeNSView(context: Context) -> FanSpinNSView { FanSpinNSView() }

    func updateNSView(_ nsView: FanSpinNSView, context: Context) {
        nsView.update(rpm: rpm, maxRPM: maxRPM, tintKey: tintKey)
    }
}

final class FanSpinNSView: NSView {
    private let blade = CALayer()
    private var currentSpeed: Float = -1
    private var currentTint: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(blade)
        blade.contentsGravity = .resizeAspect
        let anim = CABasicAnimation(keyPath: "transform.rotation.z")
        anim.fromValue = 0
        anim.toValue = -2 * Double.pi
        anim.duration = 1
        anim.repeatCount = .infinity
        anim.isRemovedOnCompletion = false
        blade.add(anim, forKey: "spin")
        blade.speed = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) yok") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blade.frame = bounds
        CATransaction.commit()
        if let scale = window?.backingScaleFactor { blade.contentsScale = scale }
    }

    func update(rpm: Double, maxRPM: Double, tintKey: String) {
        if blade.superlayer == nil { layer?.addSublayer(blade) }
        if currentTint != tintKey {
            currentTint = tintKey
            let tint: NSColor
            switch tintKey {
            case "max": tint = .systemRed
            case "half": tint = .systemOrange
            default: tint = .controlAccentColor
            }
            blade.contents = Self.image(tint: tint)
        }
        // Görsel hız: azami devirde ~4 tur/sn, düşük devirde ~0,4 tur/sn; 0 RPM → durur.
        let speed: Float
        if rpm < 50 {
            speed = 0
        } else {
            let ref = maxRPM > 0 ? maxRPM : 6000
            speed = Float(0.4 + 3.6 * max(0, min(1, rpm / ref)))
        }
        guard abs(speed - currentSpeed) > 0.05 else { return }
        currentSpeed = speed
        // Kesintisiz hız değişimi: mevcut yerel zamanı sabitle, sonra hızı değiştir.
        let now = CACurrentMediaTime()
        let local = blade.convertTime(now, from: nil)
        blade.timeOffset = local
        blade.beginTime = now
        blade.speed = speed
    }

    private static func image(tint: NSColor) -> CGImage? {
        let names = ["fan.fill", "fanblades.fill", "fan", "wind"]
        var base: NSImage?
        for n in names {
            if let img = NSImage(systemSymbolName: n, accessibilityDescription: "Fan") { base = img; break }
        }
        guard let symbol = base else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: 30, weight: .regular)
        let sized = symbol.withSymbolConfiguration(config) ?? symbol
        let side: CGFloat = 84
        let out = NSImage(size: NSSize(width: side, height: side))
        out.lockFocus()
        let s = sized.size
        let scale = min(side / max(s.width, 1), side / max(s.height, 1)) * 0.9
        let w = s.width * scale, h = s.height * scale
        let rect = NSRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h)
        sized.draw(in: rect)
        tint.set()
        rect.fill(using: .sourceAtop)
        out.unlockFocus()
        var r = NSRect(x: 0, y: 0, width: side, height: side)
        return out.cgImage(forProposedRect: &r, context: nil, hints: nil)
    }
}
