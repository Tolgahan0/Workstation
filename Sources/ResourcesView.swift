import SwiftUI

// Tools › Kaynaklar: canlı bellek/CPU/GPU kartı ve "Boştakileri kapat". Makro yok.

/// Ayrı model: 2 sn'lik örnekler yalnızca bu kartları yeniden çizer.
final class ResourceModel: ObservableObject {
    @Published var snapshot: ResourceSnapshot?
    @Published var idle: [IdleItem] = []
    /// Onay kartı açık mı (seçilenler kapatılmadan önce listelenir).
    @Published var confirming = false
    @Published var selected: Set<String> = []
    @Published var busy = false
    @Published var note: String?
    @Published var showDetails = false
    @Published var autoOnSwitch: Bool = ResourceModel.autoOnSwitchSaved {
        didSet { UserDefaults.standard.set(autoOnSwitch, forKey: ResourceModel.autoKey) }
    }

    static let autoKey = "closeIdleOnModeSwitch"
    static var autoOnSwitchSaved: Bool { UserDefaults.standard.bool(forKey: autoKey) }

    var onQuit: ([IdleItem]) -> Void = { _ in }

    func beginConfirm() {
        selected = Set(idle.map { $0.id })
        confirming = true
    }
}

struct ResourcesCard: View {
    @ObservedObject var res: ResourceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let s = res.snapshot {
                PressureRow(snapshot: s)
                MemoryBreakdownBar(memory: s.memory)
                HStack(spacing: 10) {
                    MiniStat(label: "CPU", value: s.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "…")
                    MiniStat(label: "GPU", value: s.gpuPercent.map { String(format: "%.0f%%", $0) } ?? "—")
                    MiniStat(label: L("Takas"), value: StatsFormat.bytes(Double(s.memory.swapUsed)))
                    Spacer(minLength: 0)
                }
                if !s.top.isEmpty {
                    Divider()
                    Text(L("En çok kullananlar")).font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                    ForEach(s.top.prefix(res.showDetails ? 8 : 5)) { u in TopAppRow(usage: u) }
                    Button(res.showDetails ? L("Daha az") : L("Daha fazla")) { res.showDetails.toggle() }
                        .buttonStyle(.plain).font(.system(size: 10)).foregroundColor(.accentColor)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                    Text(L("Ölçülüyor…")).font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
        }
        .cardStyle()
    }
}

private func pressureColor(_ level: Int) -> Color { level >= 4 ? .red : (level == 2 ? .yellow : .green) }

private struct PressureRow: View {
    let snapshot: ResourceSnapshot
    var body: some View {
        let level = snapshot.pressure
        let m = snapshot.memory
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(pressureColor(level)).frame(width: 8, height: 8)
                Text(L("Bellek baskısı")).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(StatsFormat.pressureText(level)).font(.system(size: 11, weight: .semibold))
                    .foregroundColor(level >= 2 ? pressureColor(level) : .primary)
            }
            Text(L("%@ / %@ kullanımda · önbellek gerektiğinde boşaltılır",
                   StatsFormat.bytes(Double(m.used)), StatsFormat.bytes(Double(m.total))))
                .font(.system(size: 10)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MemoryBreakdownBar: View {
    let memory: MemoryBreakdown

    var body: some View {
        let total = Double(max(memory.total, 1))
        let parts: [(String, UInt64, Color)] = [
            (L("Uygulama"), memory.app, .accentColor),
            (L("Sabit"), memory.wired, .orange),
            (L("Sıkıştırılmış"), memory.compressed, .purple),
            (L("Önbellek"), memory.cached, Color.gray.opacity(0.45)),
        ]
        return VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(0..<parts.count, id: \.self) { i in
                        Rectangle().fill(parts[i].2)
                            .frame(width: max(0, geo.size.width * CGFloat(min(1, Double(parts[i].1) / total)) - 1))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 6)
            .background(Color.gray.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            // İki satırlık açıklama (dar panelde taşmasın).
            ForEach([0, 2], id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(Array(row..<min(row + 2, parts.count)), id: \.self) { i in
                        HStack(spacing: 3) {
                            Circle().fill(parts[i].2).frame(width: 6, height: 6)
                            Text("\(parts[i].0) \(StatsFormat.bytes(Double(parts[i].1)))")
                                .font(.system(size: 9).monospacedDigit()).foregroundColor(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

private struct MiniStat: View {
    let label: String
    let value: String
    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 10)).foregroundColor(.secondary)
            Text(value).font(.system(size: 11, weight: .semibold).monospacedDigit())
        }
    }
}

private struct TopAppRow: View {
    let usage: AppUsage
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10)).foregroundColor(.secondary).frame(width: 14)
            Text(usage.title).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
            if usage.processCount > 1 {
                Text("×\(usage.processCount)").font(.system(size: 9)).foregroundColor(.secondary)
            }
            Spacer(minLength: 4)
            Text(String(format: "%.0f%%", usage.cpuPercent)).font(.system(size: 10).monospacedDigit()).foregroundColor(.secondary)
                .frame(width: 36, alignment: .trailing)
            Text(StatsFormat.bytes(Double(usage.footprint))).font(.system(size: 11, weight: .medium).monospacedDigit())
                .frame(width: 64, alignment: .trailing)
        }
    }

    private var icon: String {
        switch usage.kind {
        case .simulator: return "iphone"
        case .agent: return "terminal"
        case .system: return "gearshape"
        case .app: return "app"
        case .other: return "circle.dashed"
        }
    }
}

struct IdleCloserCard: View {
    @ObservedObject var res: ResourceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitleRow(icon: "moon.zzz", title: L("Boştakileri kapat"),
                         subtitle: L("Açık simülatörler, boşta kalan CLI ajanları ve Docker"))
            if res.confirming {
                ConfirmList(res: res)
            } else {
                if res.idle.isEmpty {
                    Text(L("Kapatılacak boşta bir şey yok")).font(.system(size: 11)).foregroundColor(.secondary)
                } else {
                    ForEach(res.idle) { it in
                        HStack(spacing: 6) {
                            Text(it.title).font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text(StatsFormat.bytes(Double(it.footprint))).font(.system(size: 11).monospacedDigit())
                        }
                    }
                    Button(L("Boştakileri kapat…")) { res.beginConfirm() }
                        .controlSize(.small).disabled(res.busy)
                }
            }
            if let n = res.note {
                Text(n).font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ToggleRow(title: L("Remote/Uyku'ya geçerken ağır boştakileri kapat"),
                      isOn: Binding<Bool>(get: { res.autoOnSwitch }, set: { res.autoOnSwitch = $0 }))
        }
        .cardStyle()
    }
}

private struct ConfirmList: View {
    @ObservedObject var res: ResourceModel

    var body: some View {
        let chosen = res.idle.filter { res.selected.contains($0.id) }
        return VStack(alignment: .leading, spacing: 6) {
            Text(L("Şunlar kapatılacak:")).font(.system(size: 11, weight: .semibold))
            ForEach(res.idle) { it in
                HStack(alignment: .top, spacing: 6) {
                    Toggle("", isOn: Binding<Bool>(get: { res.selected.contains(it.id) }, set: { on in
                        if on { res.selected.insert(it.id) } else { res.selected.remove(it.id) }
                    }))
                    .labelsHidden().toggleStyle(.checkbox).controlSize(.small)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(it.title).font(.system(size: 11, weight: .medium))
                        Text(it.detail).font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Text(StatsFormat.bytes(Double(it.footprint))).font(.system(size: 10).monospacedDigit()).foregroundColor(.secondary)
                }
            }
            Text(L("Düzgünce kapatılır (kaydedilmemiş iş kaybolabilir); öndeki uygulamaya ve sistem süreçlerine dokunulmaz."))
                .font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L("Vazgeç")) { res.confirming = false }.controlSize(.small)
                Spacer()
                Button(L("Kapat (%@)", chosen.count)) {
                    res.confirming = false
                    res.onQuit(chosen)
                }
                .controlSize(.small).keyboardShortcut(.defaultAction).disabled(chosen.isEmpty || res.busy)
            }
        }
    }
}
