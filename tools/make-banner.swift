// VPuNinst. Copyright (c) 2026 Riccardo Nevoso. GPL-3.0-or-later; see LICENSE.
// Builds docs/banner.png for the README and docs/social.png for the repository's
// social preview, in the app's own type and colours.
//
//   swift tools/make-banner.swift
//
// PNGs rather than SVGs: GitHub renders README images without web fonts, and
// both should be set in DM Sans like the app. The social preview is the
// banner's composition, centred on the 1280 × 640 that GitHub asks for, and
// full-bleed: GitHub rounds and crops it itself. It is uploaded by hand, in
// the repository's Settings ▸ General ▸ Social preview.
import AppKit

func hex(_ v: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255, alpha: 1)
}
let ivory = hex(0xF9F8EF), ink = hex(0x404040), caramel = hex(0x9A6636)
let soft = ink.withAlphaComponent(0.78)

for w in ["400", "500", "700"] {
    CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: "Resources/fonts/dm-sans-\(w).woff2") as CFURL, .process, nil)
}
func font(_ w: String, _ size: CGFloat) -> NSFont { NSFont(name: "DMSans9pt-\(w)", size: size)! }

/// The composition, 1280 × 360, raised by `dy` on a card `height` tall.
func render(height H: Int, dy: CGFloat, corner: CGFloat, to path: String) {
    let W = 1280, scale = 2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W * scale, pixelsHigh: H * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let card = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: W, height: H), xRadius: corner, yRadius: corner)
    ivory.setFill(); card.fill()

    // The flake, as on the icon (Sources/Flake.swift): caramel arms, ink centre.
    let reach: CGFloat = 10, stroke: CGFloat = 1.5, core: CGFloat = 0.92
    let c = NSPoint(x: 194, y: 180 + dy), u = 210 / 2 / (reach + stroke / 2)
    let arms = NSBezierPath()
    for k in 0..<6 {
        let a = CGFloat.pi / 2 - CGFloat(k) * .pi / 3
        func pt(_ along: CGFloat, _ side: CGFloat) -> NSPoint {
            NSPoint(x: c.x + u * (along * cos(a) + side * sin(a)), y: c.y + u * (along * sin(a) - side * cos(a)))
        }
        arms.move(to: pt(0, 0)); arms.line(to: pt(reach, 0))
        for (apex, depth, half) in [(2, 1.5, 2), (5.5, 3, 3)] as [(CGFloat, CGFloat, CGFloat)] {
            arms.move(to: pt(apex + depth, -half)); arms.line(to: pt(apex, 0)); arms.line(to: pt(apex + depth, half))
        }
    }
    arms.lineWidth = stroke * u; arms.lineCapStyle = .round; arms.lineJoinStyle = .round
    caramel.setStroke(); arms.stroke()
    ink.setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - core * u, y: c.y - core * u, width: 2 * core * u, height: 2 * core * u)).fill()

    func draw(_ s: String, _ f: NSFont, _ c: NSColor, x: CGFloat, y: CGFloat, kern: CGFloat = 0) {
        NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c, .kern: kern])
            .draw(at: NSPoint(x: x, y: y + dy))
    }
    draw("VPuNinst", font("Bold", 76), ink, x: 360, y: 178, kern: -1.5)
    draw("Your institutions’ VPNs on macOS, side by side.", font("Regular", 26), soft, x: 364, y: 136)

    // Three facts, separated by caramel dots.
    var x: CGFloat = 364
    for (i, t) in ["Touch ID", "Stays connected", "Leaves your DNS alone"].enumerated() {
        if i > 0 {
            caramel.setFill()
            NSBezierPath(ovalIn: NSRect(x: x + 12, y: 92 + dy, width: 7, height: 7)).fill()
            x += 32
        }
        let a = NSAttributedString(string: t, attributes: [.font: font("Medium", 20), .foregroundColor: ink])
        a.draw(at: NSPoint(x: x, y: 84 + dy))
        x += a.size().width
    }

    caramel.setFill()
    NSRect(x: 364, y: 62 + dy, width: 56, height: 3).fill()

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

render(height: 360, dy: 0, corner: 28, to: "docs/banner.png")
render(height: 640, dy: 140, corner: 0, to: "docs/social.png")
