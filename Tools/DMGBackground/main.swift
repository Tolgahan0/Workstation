import AppKit

// DMG penceresinin arka planı (Finder simge görünümü). Koordinatlar Finder ile aynı: sol üst köşe (0,0).
// Kullanım: DMGBackground <çıktı klasörü>  →  background.png (1x) + background@2x.png
// scripts/make-dmg.sh bu ikisini tiffutil ile tek bir HiDPI background.tiff yapar.
// Yerleşim make-dmg.sh ile eşleşmeli: pencere 660 × 440 (görünen alan), simgeler 128 pt,
//   Workstation.app (170, 220) · Applications (490, 220) · aşağıda (kaydırınca) Kurulum.command / BENİOKU.txt.

let W: CGFloat = 660
let VISIBLE: CGFloat = 440
let H: CGFloat = 720          // görünen alanın altında "isteğe bağlı kurulum" bölümü

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("Kullanım: DMGBackground <klasör>\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func drawText(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, centerX: CGFloat, top: CGFloat,
              kern: CGFloat = 0) {
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: para,
        .kern: kern,
    ]
    let str = NSAttributedString(string: s, attributes: attrs)
    let sz = str.size()
    str.draw(in: NSRect(x: centerX - 300, y: top, width: 600, height: sz.height + 2))
}

func render(scale: CGFloat) -> Data? {
    let pw = Int(W * scale), ph = Int(H * scale)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    // Sol üst köşe orijinli (Finder gibi) çizim
    ctx.cgContext.translateBy(x: 0, y: H)
    ctx.cgContext.scaleBy(x: 1, y: -1)
    let flippedCtx = NSGraphicsContext(cgContext: ctx.cgContext, flipped: true)
    NSGraphicsContext.current = flippedCtx

    // Zemin: sıcak açık degrade
    let full = NSRect(x: 0, y: 0, width: W, height: H)
    NSGradient(colors: [rgb(250, 249, 247), rgb(241, 239, 235)])!.draw(in: full, angle: 90)
    // Yumuşak ışık halkaları (simgelerin arkasında)
    for cx in [CGFloat(170), 490] {
        let glow = NSGradient(colors: [rgb(255, 255, 255, 0.95), rgb(255, 255, 255, 0)])!
        glow.draw(fromCenter: NSPoint(x: cx, y: 214), radius: 0, toCenter: NSPoint(x: cx, y: 214), radius: 120,
                  options: [])
    }

    // Başlık
    drawText("Workstation", size: 26, weight: .bold, color: rgb(28, 28, 30), centerX: W / 2, top: 34, kern: -0.3)
    drawText("Kurmak için Applications klasörüne sürükle", size: 13.5, weight: .medium,
             color: rgb(72, 72, 76), centerX: W / 2, top: 72)
    drawText("Drag to Applications to install", size: 11.5, weight: .regular,
             color: rgb(134, 134, 139), centerX: W / 2, top: 92)

    // Ok: iki simge arasında, kesikli gövde + dolu uç
    let y: CGFloat = 214
    let x0: CGFloat = 262, x1: CGFloat = 392
    let arrowColor = rgb(60, 60, 67, 0.55)
    arrowColor.setStroke()
    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: x0, y: y))
    shaft.line(to: NSPoint(x: x1 - 12, y: y))
    shaft.lineWidth = 3
    shaft.lineCapStyle = .round
    shaft.setLineDash([2, 8], count: 2, phase: 0)
    shaft.stroke()
    arrowColor.setFill()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: x1 + 4, y: y))
    head.line(to: NSPoint(x: x1 - 12, y: y - 9))
    head.line(to: NSPoint(x: x1 - 12, y: y + 9))
    head.close()
    head.fill()

    // Görünen alanın alt ipucu
    drawText("Sonra Applications'tan Workstation'ı aç  ·  Then open it from Applications", size: 11, weight: .regular,
             color: rgb(110, 110, 115), centerX: W / 2, top: 352)
    drawText("Fan kontrolü ve terminal komutu için aşağı kaydır  ↓", size: 10.5, weight: .medium,
             color: rgb(150, 150, 155), centerX: W / 2, top: 384)

    // Ayırıcı + isteğe bağlı bölüm (kaydırınca görünür)
    rgb(0, 0, 0, 0.08).setFill()
    NSRect(x: 40, y: VISIBLE + 20, width: W - 80, height: 1).fill()
    drawText("İsteğe bağlı kurulum  ·  Optional setup", size: 15, weight: .semibold, color: rgb(28, 28, 30),
             centerX: W / 2, top: VISIBLE + 44)
    drawText("Kurulum.command: fan kontrolü, parolasız mod geçişi, `workstation` komutu, açılışta başlatma.",
             size: 11, weight: .regular, color: rgb(90, 90, 95), centerX: W / 2, top: VISIBLE + 70)
    drawText("Sağ tık › Aç  ·  Right-click › Open", size: 11, weight: .regular, color: rgb(134, 134, 139),
             centerX: W / 2, top: VISIBLE + 88)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

var failed = false
for (scale, name) in [(CGFloat(1), "background.png"), (2, "background@2x.png")] {
    if let d = render(scale: scale) { try? d.write(to: outDir.appendingPathComponent(name)) } else { failed = true }
}
exit(failed ? 1 : 0)
