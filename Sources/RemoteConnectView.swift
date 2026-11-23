import SwiftUI
import AppKit

// Remote sekmesi → "Uyandır ve bağlan" kartı: Mac mini'nin MAC/IP'si ve istemcide çalıştırılacak komut.
// (Makro yok; durum PanelModel'de.)

struct WakeConnectCard: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Uzaktan uyandır ve bağlan", systemImage: "wifi.router")
                .font(.system(size: 12, weight: .semibold))
            WakeConnectBody(info: model.netInfo)
        }
        .cardStyle()
    }
}

private struct WakeConnectBody: View {
    let info: NetworkInfo?

    var body: some View {
        if let n = info {
            VStack(alignment: .leading, spacing: 6) {
                CopyLine(label: "Bağlantı", value: n.friendlyInterface.isEmpty ? "—" : n.friendlyInterface, copy: "")
                CopyLine(label: "MAC", value: n.mac.isEmpty ? "bulunamadı" : n.mac, copy: n.mac)
                CopyLine(label: "IP", value: n.ip.isEmpty ? "—" : n.ip, copy: n.ip)
                CopyLine(label: "Komut", value: n.connectCommand, copy: n.connectCommand)
                Text("Bu komutu bağlanacağın Mac'te Terminal'e yapıştır. Bu Mac uyuyorsa uyanır, Remote'a geçer ve ekranı açılır.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.6)
                Text("Ağ bilgisi okunuyor…")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
    }
}

private struct CopyLine: View {
    let label: String
    let value: String
    let copy: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
                .frame(width: 42, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button(action: { PasteboardCopy.copy(copy) }) {
                Image(systemName: "doc.on.doc").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
            .disabled(copy.isEmpty)
            .help("Kopyala")
        }
    }
}

enum PasteboardCopy {
    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
