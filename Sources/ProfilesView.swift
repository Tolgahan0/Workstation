import SwiftUI

// Masaüstü sekmesi → profiller (hızlı uygula / kaydet). Makro yok.

struct ProfilesCard: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(text: "PROFİLLER")
                Spacer()
                if let note = model.profileNote {
                    Text(note).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                }
            }
            ProfileChips(model: model)
            ProfileSaveRow(model: model)
        }
        .cardStyle()
    }
}

private struct ProfileChips: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        if model.profiles.isEmpty {
            Text("Henüz profil yok. Monitörleri/parlaklığı/fanı ayarlayıp bir ad vererek kaydedin.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.profiles) { (p: WorkspaceProfile) in
                        ProfileChip(profile: p, model: model)
                    }
                }
            }
        }
    }
}

private struct ProfileChip: View {
    let profile: WorkspaceProfile
    @ObservedObject var model: PanelModel

    var body: some View {
        let p: WorkspaceProfile = profile
        let m: PanelModel = model
        return Button(action: { m.onApplyProfile(p.id) }) {
            Label(p.name, systemImage: "square.stack.3d.up")
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.accentColor.opacity(0.22)))
        }
        .buttonStyle(.plain)
        .help("\(p.summary)\nSağ tık: üzerine kaydet / sil")
        .contextMenu {
            Button("Şu anki durumla güncelle") { m.onSaveProfile(p.name) }
            Button("Sil") { m.onDeleteProfile(p.id) }
        }
    }
}

private struct ProfileSaveRow: View {
    @ObservedObject var model: PanelModel

    private var name: Binding<String> {
        let m: PanelModel = model
        return Binding<String>(get: { m.newProfileName }, set: { m.newProfileName = $0 })
    }

    private func save() {
        let n = model.newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        model.onSaveProfile(n)
        model.newProfileName = ""
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField("Profil adı (ör. Kod, Film)", text: name, onCommit: save)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
            Button(action: save) {
                Label("Kaydet", systemImage: "plus")
                    .font(.system(size: 11, weight: .medium))
            }
            .disabled(model.newProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}
