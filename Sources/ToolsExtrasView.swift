import SwiftUI

// Tools sekmesi → Sistem kartı ve "Uyanık tut". Makro yok.

struct SystemStatsCard: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        let s: SystemStatsSnapshot? = model.stats
        return VStack(alignment: .leading, spacing: 8) {
            if let st = s {
                StatBar(icon: "cpu", label: "CPU",
                        value: st.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "…",
                        fraction: (st.cpuPercent ?? 0) / 100, tint: .accentColor)
                MemoryStatRow(stats: st)
                DiskStatRow(stats: st)
                NetworkStatRow(stats: st)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                    Text("Ölçülüyor…").font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
        }
        .cardStyle()
    }
}

private struct StatBar: View {
    let icon: String
    let label: String
    let value: String
    let fraction: Double
    let tint: Color

    var body: some View {
        let f: Double = max(0, min(1, fraction))
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 10)).foregroundColor(.secondary).frame(width: 14)
                Text(label).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(value).font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            ProgressView(value: f)
                .progressViewStyle(.linear)
                .tint(tint)
                .animation(.easeInOut(duration: 0.6), value: f)
        }
    }
}

private struct MemoryStatRow: View {
    let stats: SystemStatsSnapshot
    var body: some View {
        let total: Double = Double(max(stats.memTotal, 1))
        let used: Double = Double(stats.memUsed)
        let tint: Color = stats.pressure >= 4 ? .red : (stats.pressure == 2 ? .orange : .green)
        let text: String = "\(StatsFormat.bytes(used)) / \(StatsFormat.bytes(total)) · \(StatsFormat.pressureText(stats.pressure))"
        return StatBar(icon: "memorychip", label: "RAM", value: text, fraction: used / total, tint: tint)
    }
}

private struct DiskStatRow: View {
    let stats: SystemStatsSnapshot
    var body: some View {
        let freeFrac: Double = stats.diskFreeFraction ?? 0
        let tint: Color = freeFrac < 0.10 ? .red : (freeFrac < 0.2 ? .orange : .accentColor)
        let text: String = stats.diskFree.map { "\(StatsFormat.bytes(Double($0))) boş" } ?? "—"
        return StatBar(icon: "internaldrive", label: "Disk", value: text, fraction: 1 - freeFrac, tint: tint)
    }
}

private struct NetworkStatRow: View {
    let stats: SystemStatsSnapshot
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "network").font(.system(size: 10)).foregroundColor(.secondary).frame(width: 14)
            Text("Ağ").font(.system(size: 11, weight: .medium))
            Spacer()
            Label(StatsFormat.rate(stats.netIn), systemImage: "arrow.down")
                .font(.system(size: 11).monospacedDigit())
            Label(StatsFormat.rate(stats.netOut), systemImage: "arrow.up")
                .font(.system(size: 11).monospacedDigit())
        }
    }
}

struct KeepAwakeCard: View {
    @ObservedObject var model: PanelModel

    private var onBinding: Binding<Bool> {
        let m: PanelModel = model
        return Binding<Bool>(get: { m.keepAwakeOn }, set: { m.onKeepAwake($0, m.keepAwakeDuration) })
    }

    private var durationBinding: Binding<KeepAwake.Duration> {
        let m: PanelModel = model
        return Binding<KeepAwake.Duration>(get: { m.keepAwakeDuration }, set: { d in
            m.keepAwakeDuration = d
            if m.keepAwakeOn { m.onKeepAwake(true, d) }
        })
    }

    var body: some View {
        let subtitle: String
        if model.keepAwakeOn {
            if let u = model.keepAwakeUntil {
                let f = DateFormatter()
                f.dateFormat = "HH:mm"
                subtitle = "Açık · \(f.string(from: u))'e kadar"
            } else {
                subtitle = "Açık · sen kapatana kadar"
            }
        } else {
            subtitle = "Uzun bir iş bitene kadar Mac uyumaz"
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                CardTitleRow(icon: model.keepAwakeOn ? "cup.and.saucer.fill" : "cup.and.saucer",
                             title: "Uyanık tut", subtitle: subtitle)
                Toggle("", isOn: onBinding).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            Picker("", selection: durationBinding) {
                ForEach(KeepAwake.Duration.allCases) { (d: KeepAwake.Duration) in Text(d.title).tag(d) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .cardStyle()
    }
}
