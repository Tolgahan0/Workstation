import AppKit

// Remote modunda: (1) bu Mac'e takılı klavye/fareden girdi gelirse monitörleri geri aç (Masaüstü),
// (2) uzaktan erişim teşhisi (Tailscale adresi, Ekran Paylaşımı açık mı) ve 10 dk'da bağlanan yoksa günlüğe ipucu.
// Bağlanan yok diye Remote KENDİLİĞİNDEN bırakılmaz: kullanıcı dışarıdayken boş odada monitörleri açmak işe yaramaz,
// bağlantı sonradan gelirse istemci boyutundaki sanal ekran kaybolur; eve dönünce klavye/fare zaten geri getirir.

extension AppDelegate {
    func startRemoteWatchers() {
        stopRemoteWatchers()
        if LocalInputPolicy.enabled {
            localInput.onLocalInput = { [weak self] device in
                guard let self = self, self.currentMode == .remote, !self.isTransitioning, !self.countdownActive else { return }
                Log.info("Remote: bu Mac'e takılı aygıttan girdi (\(device)) → monitörler açılıyor (Masaüstü)")
                self.localInput.stop()
                self.requestMode(.desktop, source: L("yerel klavye/fare (%@)", device))
            }
            localInput.start()
        }
        resourceQueue.async {
            let diag = RemoteAccessDiagnostics.current()
            Log.info("Remote erişim: \(diag.summary)")
            if !diag.screenSharingEnabled {
                DispatchQueue.main.async { [weak self] in
                    self?.panelModel.statusNote = L("Ekran Paylaşımı kapalı: Sistem Ayarları › Genel › Paylaşma › Ekran Paylaşımı")
                }
            }
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.currentMode == .remote else { return }
            guard !RemoteSessionProbe.current().screenSharing else { return }
            self.resourceQueue.async {
                let diag = RemoteAccessDiagnostics.current()
                Log.warn("Remote: 10 dk'dır Ekran Paylaşımı bağlantısı yok (\(diag.summary)). Dışarıdan bağlanırken .local adı / ev IP'si değil \(diag.tailscaleIP.map { "vnc://\($0)" } ?? "Tailscale adresi") kullanılmalı.")
            }
        }
        remoteDiagItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 600, execute: item)
    }

    func stopRemoteWatchers() {
        localInput.stop()
        remoteDiagItem?.cancel()
        remoteDiagItem = nil
    }
}
