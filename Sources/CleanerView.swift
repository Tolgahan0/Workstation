import SwiftUI
import AppKit

// Tools › Disk kartı ve Temizleyici sayfası. Makro YOK (@State yok): durum CleanerModel'de.

final class CleanerModel: ObservableObject {
    @Published var settings = CleanerSettings.load()
    @Published var report: ScanReport?
    @Published var scanning = false
    @Published var cleaning = false
    @Published var stage = ""
    @Published var fraction: Double = 0
    @Published var lastRun: CleanRunRecord? = CleanHistory.load().last
    @Published var expanded: Set<String> = []
    @Published var confirming = false
    @Published var diskFree: Int64?
    @Published var diskTotal: Int64?
    /// Tarama/temizlik özeti ve uyarılar 5 sn sonra kaybolur (ayrıntı günlükte ve raporda kalır).
    @Published var note: String? {
        didSet {
            guard note != nil else { return }
            noteGeneration += 1
            let g = noteGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + PanelModel.noteLifetime) { [weak self] in
                guard let self = self, self.noteGeneration == g else { return }
                self.note = nil
            }
        }
    }
    private var noteGeneration = 0
    @Published var newNeverTouch = ""
    @Published var newRoot = ""

    var onScan: () -> Void = {}
    var onCancel: () -> Void = {}
    var onClean: () -> Void = {}
    var onSettings: (CleanerSettings) -> Void = { _ in }
    var onOpenPage: () -> Void = {}

    var busy: Bool { scanning || cleaning }

    func update(_ change: (inout CleanerSettings) -> Void) {
        var s = settings
        change(&s)
        onSettings(s)
    }

    func toggleExpanded(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    func setItem(_ id: String, selected: Bool) {
        guard var r = report else { return }
        for i in r.results.indices {
            if let j = r.results[i].items.firstIndex(where: { $0.id == id }) {
                r.results[i].items[j].selected = selected && r.results[i].items[j].isActionable
            }
        }
        report = r
    }

    func setCategory(_ c: CleanCategory, selected: Bool) {
        guard var r = report, let i = r.results.firstIndex(where: { $0.category == c }) else { return }
        for j in r.results[i].items.indices { r.results[i].items[j].selected = selected && r.results[i].items[j].isActionable }
        report = r
    }

    var trashCount: Int {
        (report?.selectedItems ?? []).filter { i in
            if case .delete = i.action {
                return i.category.deleteStyle == .trash || (i.category.deleteStyle == .cache && !settings.permanentForCaches)
            }
            return false
        }.count
    }
}

enum CleanerFormat {
    static func bytes(_ b: Int64) -> String { CleanerRules.formatBytes(b) }
    static func lastRunText(_ r: CleanRunRecord?) -> String {
        guard let r = r else { return L("Henüz temizlik yapılmadı") }
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateFormat = "d MMM HH:mm"
        let total = r.reclaimed + r.trashed
        let who = r.trigger == .daily || r.trigger == .lowSpace ? L("otomatik") : "elle"
        return L("Son temizlik: %@ (%@) · %@ açıldı", f.string(from: r.date), who, bytes(total))
    }
}

// MARK: - Tools kartı

struct DiskCleanerCard: View {
    @ObservedObject var cleaner: CleanerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                DiskRing(free: cleaner.diskFree, total: cleaner.diskTotal)
                DiskCardText(cleaner: cleaner)
                Spacer(minLength: 0)
            }
            CleanerProgressRow(cleaner: cleaner)
            DiskCardButtons(cleaner: cleaner)
        }
        .cardStyle()
    }
}

struct DiskRing: View {
    let free: Int64?
    let total: Int64?

    var body: some View {
        let t: Double = Double(max(total ?? 1, 1))
        let f: Double = Double(free ?? 0)
        let usedFrac: Double = total == nil ? 0 : max(0, min(1, 1 - f / t))
        let freeFrac: Double = 1 - usedFrac
        let tint: Color = freeFrac < 0.1 ? .red : (freeFrac < 0.2 ? .orange : .green)
        return ZStack {
            Circle().stroke(Color.white.opacity(0.1), lineWidth: 6)
            Circle()
                .trim(from: 0, to: usedFrac)
                .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: usedFrac)
            VStack(spacing: 0) {
                Text(String(format: "%%%.0f", freeFrac * 100)).font(.system(size: 12, weight: .bold).monospacedDigit())
                Text(L("boş")).font(.system(size: 8)).foregroundColor(.secondary)
            }
        }
        .frame(width: 52, height: 52)
    }
}

private struct DiskCardText: View {
    @ObservedObject var cleaner: CleanerModel
    var body: some View {
        let free: String = cleaner.diskFree.map { CleanerFormat.bytes($0) + L(" boş alan") } ?? L("Disk ölçülüyor…")
        let found: String? = cleaner.report.map { r in
            r.selectedBytes > 0 ? L("%@ temizlenebilir", CleanerFormat.bytes(r.selectedBytes)) : L("Temizlenecek bir şey bulunamadı")
        }
        return VStack(alignment: .leading, spacing: 3) {
            Text(L("Geliştirici Temizleyici")).font(.system(size: 12, weight: .semibold))
            Text(free).font(.system(size: 11)).foregroundColor(.secondary)
            if let f = found {
                Text(f).font(.system(size: 11, weight: .medium)).foregroundColor(.accentColor)
            } else {
                Text(CleanerFormat.lastRunText(cleaner.lastRun)).font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
    }
}

private struct CleanerProgressRow: View {
    @ObservedObject var cleaner: CleanerModel
    var body: some View {
        if cleaner.busy {
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: cleaner.fraction).progressViewStyle(.linear)
                Text(cleaner.stage).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
            }
        } else if let n = cleaner.note {
            Text(n).font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct DiskCardButtons: View {
    @ObservedObject var cleaner: CleanerModel
    var body: some View {
        HStack(spacing: 8) {
            if cleaner.busy {
                SmallButton(title: L("Durdur"), icon: "stop.fill", prominent: false) { cleaner.onCancel() }
            } else {
                SmallButton(title: L("Tara"), icon: "magnifyingglass", prominent: cleaner.report == nil) { cleaner.onScan() }
            }
            if cleaner.report != nil {
                SmallButton(title: L("Ayrıntılar ve temizle"), icon: "list.bullet", prominent: true) { cleaner.onOpenPage() }
            }
            Spacer()
        }
    }
}

struct SmallButton: View {
    let title: String
    let icon: String
    let prominent: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(prominent ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.1)))
                .foregroundColor(.white)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Temizleyici sayfası

struct CleanerPage: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: { model.page = .main }) { Label(L("Geri"), systemImage: "chevron.left") }
                .buttonStyle(.plain).foregroundColor(.secondary).font(.system(size: 12, weight: .medium))
            DiskCleanerCard(cleaner: model.cleaner)
            ScrollView(.vertical, showsIndicators: true) {
                CleanerCategoryList(cleaner: model.cleaner).padding(.trailing, 4)
            }
            .frame(height: 380)
            CleanerFooter(cleaner: model.cleaner)
        }
    }
}

private struct CleanerCategoryList: View {
    @ObservedObject var cleaner: CleanerModel
    var body: some View {
        let results: [CategoryResult] = cleaner.report?.results ?? []
        return LazyVStack(alignment: .leading, spacing: 8) {
            if let r = cleaner.report, !r.inUseCheckOK {
                InfoRow(icon: "exclamationmark.triangle", text: L("Açık dosyalar kontrol edilemedi. Güvenlik için projelere ve önbelleklere dokunulmayacak."))
            }
            if results.isEmpty && !cleaner.busy {
                Text(L("Önce “Tara”ya bas. Tarama hiçbir şeyi silmez, sadece neyin temizlenebileceğini gösterir."))
                    .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ScanCategoryPicker(cleaner: cleaner)
            ForEach(CleanGroup.allCases, id: \.self) { (g: CleanGroup) in
                let rs: [CategoryResult] = results.filter { $0.category.group == g && (!$0.items.isEmpty || $0.note != nil) }
                if !rs.isEmpty {
                    SectionTitle(text: g.title.uppercased(with: L10n.locale))
                    ForEach(rs) { (r: CategoryResult) in CategoryCard(cleaner: cleaner, result: r) }
                }
            }
        }
    }
}

/// Hangi kategorilerin taranacağı (açılır kart).
private struct ScanCategoryPicker: View {
    @ObservedObject var cleaner: CleanerModel
    private func binding(_ c: CleanCategory) -> Binding<Bool> {
        let m = cleaner
        return Binding<Bool>(get: { m.settings.isEnabled(c) }, set: { v in m.update { $0.enabled[c.rawValue] = v } })
    }
    var body: some View {
        let open: Bool = cleaner.expanded.contains("_categories")
        let count: Int = CleanCategory.allCases.filter { cleaner.settings.isEnabled($0) }.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "slider.horizontal.3").font(.system(size: 11)).foregroundColor(.secondary)
                Text(L("Neler taransın? (%@/%@)", count, CleanCategory.allCases.count)).font(.system(size: 11, weight: .medium))
                Spacer()
                Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 9)).foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { cleaner.toggleExpanded("_categories") }
            if open {
                ForEach(CleanGroup.allCases, id: \.self) { (g: CleanGroup) in
                    Text(g.title).font(.system(size: 10, weight: .bold)).foregroundColor(.secondary).padding(.top, 2)
                    ForEach(CleanCategory.inGroup(g)) { (c: CleanCategory) in ToggleRow(title: c.title, isOn: binding(c)) }
                }
            }
        }
        .cardStyle()
    }
}

private struct CategoryCard: View {
    @ObservedObject var cleaner: CleanerModel
    let result: CategoryResult

    var body: some View {
        let open: Bool = cleaner.expanded.contains(result.id)
        return VStack(alignment: .leading, spacing: 6) {
            CategoryHeader(cleaner: cleaner, result: result, open: open)
            if open {
                Text(result.category.hint).font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if let n = result.note { Text(n).font(.system(size: 10)).foregroundColor(.orange) }
                CategoryAgeRow(cleaner: cleaner, category: result.category)
                ForEach(Array(result.items.prefix(150))) { (i: CleanItem) in ItemRow(cleaner: cleaner, item: i) }
                if result.items.count > 150 {
                    Text(L("+%@ öğe daha", result.items.count - 150)).font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
        }
        .cardStyle()
    }
}

private struct CategoryHeader: View {
    @ObservedObject var cleaner: CleanerModel
    let result: CategoryResult
    let open: Bool

    private var selection: Binding<Bool> {
        let c = cleaner, r = result
        return Binding<Bool>(get: { r.actionable.contains { $0.selected } }, set: { c.setCategory(r.category, selected: $0) })
    }

    var body: some View {
        let actionable: Int = result.actionable.count
        let skipped: Int = result.items.filter { $0.skip != nil }.count
        var sub: String = actionable > 0 ? L("%@ öğe", actionable) : L("temizlenecek yok")
        if skipped > 0 { sub += L(" · %@ atlandı", skipped) }
        if result.category.suggestOnly { sub = L("%@ öneri · silinmez", result.items.count) }
        return HStack(spacing: 8) {
            if actionable > 0 && !result.category.suggestOnly {
                Toggle("", isOn: selection).toggleStyle(.checkbox).labelsHidden()
            } else {
                Image(systemName: result.category.group.icon).font(.system(size: 11)).foregroundColor(.secondary).frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(result.category.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text(sub).font(.system(size: 10)).foregroundColor(.secondary)
            }
            Spacer()
            Text(CleanerFormat.bytes(result.category.suggestOnly ? result.items.reduce(0) { $0 + $1.bytes } : result.selectedBytes))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundColor(result.selectedBytes > 0 ? .primary : .secondary)
            Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 9)).foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { cleaner.toggleExpanded(result.id) }
    }
}

private struct CategoryAgeRow: View {
    @ObservedObject var cleaner: CleanerModel
    let category: CleanCategory

    private var value: Binding<Int> {
        let c = cleaner, cat = category
        return Binding<Int>(get: { c.settings.age(cat) ?? 0 }, set: { v in c.update { $0.ageDays[cat.rawValue] = max(1, v) } })
    }

    var body: some View {
        if let d = cleaner.settings.age(category) {
            HStack {
                Text(L("%@ günden eski olanlar (değişince yeniden tara)", d)).font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
                Stepper("", value: value, in: 1...365).labelsHidden().controlSize(.mini)
            }
        }
    }
}

private struct ItemRow: View {
    @ObservedObject var cleaner: CleanerModel
    let item: CleanItem

    private var selection: Binding<Bool> {
        let c = cleaner, id = item.id
        return Binding<Bool>(get: { c.report?.results.lazy.flatMap { $0.items }.first { $0.id == id }?.selected ?? false },
                             set: { c.setItem(id, selected: $0) })
    }

    var body: some View {
        let dim: Bool = item.skip != nil
        let age: String = CleanerRules.ageText(item.modified)
        return HStack(alignment: .top, spacing: 6) {
            if item.isActionable {
                Toggle("", isOn: selection).toggleStyle(.checkbox).labelsHidden().controlSize(.small)
            } else {
                Image(systemName: dim ? "lock.fill" : "lightbulb").font(.system(size: 9)).foregroundColor(.secondary).frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 10, weight: .medium)).lineLimit(1).truncationMode(.middle)
                ItemMetaLine(item: item, age: age)
            }
            Spacer(minLength: 4)
            if item.bytes > 0 {
                Text(CleanerFormat.bytes(item.bytes)).font(.system(size: 10).monospacedDigit()).foregroundColor(.secondary)
            }
        }
        .opacity(dim ? 0.5 : 1)
        .help(item.path ?? item.title)
    }
}

private struct ItemMetaLine: View {
    let item: CleanItem
    let age: String
    var body: some View {
        HStack(spacing: 4) {
            if let s = item.skip {
                Text(s.text)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
            }
            if !item.detail.isEmpty { Text(item.detail).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1) }
            if !age.isEmpty { Text(age).font(.system(size: 9)).foregroundColor(.secondary) }
        }
    }
}

private struct CleanerFooter: View {
    @ObservedObject var cleaner: CleanerModel

    private var permanent: Binding<Bool> {
        let c = cleaner
        return Binding<Bool>(get: { c.settings.permanentForCaches }, set: { v in c.update { $0.permanentForCaches = v } })
    }

    var body: some View {
        let total: Int64 = cleaner.report?.selectedBytes ?? 0
        let count: Int = cleaner.report?.selectedItems.count ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            ToggleRow(title: L("Önbellekleri kalıcı sil (Çöp'e taşıma)"), isOn: permanent)
            if cleaner.confirming {
                CleanerConfirmBox(cleaner: cleaner, total: total, count: count)
            } else {
                StartButton(title: L("Temizle (%@)", CleanerFormat.bytes(total)), systemImage: "sparkles",
                            tint: .accentColor, disabled: count == 0 || cleaner.busy) { cleaner.confirming = true }
            }
        }
    }
}

private struct CleanerConfirmBox: View {
    @ObservedObject var cleaner: CleanerModel
    let total: Int64
    let count: Int

    var body: some View {
        let trash: Int = cleaner.trashCount
        let text: String = trash > 0
            ? L("%@ öğe temizlenecek (%@). %@ tanesi Çöp Sepeti'ne gider, istersen geri alabilirsin. Alan, Çöp boşaltılınca açılır.", count, CleanerFormat.bytes(total), trash)
            : L("%@ öğe temizlenecek (%@). Hepsi gerektiğinde kendiliğinden yeniden oluşur.", count, CleanerFormat.bytes(total))
        return VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Text(L("Her öğe silinmeden hemen önce bir kez daha kontrol edilir; o an kullanılıyorsa atlanır."))
                .font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                SmallButton(title: L("Vazgeç"), icon: "xmark", prominent: false) { cleaner.confirming = false }
                Spacer()
                SmallButton(title: L("Evet, temizle"), icon: "checkmark", prominent: true) {
                    cleaner.confirming = false
                    cleaner.onClean()
                }
            }
        }
        .cardStyle()
    }
}

