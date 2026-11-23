# WorkstationMode

Mac mini (Apple Silicon) için menü çubuğu uygulaması. Üç çalışma modu arasında tek tıkla (veya SSH üzerinden tek komutla) geçiş yapar:

| Mod | Ekranlar | Güç (`pmset -a`) |
|---|---|---|
| **Masaüstü** | Fiziksel monitörler kendi kayıtlı durumlarına döner, sanal ekran **kapalı** | `sleep 0 displaysleep 15 lowpowermode 0` |
| **Uyku / Gece** | Sanal ekran **asla açılmaz**, fiziksel monitörler **kesik**, `pmset displaysleepnow` | `lowpowermode 1 sleep 1 displaysleep 1 womp 1` |
| **Remote** | Sanal ekran (bağlanan Mac'in boyutunda, HiDPI) açık → 1 sn → fiziksel monitörler **kesik** (tamamen uzaktan geliştirme için) | `sleep 0 disksleep 0 displaysleep 0 lowpowermode 0 tcpkeepalive 1 autorestart 1` |

**Geri sayım:** Uyku veya Remote sekmesinde **Başlat**'a basınca (ya da URL/SSH ile istendiğinde) her ekranın ortasında, azalan bir ilerleme halkasının içinde tek büyük bir sayı geri sayar (varsayılan 3 sn) ve sonra mod uygulanır. Ek açıklama yazısı yoktur. **İptal** düğmesi veya **Esc** ile vazgeçilebilir; SSH/URL ile tetiklenip kimse dokunmazsa süre dolunca kendiliğinden devam eder. Süre **Ayarlar > Geri sayım** bölümünden değiştirilir (0 = kapalı, en fazla 10). Masaüstü'ne dönüş beklemeden uygulanır.

**Simgeler:** Menü çubuğu simgesi **tek renk (şablon) Mac mini**'dir (SF Symbol `macmini.fill`, yoksa elle çizilmiş Mac mini); menü çubuğu kalınlığını tam kullanır ve açık/koyu menü çubuğuna göre otomatik beyaz/siyah olur. Sağ alttaki küçük renkli nokta modu gösterir: yok = Masaüstü · mavi = Uyku · yeşil = Remote · sarı = geçiş/geri sayım. Uygulama simgesi koyu grafit zemin üzerinde gümüş Mac Studio'dur; `AppIcon.icns` kurulumda `Tools/MakeIcon` ile üretilir (`iconutil`).

### Ekranlar nasıl kesiliyor?

- **Monitör kapatma yöntemi (Ayarlar > Monitör kapatma yöntemi):**
  - **Otomatik** (varsayılan): BetterDisplay kurulu ve CLI açıksa **BetterDisplay** (`set -tagID=<id> -connected=off/on`) — yalnızca seçilen monitörü temiz biçimde keser; değilse sistem API'si.
  - **BetterDisplay:** her zaman BetterDisplay; başaramadığı monitör için sistem API'sine düşülür.
  - **Sistem API:** macOS'un CoreGraphics özel API'si `CGSConfigureDisplayEnabled` (yoksa SkyLight `SLSConfigureDisplayEnabled`), `CGCompleteDisplayConfiguration(.forSession)` ile.
  - CG displayID ↔ BetterDisplay tagID eşlemesi displayID → hatırlanan donanım (vendor/model/seri) → ad sırasıyla yapılır ve saklanır. Fiziksel ekranlar `CGGetOnlineDisplayList` ile bulunur; dahili ekran ve BetterDisplay sanal/dummy ekranları ile **gruplar** (ör. "Varsayılan Grup") hariç tutulur. Kesilen ekranlar hatırlanır ve Masaüstü Modu'nda geri açılır.
- **Tek monitörü kapatınca diğerinin de kararması:** macOS her ekran yeniden yapılandırmasında tüm ekranları bir an karartabilir (önlenemez). Uygulama bu sırada kendi tetiklediği yeniden yapılandırma bildirimlerini **3 sn boyunca yok sayar**, ardından durumu **iki örnekle** (0,6 sn arayla) doğrular ve yalnızca istenen durumda olmayan monitöre dokunur — açık kalması gereken monitör asla kapatılıp açılmaz, ikinci flaş olmaz. Her adım (önce / hemen sonra / 1,8 sn sonra / düzeltme) günlüğe "Ekran durumu [...]" satırlarıyla yazılır.
- **BetterDisplay yalnızca sanal ekran için kullanılır** (oluşturma, bağlama, 1512x982 HiDPI çözünürlük).
- Özel API bulunamazsa (gelecekteki bir macOS sürümünde kaldırılırsa) otomatik olarak BetterDisplay `connected` yoluna düşülür (bu yol Pro gerektirir).
- `.forSession` sayesinde kesme işlemi oturum kapanana / Mac yeniden başlayana kadar sürer: bir şey ters giderse **yeniden başlatmak monitörleri her zaman geri getirir**.

Yalnızca Apple çerçevelerini kullanır (Cocoa/AppKit, Foundation, SwiftUI, CoreGraphics, IOKit); üçüncü parti Swift kütüphanesi yoktur. Dock'ta görünmez (`LSUIElement`).

## Panel (menü çubuğu)

Menü çubuğu simgesine tıklayınca koyu, yarı saydam bir panel açılır. Panel içeriği **yalnızca açıkken** oluşturulur, kapanınca bellekten atılır.

- **Başlık:** uygulama simgesi, `WorkstationMode`, geçerli mod ve durum hapı (**AKTİF** yeşil · **GEÇİŞ** sarı).
- **Sekmeler:** `Masaüstü | Uyku | Remote`. Sekme değiştirmek modu **değiştirmez**; her sekmenin kendi **Başlat** düğmesi vardır.
  - **Masaüstü:** monitör kartları; başka moddaysanız üstte **Masaüstü Moduna Dön** düğmesi.
  - **Uyku:** ne yapılacağının özeti + **Başlat**.
  - **Remote:** sanal ekran ön ayarı (aşağıya bakın), BetterDisplay durumu (yoksa **Şimdi kur** / kurulum ilerlemesi) + **Başlat** (Remote'dayken **Yeniden Uygula**).
- **Monitör kartları** (her harici monitör için ayrı):
  - Ad (EDID ürün adı: `NSScreen.localizedName`, IORegistry `DisplayAttributes > ProductName`, CoreDisplay) — sabit kodlanmış isim yok
  - **Bağlı olduğu port** (en iyi tahmin): `HDMI` veya `USB-C / Thunderbolt n`, ayrıca DCP çıkışı (`dispext0`, `dispext1`…)
  - Çözünürlük ve yenileme hızı
  - **Aç/kapa anahtarı** — yalnızca o monitörü etkiler
  - **Parlaklık kaydırıcısı** + rozet: `DDC` (donanım), `yazılım` (elle zorlandı) veya `yazılım·oto` (DDC doğrulanamadığı için otomatik geçildi). Karta sağ tıklayıp yazılım karartmayı zorlayabilir veya DDC'yi tekrar deneyebilirsiniz.
- **Alt bilgi:** **Ayarlar** (Günlük, monitörleri yeniden tara, sanal ekranı onar, BetterDisplay'i kur, monitör kapatma yöntemi, geri sayım süresi ve **Durum** ızgarası: ekran kontrolü, monitörler, sanal ekran, BetterDisplay sürümü, güç profili (`pmset -g`), canlı bellek kullanımı (yalnızca Ayarlar açıkken 2 sn'de bir), sürüm) ve **Çık**.

### Parlaklık (DDC doğrulama + yumuşak kaydırıcı)

- **Doğrulama:** Bir monitöre oturumda ilk kez DDC ile yazıldığında ~120 ms sonra değer **geri okunur**. Okuma başarısızsa veya değer değişmemişse (dock/adaptör DDC'yi iletmiyor demektir — "dock'taki monitör kararmıyor" sorununun sebebi) monitör **kalıcı olarak yazılım karartmaya** geçer (`yazılım·oto`). 3 ardışık yazma hatası da aynı sonucu verir. Sağ tık → "DDC'yi tekrar dene" bu kararı sıfırlar.
- **Birleştirme (coalescing):** Kaydırıcı sürüklenirken her olay monitöre gönderilmez; tek bir seri kuyruk yalnızca **en son değeri**, DDC için **en fazla ~150 ms'de bir** (yazılımda ~30 ms) yazar, aynı değeri tekrar yazmaz ve bırakıldığında son değeri **hemen** gönderir. Ana iş parçacığı hiç beklemez. Bu, "azalıp artma çok kötü/titrek" sorununu giderir.
- **Algısal eğri:** Kaydırıcı doğrusal değil, göze doğrusal görünen bir eğriyle çevrilir (DDC: `değer = max · s^1.6`; yazılım: `0.08 + 0.92 · s^1.25`, ekran hiçbir zaman tamamen kararmaz).

### Monitör durumları kalıcıdır

Diğer uygulamalardaki "uykudan dönünce kapattığım monitör yeniden açılıyor" sorununu çözmek için her monitörün **istenen durumu** (açık/kapalı + parlaklık) kararlı kimliğiyle (vendor + model + seri; aynı model iki monitörde port/DCP çıkışı ayırıcı olarak eklenir) kaydedilir ve şu olaylardan sonra **1, 3 ve 6 saniye** gecikmeyle yeniden uygulanır:

- sistem uyanması (`didWake`), ekran uyanması (`screensDidWake`)
- her ekran yeniden yapılandırması (`CGDisplayRegisterReconfigurationCallback`: takma/çıkarma, macOS'un monitörü kendiliğinden açması)
- uygulama açılışı ve her mod geçişi

Kurallar:
- **Masaüstü:** her monitör kendi istenen durumuna döner — kapattığınız monitör kapalı kalır, yalnızca "açık" olanlar açılır; parlaklık geri yüklenir.
- **Remote / Uyku:** istenen durum değişmeden, tüm fiziksel monitörler geçici olarak kapatılır. Masaüstü'ne dönünce her monitör kendi durumuna döner.
- **Koruma:** Masaüstü'nde son açık ekran kapatılamaz (Mac ekransız kalmasın); Remote'da sanal ekran etkin değilse fiziksel monitörler kapatılmaz. Uyku'da hepsi kapanabilir.
- macOS ekranları sürekli değiştirirse (60 sn'de 8+ düzeltme) döngüye girmemek için düzeltme geçici olarak durur ve günlüğe yazılır.

## Uyandır ve bağlan (Wake-on-LAN) — 1.7.0

MacBook'ta tek komut: Mac mini uyuyorsa **Wake-on-LAN** sihirli paketi gönderilir, SSH erişilebilir olana kadar beklenir, Mac mini istemcinin ekran boyutunda **Remote**'a alınır ve **Ekran Paylaşımı** (`vnc://`) açılır.

```bash
# MacBook'ta bir kez (Mac mini uyanıkken): MAC / yayın adresini uzak Mac'ten alıp kaydeder
workstation-connect --setup studio
# Sonra her seferinde:
workstation-connect            # uyandır → bekle → remote WxH → Ekran Paylaşımı
workstation-connect --no-wake  # uyandırmadan
workstation-connect --wake-only
```

- Yapılandırma: `~/.config/workstation/config` → `HOST`, `MAC`, `BROADCAST`, `VNC_HOST`, `WAKE_TIMEOUT` (varsayılan 90 sn). Dosya kaynak olarak çalıştırılmaz; yalnızca bu anahtarlar okunur.
- Sihirli paket sırasıyla `python3` (yalnızca Command Line Tools kuruluysa), `perl` (macOS ile gelir), son çare `nc` ile UDP 9/7 portlarına yayınlanır; 15 sn içinde uyanmazsa bir kez daha gönderilir.
- Mac mini tarafında `workstation netinfo` MAC (öncelik Ethernet), IP, yayın adresi ve `.local` adını yazdırır. Panelde **Remote** sekmesindeki "Uyandır ve bağlan" kartı aynı bilgiyi ve kopyalanabilir komutu gösterir.
- Remote modu artık `pmset womp 1` de uygular (Uyku modu zaten uyguluyordu).
- **Not:** Wake-on-LAN kablolu Ethernet'te güvenilirdir; Wi-Fi'de Mac mini derin uykudaysa paket ulaşmayabilir. Paket yerel ağ içindir; ağ dışından (internet) uyandırma için VPN/Tailscale gibi bir yol ve aynı ağda bir aracı gerekir.

## Otomatik mod geçişi — 1.7.0

**Ayarlar › Otomasyon › Otomatik mod geçişi** (varsayılan **kapalı**):

- Gelen bir **Ekran Paylaşımı** oturumu (isteğe bağlı **SSH** oturumu da) algılanınca Mac mini **Remote**'a geçer. Geri sayım HUD'u gösterilir; kimse iptal etmezse devam eder.
- Oturum bittikten sonra ayarlanan süre (varsayılan **15 dk**) boyunca yeni oturum gelmezse ve mod hâlâ Remote ise: **Uyku**, **Masaüstü** ya da **Hiçbir şey**.
- Oturum sürerken modu elle değiştirirseniz zorlanmaz (geçiş yalnızca oturumun *başladığı* anda tetiklenir).
- Algılama: süreç listesi uygulama içinden taranır (`screensharingd`, `sshd`/`sshd-session`; komut çalıştırılmaz). macOS bunun için bir olay yayınlamadığından tarama **yalnızca ayar açıkken** 10 sn'de bir yapılır (≈1 ms); kapalıyken hiçbir zamanlayıcı yoktur.

## Zamanlanmış modlar — 1.7.0

**Ayarlar › Otomasyon › Zamanlanmış modlar**: saat + haftanın günleri + mod (Masaüstü / Uyku / Remote) kuralları. Ör. *Hafta içi 23:30 → Uyku*, *Pzt–Cum 08:00 → Masaüstü*.

- Tek bir zamanlayıcı **bir sonraki** tetiklenme anına kurulur (yoklama yok); kural değişince, uyanınca ve saat/saat dilimi değişince yeniden kurulur.
- Mac uykudayken kaçırılan kurallar çalıştırılmaz; yalnızca uyanmadan önceki son 2 dk içindekiler çalışır (planlı uyanma ile birlikte kullanım için).
- Geçişler geri sayım HUD'u ile yapılır (İptal ile vazgeçilebilir). Mod zaten aynıysa atlanır.
- **Planlı uyanma** (isteğe bağlı): ilk Masaüstü/Remote kuralından 2 dk önce `sudo pmset repeat wakeorpoweron <günler> <saat>` yazılır. `pmset` yalnızca **tek** tekrar eden uyanma tutar; bu ayar sizin önceden kurduğunuz `pmset repeat` planının yerine geçer. Ayarı kapatınca (yalnızca bizim kurduğumuz) plan `pmset repeat cancel` ile silinir. Kontrol: `pmset -g sched`.

## Çalışma alanı profilleri — 1.7.0

**Masaüstü** sekmesinin üstünde *Profiller* kartı: monitör başına **aç/kapa** + **parlaklık** + **fan modu** adlandırılmış profil olarak kaydedilir (ör. "Kod": iki monitör %70, fan Otomatik; "Film": yalnızca büyük monitör %40).

- Profil çipine tıklamak uygular; sağ tık → *Şu anki durumla güncelle* / *Sil*. Aynı adla kaydetmek üzerine yazar.
- Remote/Uyku modundayken uygulanan profil fiziksel monitörleri **açmaz**; durumlar kaydedilir ve Masaüstü'ne dönünce uygulanır.
- Pencere yerleşimi güvenlik/kararlılık için kaydedilmez.
- URL: `workstation://profile/Kod` · CLI: `workstation profile Kod` (ad büyük/küçük harf, aksan ve boşluktan bağımsız eşleşir).

## Ses — 1.7.0

**Ayarlar › Ses › Remote modunda Mac mini sesini kapat** (varsayılan kapalı): Remote'a geçerken varsayılan çıkış cihazı CoreAudio ile sessize alınır; **Masaüstü**'ne dönünce geri açılır. Yalnızca uygulamanın kapattığı durum geri yüklenir (zaten sessizse dokunulmaz). Cihaz "mute" desteklemiyorsa (bazı HDMI/DP çıkışları) ses seviyesi 0 yapılır ve önceki seviye geri yüklenir.

> Not: Ekran Paylaşımı'nın "Yüksek Performans" modu sesi istemciye aktarabilir; bu ayar Mac mini'nin çıkış cihazını sessize aldığından aktarılan ses de kesilebilir. Uzaktan ses istiyorsanız kapalı bırakın.

## Tools → Sistem ve Uyanık tut — 1.7.0

- **Sistem kartı:** CPU %, RAM (kullanılan / toplam + bellek baskısı: Normal/Uyarı/Kritik), disk boş alanı (%10'un altında kırmızı), ağ ↓/↑ hızı. Değerler süreç içinden (mach `host_statistics`, `getifaddrs`, `sysctl`) okunur ve **yalnızca panel açık ve Tools sekmesi görünürken** fan okumasıyla aynı 1,5 sn'lik zamanlayıcıda yenilenir.
- **Uyanık tut:** `IOPMAssertion` (PreventUserIdleSystemSleep) ile Mac boşta uyumaz; süre **1 sa / 3 sa / Kapatana dek**. Süre dolunca tek atımlık zamanlayıcı onayı bırakır. Uygulama kapanınca macOS onayı otomatik kaldırır. Kontrol: `pmset -g assertions`.
- URL: `workstation://keepawake/on`, `workstation://keepawake/off`, `workstation://keepawake/on?hours=2` · CLI: `workstation keepawake on|off|1h|90m`.

## Bildirimler — 1.7.0

**Ayarlar › Bildirimler** (yerel macOS bildirimleri; ilk bildirimde izin istenir):

- **Aşırı ısınma (> 95 °C):** sıcaklık okunduğunda (Tools sekmesi açıkken veya Yarım modundaki bekçi tarafından) tetiklenir; 30 dk'da en fazla bir kez. Boşta ayrıca sıcaklık yoklanmaz.
- **Disk < %10 boş:** açılışta, uyanınca ve Tools sekmesi açıkken kontrol edilir; 12 saatte en fazla bir kez.
- **Beklenmedik kapanma:** her açılışta "temiz çıkış" bayrağı kontrol edilir; önceki oturum çökme/zorla kapatma/elektrik kesintisiyle bittiyse bildirilir. Uygulama artık `SIGTERM` (`kill`, `pkill`) aldığında da temiz kapanır (fanlar otomatiğe döner).
- Telefona anlık bildirim (push) bu sürümün kapsamında değil; ileride Pushover/ntfy gibi bir köprüyle eklenebilir.

## Tools → Fan kontrolü (1.6.0)

Panelde **Masaüstü / Uyku / Remote**'un sağında **Tools** sekmesi var. İlk araç, Macs Fan Control benzeri fan denetimi:

| Mod | Davranış |
|---|---|
| **Otomatik** | Fanlar tamamen macOS'ta (varsayılan). |
| **Yarım** | Hedef = min + %50 × (max − min). CPU/GPU 95 °C'yi geçerse otomatik **Full Blast**'a çıkar. |
| **Full Blast** | Hedef = fanın azami devri (Mx). |

- Dönen fan ikonu gerçek RPM'e göre hızlanır/yavaşlar (Core Animation; CPU harcamaz). Her fan için RPM çubuğu, min–max aralığı ve CPU/GPU ortalama sıcaklığı gösterilir.
- Fansız Mac'lerde (ör. MacBook Air) **"Bu Mac'te fan yok"** yazar, ayar yapılmaz.
- Seçilen mod saklanır; uyanmadan sonra ve Uyku modundan çıkınca yeniden uygulanır.

**Nasıl çalışır:** Okuma (RPM, sıcaklık) uygulama içinden AppleSMC ile yapılır (root gerekmez) ve **yalnızca panel açıkken ve Tools sekmesi görünürken** 1,5 sn'de bir yenilenir; panel kapalıyken hiçbir okuma yapılmaz. Yazma için küçük bir root yardımcısı kullanılır:

```bash
/usr/local/libexec/wm-fanhelper status                       # JSON durum
/usr/local/libexec/wm-fanhelper set <0-7|all> auto|half|max  # (sudo ile)
/usr/local/libexec/wm-fanhelper reset                        # hepsi otomatik, Ftst=0
```

Yardımcı yalnızca Swift + IOKit'tir, `root:wheel 755` olarak kurulur ve sudoers'ta yalnızca bu tam yol parolasız izinlidir (`/etc/sudoers.d/workstation_toggle`, visudo ile doğrulanır). Başka argüman kabul etmez, yalnızca fan mod/hedef anahtarlarına ve `Ftst`'ye yazar; hedef her zaman fanın `Mn..Mx` aralığına sıkıştırılır.

### Güvenlik notları

- Fanlar şu durumlarda **otomatiğe döndürülür**: uygulamadan çıkış, sistem uykuya geçerken, Uyku moduna geçişte, yardımcı hata verdiğinde ve (uygulama çökmüş/zorla kapatılmışsa) bir sonraki açılışta.
- Yarım modunda 15 sn'de bir sıcaklık bekçisi çalışır (uygulamada boşta çalışan tek zamanlayıcı; Otomatik ve Full Blast'ta yoktur).
- Fanı **minimumun altına** indiren bir mod yoktur. En kötü durumda fan gereğinden hızlı döner; soğutma hiçbir zaman azaltılmaz.
- M1/M2'de manuel moda geçmek için SMC "Ftst" (force test) bayrağı kısa süreliğine 1 yapılır; otomatiğe dönüşte 0'a çekilir. Bu, açık kaynak araçların (macos-smc-fan, Stats) kullandığı yöntemdir; Apple tarafından belgelenmemiştir.
- Sıcaklık anahtarları modele (hw.model) göre seçilir ve 5–125 °C aralığında okunanlar kullanılır. Yeni/bilinmeyen modellerde CPU/GPU değeri "—" görünebilir; fan kontrolü yine çalışır, ancak bu durumda Yarım modundaki bekçi sıcaklığı göremez.
- Elle sıfırlama: `sudo /usr/local/libexec/wm-fanhelper reset` ya da Mac'i yeniden başlatmak (SMC her açılışta otomatiğe döner).

## Dosyalar

```
WorkstationMode/
├── Sources/
│   ├── main.swift                 # Giriş noktası, CLI argümanları (--mode, --res, --preset), tek örnek yönlendirme
│   ├── AppDelegate.swift          # Menü çubuğu, popover yaşam döngüsü, URL scheme, uyanma/yeniden yapılandırma olayları
│   ├── ModeController.swift       # Mod uygulama kuyruğu, BetterDisplay otomatik kurulumu, parlaklık birleştirici
│   ├── PanelView.swift            # SwiftUI koyu panel: sekmeler, Başlat düğmeleri, monitör kartları, Ayarlar
│   ├── Countdown.swift            # Uyku/Remote öncesi geri sayım HUD'u (halka + tek sayı, İptal/Esc)
│   ├── LogWindow.swift            # Günlük penceresi (filtre, kopyala, temizle, otomatik kaydırma)
│   ├── IconRenderer.swift         # Mor/gümüş Mac Studio uygulama + menü çubuğu simgesi
│   ├── DisplayManager.swift       # Mod dizileri; BetterDisplay CLI ile sanal ekran (oluştur/bağla/çözünürlük/en-boy)
│   ├── BetterDisplayInstaller.swift # brew cask veya GitHub DMG ile BetterDisplay kurulumu (ilerleme bildirimli)
│   ├── PhysicalDisplayController.swift # Fiziksel ekranları CGSConfigureDisplayEnabled ile kes/aç
│   ├── Monitors.swift             # Monitör keşfi, port, DDC (doğrulamalı)/yazılım parlaklık, istenen durum uzlaştırma
│   ├── BrightnessCoalescer.swift  # Kaydırıcı yazımlarını seri kuyrukta birleştirme/hız sınırlama
│   ├── Models.swift               # WorkMode, monitör modeli/kalıcı durum, DDC paketleri, parlaklık eğrisi, Remote ön ayarları
│   ├── PowerManager.swift         # sudo -n pmset profilleri, displaysleepnow
│   └── Shell.swift                # Process çalıştırma (zaman aşımı) + döndürmeli günlük
├── Tools/MakeIcon/main.swift      # Kurulumda AppIcon.iconset PNG'lerini üretir
├── Info.plist                     # LSUIElement, com.tolgahanayaz.workstationmode, workstation:// scheme, AppIcon
├── setup_env.sh                   # Homebrew + BetterDisplay + CLI doğrulaması
├── install.sh                     # Tek adımlık kurulum (herhangi bir kullanıcı/Mac için)
├── workstation                    # Sunucu tarafı yardımcı komut (/usr/local/bin/workstation)
├── workstation-connect            # Bağlanan Mac'te: ekran boyutunu algıla → ssh ile Remote → Ekran Paylaşımı
└── README.md
```

## Kurulum

> Yalnızca **Command Line Tools** (Xcode olmadan) yeterlidir. Kod bilerek SwiftUI makrolarını (`@State`, `@Observable`, `#Preview` …) kullanmaz; CLT'deki `swiftc` SwiftUIMacros eklentisini içermediği için bunlar derlenmez.

Mac mini'de (veya bir arkadaşın Mac'inde), GUI oturumu açık kullanıcıyla (sudo **olmadan**):

```bash
cd WorkstationMode
chmod +x install.sh setup_env.sh workstation workstation-connect
./install.sh
```

Betikte kullanıcı adı / ev dizini sabit kodlanmamıştır (`id -un`, `$HOME`); Apple Silicon ve Intel (`uname -m`) için derler. `install.sh` sırasıyla:

1. `setup_env.sh` → Homebrew yoksa kurar; BetterDisplay yoksa `brew install --cask betterdisplay`; CLI'ı doğrular. Bu adım başarısız olsa bile kurulum devam eder (uygulama BetterDisplay'i gerektiğinde kendisi kurar).
2. Xcode Command Line Tools kontrolü (yoksa kurulum penceresini açar; bitince betiği tekrar çalıştırın).
3. `swiftc -O` ile derler, `Tools/MakeIcon` + `iconutil` ile `AppIcon.icns` üretir, `/Applications/WorkstationMode.app` paketini oluşturur ve ad-hoc imzalar.
4. `/etc/sudoers.d/workstation_toggle` → `<kullanıcı> ALL=(root) NOPASSWD: /usr/bin/pmset` (`visudo -cf` ile doğrulanır, izin `440`).
5. `workstation://` URL scheme'ini `lsregister` ile kaydeder.
6. `/usr/local/bin/workstation` ve `/usr/local/bin/workstation-connect` komutlarını kurar, `~/.zshenv`'e `/usr/local/bin` PATH satırını ekler.
7. Uygulamayı Login Items'a ekler ve başlatır.

Betik tekrar çalıştırılabilir (idempotent); güncelleme için de aynı komutu kullanın.

## BetterDisplay otomatik kurulumu

Remote ilk kez başlatıldığında BetterDisplay yoksa uygulama **kendisi kurar** (panelde ilerleme görünür; Ayarlar'da veya Remote sekmesinde "Şimdi kur" ile önceden de kurulabilir):

1. Homebrew varsa: `brew install --cask betterdisplay`
2. Yoksa: GitHub `waydabber/BetterDisplay` son sürümünün `.dmg` dosyası indirilir → `hdiutil attach` → `/Applications`'a kopyalanır → karantina özniteliği kaldırılır → arka planda başlatılır.

Kurulumdan sonra **BetterDisplay > Settings > Application (Integration) > CLI / URL scheme erişimini bir kez açın**; açık değilse Remote, nedenini anlatan bir hata ile durur (fiziksel monitörler kapatılmaz).

## Remote sanal ekranı: ön ayarlar ve "Otomatik"

Remote sekmesinden sanal ekran boyutu seçilir. En-boy oranı seçilen ön ayardan hesaplanır (ör. 1512x982 → 20:13) ve sanal ekran tanımı buna göre güncellenir.

| Ön ayar | Varsayılan görünüm (nokta) |
|---|---|
| MacBook Air 13" | 1470x956 |
| MacBook Air 15" | 1710x1107 |
| MacBook Pro 14" | 1512x982 |
| MacBook Pro 16" | 1728x1117 |
| iMac 24" | 2240x1260 |
| **Otomatik** (varsayılan) | Bağlanan Mac'in bildirdiği boyut → yoksa son hatırlanan → yoksa 14" (1512x982) |

Ekran Paylaşımı oturumundan istemcinin ekran boyutu güvenilir şekilde okunamadığı için "Otomatik", **bağlanan Mac'te** çalışan `workstation-connect` ile beslenir:

```bash
# MacBook'ta (bir kez: /usr/local/bin'e kopyalayın ya da depo klasöründen çalıştırın)
workstation-connect studio            # ekran boyutunu algılar → ssh studio workstation remote 1512x982 → vnc://studio açar
workstation-connect studio --no-vnc   # yalnızca Remote'u aç
workstation-connect studio --res 1728x1117
```

Algılama: ana ekranın nokta boyutu (`NSScreen`, JXA ile), olmazsa `system_profiler SPDisplaysDataType` → "UI Looks like". Gelen değer hatırlanır; bir sonraki Otomatik Remote'ta da kullanılır.

## İlk çalıştırmada dikkat

- **BetterDisplay CLI erişimi** açık olmalı (yukarıya bakın). BetterDisplay kurulu ama CLI kapalıysa uygulama açılışta bir kez uyarır.
- **BetterDisplay Pro:** Fiziksel monitörleri kesmek için Pro **gerekmez** (uygulama kendi kodu ile yapar). **Sanal ekran** özelliği BetterDisplay'in ücretsiz sürümünde sınırlı olabilir; Remote çalışmazsa günlükte "sanal ekran açılamadı" görürsünüz ve güvenlik için fiziksel monitörler **kapatılmaz**.
- **İzin pencereleri:** Login Items eklenirken Terminal için *System Events'i denetleme* izni istenebilir. Ad-hoc imzalı uygulama ilk açılışta Gatekeeper uyarısı verirse System Settings > Privacy & Security > "Open Anyway".
- **Parola:** Kurulum sırasında sudo parolası **bir kez** istenir; sonrasında mod geçişlerinde sorulmaz.

## Davranış kuralları

- **Dinamik algılama:** İsim sabit kodlanmamıştır. Fiziksel monitörler her geçişte CoreGraphics ile bulunur; BetterDisplay çıktısı yalnızca sanal/dummy ekranları dışarıda bırakmak için kullanılır.
- **Sanal ekran yalnızca Remote'da oluşturulur/bağlanır**; yoksa otomatik oluşturulur (elle "oluştur" demeniz gerekmez; Ayarlar'daki seçenek yalnızca onarım içindir).
- **Uyku modu:** sanal ekran **hiçbir zaman açılmaz veya oluşturulmaz**; fiziksel monitörler kesilir, `displaysleepnow`, minimum güç profili.
- **Uyku → uyanma:** sistem/ekran uyanması veya fare/klavye girdisinde (girişten ≥5 sn sonra) otomatik **Masaüstü**'ne dönülür. Klavye girdisi için *Erişilebilirlik* izni gerekir; fare hareketi izinsiz çalışır.
- **Remote – kritik kural:** Remote'dayken uyanma, SSH, Ekran Paylaşımı ya da uzaktan girdi **fiziksel monitörleri asla açmaz**; yeniden belirirlerse tekrar kesilir. Fiziksel monitörleri yalnızca **Masaüstü Modu** açar.
- Remote'da `pmset`'e ek olarak sistem uykusunu engelleyen bir etkinlik (`ProcessInfo.beginActivity`) tutulur.
- Uygulama yeniden başlarsa kayıtlı mod *Remote* ise Remote yeniden uygulanır; *Uyku* ise Masaüstü'ne dönülür.

## Günlük

Günlük yalnızca **Ayarlar > Günlük** içindedir (menüde ayrıca yoktur). Pencere: kaydırılabilir, eş aralıklı yazı, renk kodlu satırlar (bilgi / **UYARI** sarı / **HATA** kırmızı), `Tümü / Bilgi / Uyarı / Hata` filtresi, **Kopyala**, **Temizle**, **Otomatik kaydır**, "Finder'da Göster". Pencere kapanınca içeriği bellekten atılır.

Dosya: `~/Library/Logs/WorkstationMode.log` — **1 MB**'ı geçince `WorkstationMode.log.1` olarak döndürülür; pencere en fazla son **500** satırı tutar.

## Performans

- Boşta **zamanlayıcı/yoklama yoktur**: her şey olay güdümlüdür (uyanma, ekran yapılandırma geri çağrısı, URL). Uyanma/yeniden yapılandırma sonrası yalnızca 1-3-6 sn'lik üç tek seferlik kontrol çalışır. Tek istisna: fan **Yarım** modundayken 15 sn'lik sıcaklık bekçisi. Tools sekmesindeki fan okuması yalnızca panel açık ve sekme görünürken çalışır.
- Panel ve günlük penceresi **tembel** oluşturulur, kapanınca SwiftUI hiyerarşisi serbest bırakılır; menü çubuğu simgeleri önbelleklenir.
- Tüm kabuk/DDC işleri arka plan kuyruklarında; ana iş parçacığı bloklanmaz. `Process` boruları her çağrıdan sonra kapatılır.
- Beklenen ayak izi (Apple Silicon): **boşta ~20–35 MB RAM, %0 CPU, GPU kullanımı yok**; panel açıkken geçici olarak +10–20 MB, kaydırıcı sürüklenirken kısa CPU artışları. (Etkinlik Monitörü'nde "Bellek" sütunundan doğrulayın; değerler macOS sürümüne göre değişir.)

## Uzaktan (SSH) kullanım

Bağlanan Mac'te `~/.ssh/config` içinde `studio` takma adı tanımlı olduğunu varsayar (Mac mini'de System Settings > General > Sharing > **Remote Login** açık olmalı):

```bash
workstation-connect studio                  # önerilen: boyutu algıla + Remote + Ekran Paylaşımı
ssh studio workstation remote               # uygulamadaki ön ayar / Otomatik
ssh studio workstation remote 1728x1117     # belirli çözünürlük
ssh studio workstation remote mbp16         # ön ayar adı (mba13 mba15 mbp14 mbp16 imac24)
ssh studio workstation desktop              # eve dönünce
ssh studio workstation sleep                # gece
ssh studio workstation status               # geçerli mod
ssh studio workstation log                  # son günlük satırları
```

Alternatifler:

```bash
ssh studio open -g 'workstation://remote?res=1512x982'
ssh studio /Applications/WorkstationMode.app/Contents/MacOS/WorkstationMode --mode remote --preset mbp14
```

Not: `open` SSH üzerinden, Mac mini'de **aynı kullanıcının GUI oturumu açıkken** çalışır.

## Ayarlar (isteğe bağlı, `defaults`)

```bash
# Geri sayım süresi (sn, 0 = kapalı, varsayılan 3; panelde Ayarlar > Geri sayım):
defaults write com.tolgahanayaz.workstationmode countdownSeconds -int 3

# Fiziksel kabul edilmemesi gereken ekranları hariç tut (isim parçası, büyük/küçük harf duyarsız):
defaults write com.tolgahanayaz.workstationmode excludedDisplays -array "Sidecar" "AirPlay"

# Monitör kapatma yöntemi (panelden de seçilir): auto (BetterDisplay varsa o) | betterdisplay | system
defaults write com.tolgahanayaz.workstationmode physicalDisplayMethod auto

# Kesme kapsamı: session (varsayılan, yeniden başlatınca geri gelir) | permanent (önerilmez)
defaults write com.tolgahanayaz.workstationmode physicalDisableScope session
```

Remote çözünürlüğü artık panelden seçilir (`remotePreset`, `lastClientResolution` anahtarlarında saklanır). Değişiklikten sonra uygulamayı yeniden başlatın.

## Monitör ayrıntıları ve sınırlamalar

- **Port adı en iyi tahmindir:** Apple Silicon'da IORegistry'deki `AppleCLCD2` (DCP çıkışı) düğümünün `Transport` (Upstream/Downstream) bilgisi ve üst düğüm adları (`atcN` = USB-C portu) kullanılır. Mac mini'nin HDMI portu genellikle `Downstream = HDMI` olarak görünür. USB-C port numarası her zaman çıkarılamayabilir; bu durumda `USB-C / Thunderbolt (DP)` ve DCP çıkış adı (`dispext0`…) gösterilir.
- **DDC/CI:** Monitörün OSD menüsünde DDC/CI açık olmalıdır. Bazı monitörler (ve çoğu USB-C dock/adaptör, Mac mini HDMI portu bazı modellerde) DDC'yi iletmez; uygulama bunu geri okuma ile algılayıp otomatik yazılım karartmaya geçer. Yazılım karartma gerçek arka ışığı kısmaz, görüntüyü koyulaştırır ve uygulama kapanınca sıfırlanır.
- **Aynı model iki monitör:** seri numarası EDID'de boşsa ayırt etme port/DCP çıkışına göre yapılır; kablolar yer değiştirirse ayarlar da yer değiştirir.
- **Parlaklık başlangıç değeri:** monitör ilk görüldüğünde DDC ile okunur; okunamazsa %100 varsayılır.

## Ekranlar geri gelmezse (kurtarma)

1. Uzaktan: `ssh studio workstation desktop`
2. Menü çubuğu erişilemiyorsa: `ssh studio 'open -g workstation://desktop'`
3. Son çare: Mac mini'yi yeniden başlatın (`ssh studio sudo shutdown -r now`). Kesme işlemi `.forSession` olduğu için yeniden başlatma sonrası monitörler açık gelir.
4. Ayrıntı: `ssh studio workstation log`

## Notlar ve sınırlamalar

- **En-boy oranı:** Sanal ekran seçilen ön ayarın oranıyla tanımlanır (oran 32'den büyük sayılar içeriyorsa en yakın küçük orana yaklaştırılır, ör. 1512x982 → 20:13); BetterDisplay bunu reddederse 16:10'a düşülür. Tüm ön ayar çözünürlükleri listeye eklenir.
- **Özel API:** `CGSConfigureDisplayEnabled` Apple'ın belgelenmemiş bir API'sidir; macOS güncellemelerinde davranışı değişebilir veya kaldırılabilir (o durumda BetterDisplay yedek yoluna düşülür). Uygulama App Store dışı, ad-hoc imzalı olduğu için kullanımında engel yoktur.
- **Hiç ekran kalmaması:** Uyku modunda fiziksel monitörler kesilir ve sanal ekran kapalıdır. macOS son ekranın devre dışı bırakılmasını reddederse `pmset displaysleepnow` ekranları yine karartır.
- **Remote koruması:** Remote modunda monitör kablo/uyanma nedeniyle yeniden belirirse uygulama onu tekrar keser; fiziksel monitörleri yalnızca Masaüstü Modu açar.
- **Uyku modunda uzaktan uyandırma:** `womp 1` açıktır; ağ üzerinden uyandırma da bir uyanma olayı olduğu için Masaüstü'ne dönüş tetiklenir. Uzaktan erişim için önce `workstation remote` kullanın.
- **Düşük Güç Modu:** `lowpowermode` masaüstü Apple Silicon Mac'lerde macOS 13+ ile desteklenir; desteklenmeyen sistemde pmset hatası günlüğe yazılır.
- **Uygulamadan çıkış** ekran/güç durumunu değiştirmez; geri dönmek için önce Masaüstü Modu'nu seçin.
- **Kaldırma:**
  ```bash
  osascript -e 'tell application "System Events" to delete login item "WorkstationMode"'
  sudo /usr/local/libexec/wm-fanhelper reset   # fanları sisteme bırak
  pkill -x WorkstationMode; rm -rf /Applications/WorkstationMode.app
  sudo rm -f /etc/sudoers.d/workstation_toggle /usr/local/bin/workstation /usr/local/bin/workstation-connect /usr/local/libexec/wm-fanhelper
  defaults delete com.tolgahanayaz.workstationmode
  ```
