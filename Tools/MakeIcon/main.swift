import AppKit

// Kullanım: MakeIcon <çıktı.iconset klasörü>
// Sources/IconRenderer.swift ile birlikte derlenir (install.sh). iconutil ile .icns'e çevrilir.
let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("Kullanım: MakeIcon <AppIcon.iconset>\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func png(_ image: NSImage, pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let icon = IconRenderer.appIcon(size: 1024)
var failed = false
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        if let data = png(icon, pixels: px) {
            try? data.write(to: outDir.appendingPathComponent(name))
        } else {
            failed = true
        }
    }
}
exit(failed ? 1 : 0)
