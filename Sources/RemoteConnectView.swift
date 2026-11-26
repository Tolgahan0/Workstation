import SwiftUI
import AppKit

// Remote sekmesi → "Uyandır ve bağlan" kartı: Mac mini'nin MAC/IP'si ve istemcide çalıştırılacak komut.
// (Makro yok; durum PanelModel'de.)

struct WakeConnectCard: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("Uzaktan uyandır ve bağlan"), systemImage: "wifi.router")
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
                CopyLine(label: L("Bağlantı"), value: n.friendlyInterface.isEmpty ? "—" : n.friendlyInterface, copy: "")
                CopyLine(label: "MAC", value: n.mac.isEmpty ? L("bulunamadı") : n.mac, copy: n.mac)
                CopyLine(label: "IP", value: n.ip.isEmpty ? "—" : n.ip, copy: n.ip)
                if n.remoteAddress.isEmpty {
                    Text(L("Tailscale bulunamadı: studio.local ve ev IP'si yalnızca ev ağında çalışır; dışarıdan bağlanamazsın."))
                        .font(.system(size: 10)).foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    CopyLine(label: L("Dışarıdan"), value: "vnc://\(n.remoteAddress)", copy: "vnc://\(n.remoteAddress)")
                }
                CopyLine(label: L("Komut"), value: n.connectCommand, copy: n.connectCommand)
                Text(L("Bu komutu bağlanacağın Mac'te Terminal'e yapıştır. Bu Mac uyuyorsa uyanır, Remote'a geçer ve ekranı açılır. Evden çıkmadan bir kez --setup çalıştır: dışarıdayken Tailscale adresine kendiliğinden geçer."))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.6)
                Text(L("Ağ bilgisi okunuyor…"))
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
            .help(L("Kopyala"))
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

/// MacBook'ta (istemci) "Mac mini'ye bağlan"; Mac mini'de "Uzaktan uyandır ve bağlan" bilgisi.
struct RoleConnectCard: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var client: ClientModel

    var body: some View {
        if client.isClient {
            ClientConnectCard(client: client)
        } else {
            WakeConnectCard(model: model)
        }
    }
}

struct ClientConnectCard: View {
    @ObservedObject var client: ClientModel

    var body: some View {
        let c: ClientModel = client
        return VStack(alignment: .leading, spacing: 8) {
            Label(L("Mac mini'ye bağlan"), systemImage: "display.and.arrow.down")
                .font(.system(size: 12, weight: .semibold))
            CopyLine(label: L("Evde"), value: client.homeHost ?? "—", copy: "")
            CopyLine(label: L("Dışarıdan"), value: client.awayHost ?? L("Tailscale yok"), copy: "")
            if client.tailscaleInstalled && !client.tailscaleConnected {
                HStack(spacing: 6) {
                    NoteText(text: L("Tailscale bağlı değil: evden dışarıdayken bağlanmak için gerekli."))
                    Button(L("Aç")) { c.onStartTailscale() }.controlSize(.small)
                }
            } else if !client.tailscaleInstalled {
                NoteText(text: L("Tailscale kurulu değil: yalnızca ev ağından bağlanabilirsin."))
            }
            HStack {
                Button(client.busy ? L("Bağlanılıyor…") : L("Bağlan")) { c.onConnect() }
                    .disabled(client.busy)
                    .keyboardShortcut(.defaultAction)
                if let f = client.fitted {
                    Text(L("Ekran: %@", f)).font(.system(size: 10).monospacedDigit()).foregroundColor(.secondary)
                }
            }
            if let n = client.note { NoteText(text: n) }
        }
        .cardStyle()
    }
}
