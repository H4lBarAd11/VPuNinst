// VPuNinst. Copyright (c) 2026 Riccardo Nevoso. GPL-3.0-or-later; see LICENSE.
// Builds Resources/AppIcon.icns and packaging/background.png.
//
//   swift tools/make-assets.swift
//
// The icon: the flake (Sources/Flake.swift, whose geometry is repeated here)
// in the house caramel with an ink centre, VPN in DM Sans Bold beneath it, on
// the house ivory, laid out on macOS's icon grid. The installer's background:
// the flake alone, faint, in the corner of the window, where it sits behind
// the installer's text in light and dark mode alike.
import AppKit

func hex(_ v: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255, alpha: 1)
}
let ivory = hex(0xF9F8EF), ink = hex(0x404040), caramel = hex(0x9A6636)

// The flake, as in Flake.swift: six arms 10 long, two chevrons each, strokes
// 1.5 wide with round ends, a centre 0.92 across its radius.
let reach: CGFloat = 10, stroke: CGFloat = 1.5, core: CGFloat = 0.92
let chevrons: [(apex: CGFloat, depth: CGFloat, half: CGFloat)] = [(2, 1.5, 2), (5.5, 3, 3)]

/// The flake centred on c, `across` from tip to tip, y up.
func flake(at c: NSPoint, across: CGFloat, arms armColor: NSColor = caramel, core coreColor: NSColor = ink) {
    let s = across / 2 / (reach + stroke / 2)
    let arms = NSBezierPath()
    for k in 0..<6 {
        let a = CGFloat.pi / 2 - CGFloat(k) * .pi / 3    // clockwise from the top
        func pt(_ along: CGFloat, _ side: CGFloat) -> NSPoint {
            NSPoint(x: c.x + s * (along * cos(a) + side * sin(a)), y: c.y + s * (along * sin(a) - side * cos(a)))
        }
        arms.move(to: pt(0, 0)); arms.line(to: pt(reach, 0))
        for ch in chevrons {
            arms.move(to: pt(ch.apex + ch.depth, -ch.half))
            arms.line(to: pt(ch.apex, 0))
            arms.line(to: pt(ch.apex + ch.depth, ch.half))
        }
    }
    arms.lineWidth = stroke * s
    arms.lineCapStyle = .round
    arms.lineJoinStyle = .round
    armColor.setStroke(); arms.stroke()
    coreColor.setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - core * s, y: c.y - core * s, width: 2 * core * s, height: 2 * core * s)).fill()
}

CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: "Resources/fonts/dm-sans-700.woff2") as CFURL, .process, nil)

func icon(_ px: Int) -> Data {
    let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    r.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: r)
    let s = CGFloat(px) / 1024
    // macOS icon grid: 824pt body, 100pt margin, ~185pt continuous corners.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 24 * s
    shadow.set()
    ivory.setFill(); shape.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    // hairline so the ivory body holds its edge on a light Dock
    caramel.withAlphaComponent(0.25).setStroke()
    shape.lineWidth = max(1, 4 * s); shape.stroke()

    // Above the lettering: 504 across, centred at 590.
    flake(at: NSPoint(x: 512 * s, y: 590 * s), across: 504 * s)

    let para = NSMutableParagraphStyle(); para.alignment = .center
    let font = NSFont(name: "DMSans9pt-Bold", size: 150 * s) ?? .boldSystemFont(ofSize: 150 * s)
    let text = NSAttributedString(string: "VPN", attributes: [
        .font: font, .foregroundColor: ink, .paragraphStyle: para, .kern: 12 * s])
    text.draw(in: NSRect(x: 100 * s, y: 150 * s, width: 824 * s, height: 190 * s))
    NSGraphicsContext.restoreGraphicsState()
    return r.representation(using: .png, properties: [:])!
}

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
                   ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
                   ("512x512", 512), ("512x512@2x", 1024)] {
    try! icon(px).write(to: tmp.appendingPathComponent("icon_\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", tmp.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: tmp)
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")

// 180 points square at twice the pixels: Installer draws it at the window's
// bottom left, unscaled. Caramel at a fifth of its strength, centre included,
// reads on Installer's light and dark panes and never competes with the text.
let bg = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 360, pixelsHigh: 360, bitsPerSample: 8,
                          samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bg.size = NSSize(width: 180, height: 180)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bg)
let faint = caramel.withAlphaComponent(0.2)
flake(at: NSPoint(x: 70, y: 70), across: 150, arms: faint, core: faint)
NSGraphicsContext.restoreGraphicsState()
try! bg.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "packaging/background.png"))
print("wrote packaging/background.png")
