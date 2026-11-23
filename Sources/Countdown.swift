import Cocoa
import QuartzCore

/// Esc tuşunu yakalayabilen, kenarlıksız geri sayım paneli.
final class CountdownPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }   // Esc
}

/// Uyku / Remote başlamadan önce her ekranın ortasında büyük tek bir sayı (3 → 2 → 1) ve
/// azalan bir ilerleme halkası gösterir. İptal düğmesi veya Esc ile vazgeçilebilir.
/// Etkileşimsiz (URL/SSH) tetiklemede de gösterilir; kimse dokunmazsa süre dolunca devam eder.
/// Zamanlayıcı yalnızca geri sayım sürerken vardır; panel kapanınca her şey serbest bırakılır.
final class Countdown: NSObject {
    private var panels: [CountdownPanel] = []
    private var numberLabels: [NSTextField] = []
    private var timer: Timer?
    private var remaining = 0
    private var completion: ((Bool) -> Void)?

    private(set) var mode: WorkMode?
    var isRunning: Bool { completion != nil }

    /// - Parameters:
    ///   - interactive: true ise (panelden Başlat) panel klavye odağı alır (Esc çalışır).
    ///   - completion: true = süre doldu, devam et; false = iptal edildi.
    func start(mode: WorkMode, seconds: Int, interactive: Bool, completion: @escaping (Bool) -> Void) {
        cancel()
        guard seconds > 0 else { completion(true); return }
        self.mode = mode
        self.completion = completion
        remaining = seconds

        let keyScreen: NSScreen? = NSScreen.main ?? NSScreen.screens.first
        for screen in NSScreen.screens {
            let built = makePanel(on: screen, mode: mode, total: seconds)
            panels.append(built.panel)
            numberLabels.append(built.label)
            built.panel.orderFrontRegardless()
            if interactive && screen == keyScreen {
                NSApp.activate(ignoringOtherApps: true)
                built.panel.makeKeyAndOrderFront(nil)
            }
        }
        render()

        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Geri sayımı iptal eder (completion(false) çağrılır).
    func cancel() {
        if isRunning { finish(proceed: false) }
    }

    @objc private func cancelPressed(_ sender: Any?) { cancel() }

    private func tick() {
        remaining -= 1
        if remaining <= 0 {
            finish(proceed: true)
        } else {
            render()
        }
    }

    private func render() {
        let text = String(remaining)
        for l in numberLabels { l.stringValue = text }
    }

    private func finish(proceed: Bool) {
        timer?.invalidate()
        timer = nil
        for p in panels {
            p.onCancel = nil
            p.orderOut(nil)
            p.contentView = nil
        }
        panels.removeAll()
        numberLabels.removeAll()
        let c = completion
        completion = nil
        mode = nil
        remaining = 0
        c?(proceed)
    }

    // MARK: Panel oluşturma

    private func makePanel(on screen: NSScreen, mode: WorkMode, total: Int) -> (panel: CountdownPanel, label: NSTextField) {
        let size = NSSize(width: 300, height: 330)
        let vf = screen.frame
        let origin = NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2)
        let panel = CountdownPanel(contentRect: NSRect(origin: origin, size: size),
                                   styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.onCancel = { [weak self] in self?.cancel() }

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.appearance = NSAppearance(named: .darkAqua)
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 28
        bg.layer?.masksToBounds = true
        bg.autoresizingMask = [.width, .height]
        panel.contentView = bg

        // Başlık: mod simgesi + adı
        let title = makeLabel(mode.title, font: .systemFont(ofSize: 18, weight: .semibold),
                              frame: NSRect(x: 16, y: size.height - 52, width: size.width - 32, height: 26))
        bg.addSubview(title)

        // İlerleme halkası
        let ringSize: CGFloat = 170
        let ringRect = NSRect(x: (size.width - ringSize) / 2, y: 78, width: ringSize, height: ringSize)
        let ringHost = NSView(frame: ringRect)
        ringHost.wantsLayer = true
        bg.addSubview(ringHost)
        addRing(to: ringHost, size: ringSize, seconds: total, tint: tint(for: mode))

        // Halkanın ortasında tek büyük sayı
        let number = makeLabel("", font: .monospacedDigitSystemFont(ofSize: 84, weight: .bold),
                               frame: NSRect(x: ringRect.minX, y: ringRect.midY - 52, width: ringSize, height: 100))
        bg.addSubview(number)

        let button = NSButton(title: "İptal (Esc)", target: self, action: #selector(cancelPressed(_:)))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\u{1b}"
        button.frame = NSRect(x: (size.width - 140) / 2, y: 22, width: 140, height: 32)
        bg.addSubview(button)

        return (panel, number)
    }

    private func tint(for mode: WorkMode) -> NSColor {
        switch mode {
        case .sleep: return NSColor(calibratedRed: 0.40, green: 0.52, blue: 1.0, alpha: 1)
        case .remote: return NSColor(calibratedRed: 0.66, green: 0.45, blue: 1.0, alpha: 1)
        case .desktop: return NSColor.systemGreen
        }
    }

    /// Arka iz + süre boyunca doğrusal olarak boşalan halka (Core Animation; CPU zamanlayıcısı gerekmez).
    private func addRing(to host: NSView, size: CGFloat, seconds: Int, tint: NSColor) {
        guard let layer = host.layer else { return }
        let lineWidth: CGFloat = 9
        // Saat 12'den başlayıp saat yönünde ilerleyen çember (katman y-yukarı koordinatlı).
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: size / 2, y: size / 2), radius: (size - lineWidth) / 2,
                    startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)

        let track = CAShapeLayer()
        track.path = path
        track.fillColor = NSColor.clear.cgColor
        track.strokeColor = NSColor.white.withAlphaComponent(0.12).cgColor
        track.lineWidth = lineWidth
        layer.addSublayer(track)

        let progress = CAShapeLayer()
        progress.path = path
        progress.fillColor = NSColor.clear.cgColor
        progress.strokeColor = tint.cgColor
        progress.lineWidth = lineWidth
        progress.lineCap = .round
        progress.strokeEnd = 0
        layer.addSublayer(progress)

        let anim = CABasicAnimation(keyPath: "strokeEnd")
        anim.fromValue = 1.0
        anim.toValue = 0.0
        anim.duration = CFTimeInterval(seconds)
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        progress.add(anim, forKey: "countdown")
    }

    private func makeLabel(_ text: String, font: NSFont, frame: NSRect) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = font
        l.alignment = .center
        l.textColor = .white
        l.frame = frame
        l.lineBreakMode = .byTruncatingTail
        return l
    }
}
