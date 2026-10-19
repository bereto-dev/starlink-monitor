// Renders appicon.png (1024x1024) and Resources/AppIcon.icns.
// Same recipe as the other menu bar apps: diagonal gradient rounded square + white glyph.
// The glyph is the dish from tools/dish.svg (DishShape.swift), so run it through make-icon.sh:
//   tools/make-icon.sh      (from menubar/StarlinkBar)
import AppKit

let size = 1024
let base = NSColor(red: 0x3E / 255.0, green: 0x63 / 255.0, blue: 0xDD / 255.0, alpha: 1)  // #3E63DD
let light = base.blended(withFraction: 0.30, of: .white)!
let dark = base.blended(withFraction: 0.35, of: .black)!

func bitmap(_ draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let s = CGFloat(size)

let icon = bitmap {
    let ctx = NSGraphicsContext.current!.cgContext
    let path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                      cornerWidth: s * 0.225, cornerHeight: s * 0.225, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [light, base, dark].map { $0.usingColorSpace(.deviceRGB)!.cgColor } as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1])!
    // Top-left (light) to bottom-right (dark).
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
    ctx.restoreGState()
    // White dish, 72 % of the width, nudged up a little so it sits optically centered.
    let w = s * 0.72
    NSColor.white.setFill()
    DishShape.path(fitting: NSRect(x: (s - w) / 2, y: s * 0.03, width: w, height: s)).fill()
}

let png = icon.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "appicon.png"))

// .iconset -> .icns
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("StarlinkBar.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let source = NSImage(data: png)!
for (px, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"),
                   (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    source.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote appicon.png and Resources/AppIcon.icns" : "iconutil failed")
