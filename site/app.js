/* Workstation — site script: language, reveal, sticky modes, popover demo, typing. No dependencies. */
(function () {
  "use strict";
  var I18N = {
    en: {
      "skip": "Skip to content",
      "nav.modes": "Modes", "nav.how": "How it works", "nav.tools": "Tools", "nav.download": "Download", "nav.get": "Download",
      "hero.eyebrow": "For Mac mini &amp; Mac Studio",
      "hero.title": "Your Mac Studio.<br><span class=\"grad\">No monitor required.</span>",
      "hero.lead": "Workstation turns the Mac under your desk into a headless workstation you drive from your MacBook. Monitors stay dark, the screen is sized to your laptop, and sleep sips power — one click, or one command.",
      "hero.cta": "Download for macOS", "hero.cta2": "See how it works",
      "hero.fine": "Free · Native Swift · macOS 13 or later",
      "mock.mode.remote": "Remote · virtual screen", "mock.desktop": "Desktop", "mock.sleep": "Sleep", "mock.remote": "Remote",
      "mock.c0.t": "Monitors", "mock.c1.t": "Sleep", "mock.c1.p": "Monitors off, low power mode, wakes back to Desktop.",
      "mock.c2.t": "Remote work", "mock.c2.p": "Monitors off · virtual screen 1512×982 HiDPI", "mock.c3.t": "Fans", "mock.start": "Start",
      "st.p1": "Other display tools assume there’s a monitor on your desk.",
      "st.p2": "Workstation assumes there isn’t.",
      "st.p3": "Keep the Mac Studio in another room, or on a shelf with the monitors dark. Connect from your MacBook over Screen Sharing or SSH and get a desktop that fits your laptop pixel for pixel — while the real monitors stay off and never wake up from remote input.",
      "modes.title": "Three modes. One click.", "stage.power": "Power",
      "m0.tag": "Desktop", "m0.h": "Sit down. Everything’s back.",
      "m0.p": "Physical monitors come on, each with its own brightness and on/off state remembered — even after sleep. Turn one monitor off and the others stay put.",
      "m1.tag": "Sleep", "m1.h": "Lights out. Minimum power.",
      "m1.p": "Monitors are cut, low-power mode kicks in and no virtual screen is ever opened. Wake it and you’re back on Desktop.",
      "m2.tag": "Remote", "m2.h": "A screen made for your MacBook.",
      "m2.p": "The physical monitors switch off and a HiDPI virtual screen appears, sized to the Mac that connects — 1512×982 for a 14″ MacBook Pro. The Mac never sleeps, and the monitors only come back when you choose Desktop.",
      "how.title": "From your laptop to your studio.", "how.sub": "Wake it, switch it, connect — from anywhere on your network.",
      "how.chip": "Screen Sharing · SSH · Wake-on-LAN",
      "how.out1": "✔ Virtual screen 1512×982 HiDPI · monitors off · never sleeps",
      "how.out2": "✔ Woke studio.local · Remote · opening Screen Sharing…",
      "how.s1": "Install Workstation on the Mac Studio or Mac mini.",
      "how.s2": "From the MacBook, run <code>workstation-connect</code> — or open <code>workstation://remote</code>.",
      "how.s3": "Work. When you’re back at the desk, pick Desktop.",
      "tools.title": "The quiet little extras.",
      "t1.h": "Fan control", "t1.p": "Auto, Half or Full Blast. Safe by design: back to automatic on sleep, quit or any error.",
      "t2.h": "Developer disk cleaner", "t2.p": "Old builds, caches and AI-agent leftovers. Never touches files in use or active projects — re-checked right before every delete, then sent to the Trash.",
      "t3.h": "Automation", "t3.p": "Switch to Remote when someone connects, schedule Sleep at night, profiles, keep-awake and Shortcuts through <code>workstation://</code> links.",
      "t4.h": "Light as air", "t4.p": "Native Swift and AppKit, no third-party libraries. Nothing spins while idle — and it updates itself from GitHub Releases.",
      "dl.title": "Put your studio to work.", "dl.sub": "Open the DMG, drag Workstation to Applications, done.",
      "dl.cta": "Download the latest release",
      "req.os.k": "macOS", "req.os.v": "13 Ventura or later",
      "req.mac.k": "Mac", "req.mac.v": "Apple Silicon Mac mini or Mac Studio (universal build)",
      "req.bd.k": "Remote", "req.bd.v": "BetterDisplay — installed automatically",
      "req.cl.k": "Client", "req.cl.v": "Any Mac with Screen Sharing",
      "foot.by": "Made by",
      "_title": "Workstation — Your Mac Studio, without a monitor"
    },
    tr: {
      "skip": "İçeriğe geç",
      "nav.modes": "Modlar", "nav.how": "Nasıl çalışır", "nav.tools": "Araçlar", "nav.download": "İndir", "nav.get": "İndir",
      "hero.eyebrow": "Mac mini ve Mac Studio için",
      "hero.title": "Mac Studio’n.<br><span class=\"grad\">Monitör gerekmez.</span>",
      "hero.lead": "Workstation, masanın altındaki Mac’i MacBook’undan yönettiğin ekransız bir iş istasyonuna çevirir. Monitörler kapalı kalır, ekran laptopunun boyutunda açılır, uyku neredeyse hiç enerji harcamaz — tek tıkla ya da tek komutla.",
      "hero.cta": "macOS için indir", "hero.cta2": "Nasıl çalıştığını gör",
      "hero.fine": "Ücretsiz · Yerel Swift · macOS 13 ve üstü",
      "mock.mode.remote": "Remote · sanal ekran", "mock.desktop": "Masaüstü", "mock.sleep": "Uyku", "mock.remote": "Remote",
      "mock.c0.t": "Monitörler", "mock.c1.t": "Uyku", "mock.c1.p": "Monitörler kapanır, düşük güç modu, uyanınca Masaüstü.",
      "mock.c2.t": "Uzaktan çalışma", "mock.c2.p": "Monitörler kapalı · sanal ekran 1512×982 HiDPI", "mock.c3.t": "Fanlar", "mock.start": "Başlat",
      "st.p1": "Diğer ekran araçları masanda bir monitör olduğunu varsayar.",
      "st.p2": "Workstation olmadığını varsayar.",
      "st.p3": "Mac Studio başka bir odada dursun ya da monitörleri kapalı bir rafta. MacBook’undan Ekran Paylaşımı veya SSH ile bağlan, laptopuna piksel piksel uyan bir masaüstü al — gerçek monitörler kapalı kalır ve uzaktan gelen girdiyle asla uyanmaz.",
      "modes.title": "Üç mod. Tek tık.", "stage.power": "Güç",
      "m0.tag": "Masaüstü", "m0.h": "Otur. Her şey yerinde.",
      "m0.p": "Fiziksel monitörler açılır; her birinin parlaklığı ve açık/kapalı durumu hatırlanır — uykudan sonra bile. Bir monitörü kapat, diğeri olduğu gibi kalır.",
      "m1.tag": "Uyku", "m1.h": "Işıklar sönsün. En az enerji.",
      "m1.p": "Monitörler kesilir, düşük güç modu devreye girer ve sanal ekran asla açılmaz. Uyandırınca Masaüstü’ne dönersin.",
      "m2.tag": "Remote", "m2.h": "MacBook’un için yapılmış bir ekran.",
      "m2.p": "Fiziksel monitörler kapanır, bağlanan Mac’in boyutunda HiDPI bir sanal ekran açılır — 14″ MacBook Pro için 1512×982. Mac hiç uyumaz; monitörler yalnızca sen Masaüstü’nü seçince geri gelir.",
      "how.title": "Laptopundan stüdyona.", "how.sub": "Uyandır, moda al, bağlan — ağın neresinde olursan ol.",
      "how.chip": "Ekran Paylaşımı · SSH · Wake-on-LAN",
      "how.out1": "✔ Sanal ekran 1512×982 HiDPI · monitörler kapalı · uyumaz",
      "how.out2": "✔ studio.local uyandı · Remote · Ekran Paylaşımı açılıyor…",
      "how.s1": "Workstation’ı Mac Studio’ya ya da Mac mini’ye kur.",
      "how.s2": "MacBook’ta <code>workstation-connect</code> çalıştır — ya da <code>workstation://remote</code> adresini aç.",
      "how.s3": "Çalış. Masaya dönünce Masaüstü’nü seç.",
      "tools.title": "Sessiz küçük ekstralar.",
      "t1.h": "Fan kontrolü", "t1.p": "Otomatik, Yarım ya da Full Blast. Güvenli tasarım: uykuda, çıkışta ya da bir hata olunca otomatiğe döner.",
      "t2.h": "Geliştirici disk temizleyici", "t2.p": "Eski derlemeler, önbellekler, yapay zekâ ajanlarının artıkları. Kullanılan dosyalara ve aktif projelere asla dokunmaz — her silmeden hemen önce yeniden kontrol eder, Çöp Sepeti’ne taşır.",
      "t3.h": "Otomasyon", "t3.p": "Biri bağlanınca Remote’a geç, gece Uyku’yu zamanla; profiller, uyanık tutma ve <code>workstation://</code> adresleriyle Kestirmeler.",
      "t4.h": "Tüy kadar hafif", "t4.p": "Yerel Swift ve AppKit, üçüncü parti kütüphane yok. Boştayken hiçbir şey dönmez — GitHub Releases’tan kendini günceller.",
      "dl.title": "Stüdyonu işe koş.", "dl.sub": "DMG’yi aç, Workstation’ı Applications’a sürükle, bitti.",
      "dl.cta": "Son sürümü indir",
      "req.os.k": "macOS", "req.os.v": "13 Ventura ve üstü",
      "req.mac.k": "Mac", "req.mac.v": "Apple Silicon Mac mini ya da Mac Studio (evrensel derleme)",
      "req.bd.k": "Remote", "req.bd.v": "BetterDisplay — otomatik kurulur",
      "req.cl.k": "İstemci", "req.cl.v": "Ekran Paylaşımı olan herhangi bir Mac",
      "foot.by": "Yapan:",
      "_title": "Workstation — Mac Studio’n, monitörsüz"
    }
  };

  var root = document.documentElement;
  var reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (reduce) root.classList.add("reduce");

  function pickLang() {
    var p = new URLSearchParams(location.search).get("lang");
    if (p && I18N[p]) return p;
    try { var s = localStorage.getItem("ws-lang"); if (s && I18N[s]) return s; } catch (e) {}
    var langs = navigator.languages && navigator.languages.length ? navigator.languages : [navigator.language || "en"];
    return String(langs[0] || "en").toLowerCase().indexOf("tr") === 0 ? "tr" : "en";
  }

  function setLang(lang, save) {
    var d = I18N[lang] || I18N.en;
    root.lang = lang;
    document.title = d._title;
    document.querySelectorAll("[data-i18n]").forEach(function (el) {
      var k = el.getAttribute("data-i18n");
      if (d[k] != null) el.innerHTML = d[k];
    });
    document.querySelectorAll(".lang button").forEach(function (b) {
      b.setAttribute("aria-pressed", String(b.getAttribute("data-lang") === lang));
    });
    if (save) { try { localStorage.setItem("ws-lang", lang); } catch (e) {} }
  }
  document.querySelectorAll(".lang button").forEach(function (b) {
    b.addEventListener("click", function () { setLang(b.getAttribute("data-lang"), true); });
  });
  setLang(pickLang(), false);

  // Sticky nav shadow
  var nav = document.getElementById("nav");
  var onScroll = function () { nav.classList.toggle("scrolled", window.scrollY > 8); };
  window.addEventListener("scroll", onScroll, { passive: true }); onScroll();

  // Scroll reveal
  var reveals = document.querySelectorAll(".reveal");
  if (reduce || !("IntersectionObserver" in window)) {
    reveals.forEach(function (el) { el.classList.add("in"); });
  } else {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
      });
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.12 });
    reveals.forEach(function (el, i) {
      if (el.closest(".hero")) {           // hero: reveal on load, staggered
        el.style.transitionDelay = i * 90 + "ms";
        requestAnimationFrame(function () { requestAnimationFrame(function () { el.classList.add("in"); }); });
      } else { el.style.transitionDelay = (i % 4) * 70 + "ms"; io.observe(el); }
    });
  }

  // Modes: the step in view drives the sticky stage
  var stage = document.querySelector(".stage");
  var steps = document.querySelectorAll(".step");
  function activate(i) {
    stage.setAttribute("data-mode", String(i));
    steps.forEach(function (s) { s.classList.toggle("active", s.getAttribute("data-step") === String(i)); });
  }
  activate(0);
  if ("IntersectionObserver" in window) {
    var so = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) { if (e.isIntersecting) activate(+e.target.getAttribute("data-step")); });
    }, { rootMargin: "-45% 0px -45% 0px" });
    steps.forEach(function (s) { so.observe(s); });
  }

  // Popover demo: cycle tabs
  var pop = document.querySelector(".popover");
  var tab = 2;
  function showTab(i) {
    pop.setAttribute("data-tab", String(i));
    var mb = document.querySelector(".mb-icon");
    mb.setAttribute("data-tab", String(i));
  }
  showTab(tab);
  if (!reduce) {
    var timer = setInterval(function () { tab = (tab + 1) % 4; showTab(tab); }, 2600);
    document.addEventListener("visibilitychange", function () {
      if (document.hidden) { clearInterval(timer); timer = null; }
      else if (!timer) timer = setInterval(function () { tab = (tab + 1) % 4; showTab(tab); }, 2600);
    });
  }

  // Terminal typing
  var typed = document.querySelector(".typed");
  var full = typed.getAttribute("data-text");
  var term = document.querySelector(".terminal");
  function type() {
    if (reduce) { typed.textContent = full; term.classList.add("done"); return; }
    var n = 0;
    (function tick() {
      typed.textContent = full.slice(0, n++);
      if (n <= full.length) setTimeout(tick, 45 + Math.random() * 40);
      else setTimeout(function () { term.classList.add("done"); }, 250);
    })();
  }
  if ("IntersectionObserver" in window && !reduce) {
    var to = new IntersectionObserver(function (e) {
      if (e[0].isIntersecting) { type(); to.disconnect(); }
    }, { threshold: 0.5 });
    to.observe(term);
  } else type();
})();
