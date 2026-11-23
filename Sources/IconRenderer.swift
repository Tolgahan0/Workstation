import AppKit

/// Uygulama simgesi (koyu grafit zemin üzerinde gümüş Mac Studio) ve menü çubuğu simgesi
/// (tek renk, şablon Mac mini — menü çubuğunun rengine otomatik uyar).
/// Tümü vektörel çizim (NSImage drawingHandler) → her ölçekte keskin.
enum IconRenderer {
    static let graphiteTop = NSColor(srgbRed: 0.27, green: 0.28, blue: 0.31, alpha: 1)
    static let graphiteBottom = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1)
    static let silverLight = NSColor(srgbRed: 0.97, green: 0.97, blue: 0.99, alpha: 1)
    static let silverMid = NSColor(srgbRed: 0.84, green: 0.85, blue: 0.88, alpha: 1)
    static let silverDark = NSColor(srgbRed: 0.66, green: 0.68, blue: 0.73, alpha: 1)

    static var silverGradient: NSGradient {
        NSGradient(colors: [silverLight, silverMid, silverDark], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    }

    static var graphiteGradient: NSGradient {
        NSGradient(starting: graphiteTop, ending: graphiteBottom)!
    }

    /// SF Symbol "macstudio.fill" (macOS 13+); yoksa elle çizim.
    private static func macStudioSymbol(pointSize: CGFloat) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        for name in ["macstudio.fill", "macstudio"] {
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: "Mac Studio")?
                .withSymbolConfiguration(config) {
                return img
            }
        }
        return nil
    }

    /// `rect` içine (oranı koruyarak, ortalanmış) gümüş degrade Mac Studio çizer.
    static func drawMacStudio(in rect: NSRect, pointSize: CGFloat) {
        if let symbol = macStudioSymbol(pointSize: pointSize), symbol.size.width > 0, symbol.size.height > 0 {
            let scale = min(rect.width / symbol.size.width, rect.height / symbol.size.height)
            let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
            let target = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                width: size.width, height: size.height)
            // Sembolü maske olarak kullanıp üstüne gümüş degrade boya.
            let tinted = NSImage(size: size, flipped: false) { r in
                symbol.draw(in: r)
                NSGraphicsContext.current?.compositingOperation = .sourceAtop
                silverGradient.draw(in: r, angle: -90)
                return true
            }
            tinted.draw(in: target)
        } else {
            drawMacStudioFallback(in: rect)
        }
    }

    /// Elle çizilmiş Mac Studio: alçak, yuvarlatılmış kare gövde + ön yüzde portlar.
    private static func drawMacStudioFallback(in rect: NSRect) {
        let w = min(rect.width, rect.height * 1.6)
        let h = w * 0.42
        let body = NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
        let path = NSBezierPath(roundedRect: body, xRadius: h * 0.22, yRadius: h * 0.22)
        silverGradient.draw(in: path, angle: -90)
        // Üst kenar parlaması
        NSColor.white.withAlphaComponent(0.6).setStroke()
        let top = NSBezierPath()
        top.move(to: NSPoint(x: body.minX + h * 0.25, y: body.maxY - 0.75))
        top.line(to: NSPoint(x: body.maxX - h * 0.25, y: body.maxY - 0.75))
        top.lineWidth = max(0.5, h * 0.04)
        top.stroke()
        // Ön portlar (2 USB-C + SD yuvası)
        NSColor(white: 0.35, alpha: 0.85).setFill()
        let portH = h * 0.12
        let y = body.minY + h * 0.38
        for i in 0..<2 {
            let x = body.minX + w * 0.12 + CGFloat(i) * w * 0.07
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w * 0.04, height: portH),
                         xRadius: portH / 2, yRadius: portH / 2).fill()
        }
        NSBezierPath(roundedRect: NSRect(x: body.maxX - w * 0.28, y: y, width: w * 0.14, height: portH),
                     xRadius: portH / 3, yRadius: portH / 3).fill()
    }

    /// Uygulama simgesi (macOS simge ızgarası: kenarlarda %10 boşluk, sürekli köşe).
    static func appIcon(size: CGFloat = 1024) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let inset = size * 0.1
            let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
            let radius = tile.width * 0.225
            let path = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = size * 0.02
            shadow.shadowOffset = NSSize(width: 0, height: -size * 0.01)
            shadow.set()
            graphiteGradient.draw(in: path, angle: -90)
            NSGraphicsContext.restoreGraphicsState()

            // İnce kenar çizgisi (koyu zeminde simge sınırı belirgin olsun)
            NSColor.white.withAlphaComponent(0.10).setStroke()
            path.lineWidth = max(1, size * 0.004)
            path.stroke()

            // Hafif iç parlama
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            NSGradient(starting: NSColor.white.withAlphaComponent(0.18), ending: .clear)?
                .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
            NSGraphicsContext.restoreGraphicsState()

            let art = tile.insetBy(dx: tile.width * 0.16, dy: tile.height * 0.22)
            NSGraphicsContext.saveGraphicsState()
            let s2 = NSShadow()
            s2.shadowColor = NSColor.black.withAlphaComponent(0.3)
            s2.shadowBlurRadius = size * 0.015
            s2.shadowOffset = NSSize(width: 0, height: -size * 0.008)
            s2.set()
            drawMacStudio(in: art, pointSize: size * 0.5)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }

    // MARK: Menü çubuğu (şablon Mac mini)

    /// SF Symbol "macmini.fill" / "macmini" (macOS 12+); yoksa nil.
    private static func macMiniSymbol() -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 64, weight: .regular)
        for name in ["macmini.fill", "macmini"] {
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: "Mac mini")?
                .withSymbolConfiguration(config) {
                return img
            }
        }
        return nil
    }

    /// Elle çizilmiş Mac mini (önden görünüm): alçak, yuvarlatılmış gövde + durum ışığı.
    private static func drawMacMiniFallback(in rect: NSRect) {
        let w = min(rect.width, rect.height / 0.42)
        let h = w * 0.42
        let body = NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
        let path = NSBezierPath(roundedRect: body, xRadius: h * 0.28, yRadius: h * 0.28)
        // Ön yüzdeki ışık ve yarık: gövdeden oyulur (even-odd) → şablon olarak keskin.
        let led = NSRect(x: body.maxX - w * 0.14, y: body.minY + h * 0.40, width: h * 0.16, height: h * 0.16)
        path.append(NSBezierPath(ovalIn: led))
        let slot = NSRect(x: body.minX + w * 0.12, y: body.minY + h * 0.43, width: w * 0.22, height: h * 0.10)
        path.append(NSBezierPath(roundedRect: slot, xRadius: h * 0.05, yRadius: h * 0.05))
        path.windingRule = .evenOdd
        NSColor.black.setFill()
        path.fill()
    }

    /// Menü çubuğu kalınlığını tam kullanan şablon Mac mini simgesi. Tek renk; macOS menü
    /// çubuğunun açık/koyu görünümüne göre otomatik renklendirir. Mod rozeti ayrı bir katmandır.
    static func menuBarImage(thickness: CGFloat) -> NSImage {
        let height = max(16, thickness - 2)          // ~20–22 pt: menü çubuğuna sığan en büyük boy
        let maxWidth = height * 1.75
        let symbol = macMiniSymbol()
        let aspect: CGFloat
        if let sym = symbol, sym.size.height > 0 {
            aspect = sym.size.width / sym.size.height
        } else {
            aspect = 1 / 0.42
        }
        // Simgenin kendi oranıyla, yükseklik ve genişlik sınırına sığdır.
        var drawH = height
        var drawW = drawH * aspect
        if drawW > maxWidth { drawW = maxWidth; drawH = drawW / aspect }
        let size = NSSize(width: ceil(drawW), height: height)
        let image = NSImage(size: size, flipped: false) { r in
            let target = NSRect(x: (r.width - drawW) / 2, y: (r.height - drawH) / 2, width: drawW, height: drawH)
            if let sym = symbol {
                sym.draw(in: target)
            } else {
                drawMacMiniFallback(in: target)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Workstation"
        return image
    }

    /// Mod rozeti rengi: Masaüstü yok · Uyku mavi · Remote yeşil · geçiş sarı.
    static func badgeColor(mode: WorkMode, busy: Bool) -> NSColor? {
        if busy { return NSColor.systemYellow }
        switch mode {
        case .desktop: return nil
        case .sleep: return NSColor(srgbRed: 0.45, green: 0.70, blue: 1.0, alpha: 1)
        case .remote: return NSColor(srgbRed: 0.20, green: 0.84, blue: 0.40, alpha: 1)
        }
    }
}

/// Şablon simgenin üstünde duran küçük renkli mod noktası (simgeyi tek renk bırakır).
final class StatusBadgeView: NSView {
    var color: NSColor? {
        didSet { isHidden = color == nil; needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = color else { return }
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        NSColor(white: 0.08, alpha: 0.85).setFill()
        NSBezierPath(ovalIn: r).fill()
        c.setFill()
        NSBezierPath(ovalIn: r.insetBy(dx: 1.3, dy: 1.3)).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // tıklamalar düğmeye gitsin
}
