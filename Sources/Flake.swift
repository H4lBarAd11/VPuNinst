// VPuNinst. Copyright (c) 2026 Riccardo Nevoso. GPL-3.0-or-later; see LICENSE.
import AppKit
import SwiftUI

/// The mark: a six-armed snowflake, each arm a spine with two chevrons, and a
/// round centre. In the flake's own units the arms are 10 long from the
/// centre, the strokes 1.5 wide with round ends, and the centre 0.92 across
/// its radius. Caramel arms and an ink centre on the app's ivory.
enum Flake {
    static let reach: CGFloat = 10
    static let stroke: CGFloat = 1.5
    static let core: CGFloat = 0.92
    /// Out along the spine to where each chevron meets it, how far its ends
    /// sweep back out, and how far to either side they reach.
    static let chevrons: [(apex: CGFloat, depth: CGFloat, half: CGFloat)] = [(2, 1.5, 2), (5.5, 3, 3)]
    /// From the centre to the tip of an arm, round end included.
    static let radius = reach + stroke / 2

    /// One arm pointing up, open by q (0…1): the spine grows out of the
    /// centre and each chevron unfolds from it as the spine passes its apex.
    static func arm(_ q: Double) -> Path {
        let r = reach * easeOut(clamp01(q))
        return Path { p in
            guard r > 0 else { return }
            p.move(to: .zero)
            p.addLine(to: CGPoint(x: 0, y: -r))
            for c in chevrons {
                let u = easeOut(clamp01((r - c.apex) / (c.depth + 1)))
                guard u > 0 else { continue }
                p.move(to: CGPoint(x: -c.half * u, y: -(c.apex + c.depth * u)))
                p.addLine(to: CGPoint(x: 0, y: -c.apex))
                p.addLine(to: CGPoint(x: c.half * u, y: -(c.apex + c.depth * u)))
            }
        }
    }

    /// The six arms round the origin, in flake units; arm k open by open(k),
    /// clockwise from the top.
    static func arms(open: (Int) -> Double = { _ in 1 }) -> Path {
        var all = Path()
        for k in 0..<6 {
            all.addPath(arm(open(k)), transform: CGAffineTransform(rotationAngle: .pi / 3 * CGFloat(k)))
        }
        return all
    }

    /// The whole flake, centred in a square of side `side`, stroked and ready to fill.
    static func shapes(side: CGFloat, stroke width: CGFloat = stroke) -> (arms: Path, core: Path) {
        let s = side / 2 / (reach + width / 2)
        let t = CGAffineTransform(translationX: side / 2, y: side / 2).scaledBy(x: s, y: s)
        let arms = arms().strokedPath(StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        let core = Path(ellipseIn: CGRect(x: -Flake.core, y: -Flake.core, width: 2 * Flake.core, height: 2 * Flake.core))
        return (arms.applying(t), core.applying(t))
    }
}

/// The flake as a view: caramel arms, ink centre.
struct FlakeMark: View {
    var arms: Color = Theme.caramel
    var core: Color = Theme.ink

    var body: some View {
        Canvas { ctx, size in
            let f = Flake.shapes(side: min(size.width, size.height))
            ctx.fill(f.arms, with: .color(arms))
            ctx.fill(f.core, with: .color(core))
        }
    }
}

/// The flake as a menu-bar template image: macOS draws it black on a light bar
/// and white on a dark one, and inverts it when highlighted, so one image
/// covers both modes. At 18pt the inner chevrons and the centre run together
/// into a blot, so the menu bar's flake has the spines and outer chevrons
/// alone, a little heavier. Full strength while a tunnel is up, dimmed while
/// none is.
enum MenuIcon {
    private static let cache = [true: make(up: true), false: make(up: false)]

    static func image(up: Bool) -> NSImage { cache[up]! }

    private static func make(up: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext, let outer = Flake.chevrons.last else { return false }
            let width: CGFloat = 1.8, s = rect.width / 2 / (Flake.reach + width / 2)
            let arm = Path { p in
                p.move(to: .zero)
                p.addLine(to: CGPoint(x: 0, y: -Flake.reach))
                p.move(to: CGPoint(x: -outer.half, y: -(outer.apex + outer.depth)))
                p.addLine(to: CGPoint(x: 0, y: -outer.apex))
                p.addLine(to: CGPoint(x: outer.half, y: -(outer.apex + outer.depth)))
            }
            var arms = Path()
            for k in 0..<6 { arms.addPath(arm, transform: CGAffineTransform(rotationAngle: .pi / 3 * CGFloat(k))) }
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.scaleBy(x: s, y: s)
            ctx.addPath(arms.cgPath)
            ctx.setLineWidth(width)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(up ? 1 : 0.45).cgColor)
            ctx.strokePath()
            return true
        }
        img.isTemplate = true
        return img
    }
}

func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }
func easeOut(_ v: Double) -> Double { 1 - pow(1 - v, 3) }
