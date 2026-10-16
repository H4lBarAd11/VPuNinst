// VPuNinst. Copyright (c) 2026 Riccardo Nevoso. GPL-3.0-or-later; see LICENSE.
import AppKit
import CoreText
import SwiftUI

// The splash: the icon's mark, alone where the window is about to appear. The
// flake blooms out of its centre, turning as it opens; VPN is then lettered in
// beneath it, as if by a pen; and the window opens out of the flake, above the
// mark and swallowing it, until it is the main window's exact shape. The real window
// then takes its place underneath and the splash fades off it.
//
// It has a window of its own: borderless, clear, over the whole screen, and
// deaf to the mouse, so it is never an invisible pane in the way of a click.
// The main window is kept unseen until the hand-over. Launch only: opening
// the window again from the menu bar is instant, as it should be.
//
// It plays where the window is. Opened from a full-screen app, the window
// lands on a desktop, since a full-screen space holds its own app alone: the
// splash first takes you there, as switching to the app does, and plays once
// you have arrived. Played where you were, it would open out to a window
// that isn't there.
//
// The pane is the window itself, drawn from the real one while it is still
// unseen. A plain pane in the window's colours, the first version, read
// against an ivory app behind as an empty, clear window for the quarter
// second before the real one arrived.
@MainActor
enum Splash {
    // Seconds from the first frame. One clock, and nothing paces it: the app
    // has nothing slow to wait for, so the mark is the whole of the wait.
    static let bloomStart = 0.08, bloomTime = 1.0   // the flake is open at 1.08
    static let penStart = 0.7, penTime = 1.1        // VPN is written at 1.8
    static let leave = 2.0                          // a beat later, the window opens out
    static let out = 0.55, fade = 0.2
    /// Before the pane opens, the window is ordered front unseen and given
    /// this long to settle: Stage Manager moves windows as they come forward.
    static let settle = 0.15
    // Reduce Motion: the mark shown whole, faded in and out, nothing turning or
    // growing. The effect is the motion, so what is left is only the hand-over.
    static let stillIn = 0.3, stillLeave = 1.0, stillOut = 0.3
    /// How long macOS takes to give a new window its space; then, when that
    /// is another one, how long the switch there may take, and a beat after
    /// it for the slide between spaces to end.
    static let placed = 0.2, arrival = 2.0, slide = 0.25

    private static var shown: Showing?
    /// Whether the splash is still standing in for the main window.
    static let cover = Cover()

    /// The window's sheet waits on this. A sheet is a window of its own, so
    /// it doesn't share the main window's alpha: a sign-in that starts at
    /// launch (Keep connected picking a dropped tunnel back up) opened in
    /// mid-air over the flake, before the window it belongs to appeared.
    final class Cover: ObservableObject {
        @Published fileprivate(set) var covering = false
    }

    /// At launch, once SwiftUI has put the main window up. With no window
    /// opening there is nothing to open out to, and no splash.
    static func show() {
        guard shown == nil,
              let main = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true }),
              main.isVisible, let screen = main.screen ?? NSScreen.main else { return }
        cover.covering = true
        // Unseen by its alpha, and deaf to the clicks aimed at the flake, but
        // left ordered in: ordered out and back, the window lost its sheets
        // to another desktop. The sign-in sheet opened out of sight, still
        // attached (Escape reached it), so the sign-in waited on a page no
        // one could see.
        main.alphaValue = 0
        main.ignoresMouseEvents = true
        // Coming forward is what takes you to the window's space, when it is
        // on another one; on the space in front of you it changes nothing.
        NSApp.activate(ignoringOtherApps: true)
        main.makeKeyAndOrderFront(nil)
        Task { @MainActor in
            // A new window counts as on the space in front of you until macOS
            // has placed it, a moment later: from a full-screen app, on a desktop.
            try? await Task.sleep(for: .seconds(placed))
            if !main.isOnActiveSpace {
                AppLog.write("splash: the window is on another space; waiting to get there")
                let asked = Date()
                while !main.isOnActiveSpace, Date().timeIntervalSince(asked) < arrival {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard main.isOnActiveSpace else {
                    // Spaces set not to follow an app (Desktop & Dock): the
                    // window stays where it opened, shown at once, with no splash.
                    AppLog.write("splash: no switch to the window's space; shown without it")
                    main.alphaValue = 1
                    main.ignoresMouseEvents = false
                    return done()
                }
                try? await Task.sleep(for: .seconds(slide))
            }
            shown = Showing(main: main, screen: screen)
        }
    }

    fileprivate static func done() {
        cover.covering = false
        shown = nil
    }

    /// The panel, and the hand-over from it to the main window. (A nested
    /// type doesn't inherit the enum's actor, hence its own.)
    @MainActor private final class Showing {
        let panel: NSPanel
        let model: SplashModel
        let main: NSWindow

        init(main: NSWindow, screen: NSScreen) {
            self.main = main
            let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            // The mark goes in the middle of where the window is. It isn't moved
            // there: SwiftUI puts it back where it was last left.
            let s = screen.frame, f = main.frame
            model = SplashModel(anchor: CGPoint(x: f.midX - s.minX, y: s.maxY - f.midY), still: still)

            panel = NSPanel(contentRect: s, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .floating
            // Never over a full-screen app: the window it opens out to can't be there.
            panel.collectionBehavior = [.transient, .ignoresCycle]
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: SplashView(model: model))
            panel.setFrame(s, display: false)
            model.began = { [weak self] in self?.run() }
            panel.orderFrontRegardless()
            // The clock starts at the first frame; a splash that never draws
            // one still hands over, rather than leaving the window hidden.
            Task { @MainActor [model] in
                try? await Task.sleep(for: .seconds(1))
                model.begin()
            }
        }

        private func run() {
            let leave = model.still ? Splash.stillLeave : Splash.leave
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(leave - Splash.settle))
                main.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(Splash.settle))
                openOut()
            }
        }

        private func openOut() {
            // Read where the window really is now, in the panel's coordinates
            // (AppKit's origin is bottom-left, the view's top-left).
            if main.isVisible {
                let s = panel.frame, f = main.frame
                model.look = Self.snapshot(main)
                model.window = CGRect(x: f.minX - s.minX, y: s.maxY - f.maxY, width: f.width, height: f.height)
            }
            model.leftAt = Date()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(model.still ? Splash.stillOut : Splash.out))
                handOver()
            }
        }

        /// The window as it looks, title bar and all, drawn from its views
        /// while its alpha is still 0.
        private static func snapshot(_ w: NSWindow) -> NSImage? {
            guard let v = w.contentView?.superview ?? w.contentView,
                  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
            v.cacheDisplay(in: v.bounds, to: rep)
            let img = NSImage(size: v.bounds.size)
            img.addRepresentation(rep)
            return img
        }

        private func handOver() {
            main.alphaValue = 1
            main.ignoresMouseEvents = false
            // The window is real again; a waiting sheet slides in under the fade.
            Splash.cover.covering = false
            NSAnimationContext.runAnimationGroup({ c in
                c.duration = Splash.fade
                panel.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor in
                    self.panel.orderOut(nil)
                    Splash.done()
                }
            })
        }
    }
}

@MainActor
final class SplashModel: ObservableObject {
    let anchor: CGPoint
    let still: Bool
    var began: (() -> Void)?
    @Published var start: Date?
    /// The main window's frame and how it looks, set when the pane opens out to it.
    @Published var window: CGRect?
    @Published var look: NSImage?
    @Published var leftAt: Date?

    init(anchor: CGPoint, still: Bool) {
        self.anchor = anchor
        self.still = still
    }

    func begin() {
        guard start == nil else { return }
        start = Date()
        began?()
    }
}

struct SplashView: View {
    @ObservedObject var model: SplashModel

    var body: some View {
        TimelineView(.animation) { tl in
            let t = model.start.map { tl.date.timeIntervalSince($0) } ?? 0
            let o = model.leftAt.map { tl.date.timeIntervalSince($0) } ?? -1
            let flakeAt = CGPoint(x: model.anchor.x, y: model.anchor.y + SplashMark.flakeOffset)
            ZStack(alignment: .topLeading) {
                mark(t, o)
                    .position(model.anchor)
                if let w = model.window {
                    pane(w, from: flakeAt, o)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // From the moment the pane sets out, everything is held inside the
            // window's frame: the flake spreads within the window itself, and
            // nothing of it, glow included, is drawn outside.
            .clipShape(WindowFrame(rect: model.window))
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .onAppear { model.begin() }
    }

    @ViewBuilder
    private func mark(_ t: Double, _ o: Double) -> some View {
        if model.still {
            SplashMark(bloom: 1, pen: 1, still: true)
                .opacity(o < 0 ? clamp01(t / Splash.stillIn) : 1 - clamp01(o / Splash.stillOut))
        } else {
            let bloom = easeInOut(clamp01((t - Splash.bloomStart) / Splash.bloomTime))
            let pen = 0.5 - 0.5 * cos(.pi * clamp01((t - Splash.penStart) / Splash.penTime))
            // Opening out: the mark spreads from the flake's centre beneath the
            // pane, and fades in the last of it; whatever the pane hasn't
            // reached by then goes with it.
            let spread = o < 0 ? 0 : CubicBezier.standard(clamp01(o / Splash.out))
            let gone = o < 0 ? 0 : clamp01((o - 0.08) / 0.4)
            SplashMark(bloom: bloom, pen: pen)
                .scaleEffect(1 + 1.4 * spread, anchor: SplashMark.flakeAnchor)
                .opacity(1 - gone * gone)
        }
    }

    /// The window, growing out of the flake as a disc: from the flake's centre
    /// (kept inside the window, wherever the system put it) out to the
    /// farthest corner, above the mark, so that it swallows the mark as it
    /// reaches it and the mark is never drawn over the window.
    private func pane(_ w: CGRect, from c: CGPoint, _ o: Double) -> some View {
        let x = min(max(c.x, w.minX), w.maxX), y = min(max(c.y, w.minY), w.maxY)
        let far = [CGPoint(x: w.minX, y: w.minY), CGPoint(x: w.maxX, y: w.minY),
                   CGPoint(x: w.minX, y: w.maxY), CGPoint(x: w.maxX, y: w.maxY)]
            .map { hypot($0.x - x, $0.y - y) }.max()! + 1
        let r = model.still ? far : far * CubicBezier.pane(clamp01(o / Splash.out))
        let shown = model.still ? clamp01(o / Splash.stillOut) : clamp01(o / 0.12)
        return Group {
            if let look = model.look { Image(nsImage: look).resizable() } else { Theme.ivory }
        }
        .frame(width: w.width, height: w.height)
        .mask(alignment: .topLeading) {
            Circle()
                .frame(width: 2 * r, height: 2 * r)
                .offset(x: x - w.minX - r, y: y - w.minY - r)
        }
        .position(x: w.midX, y: w.midY)
        .opacity(shown)
    }
}

/// The main window's shape once the pane sets out; the whole screen before.
private struct WindowFrame: Shape {
    var rect: CGRect?
    func path(in bounds: CGRect) -> Path {
        guard let rect else { return Path(bounds) }
        return Path(roundedRect: rect, cornerRadius: 16, style: .continuous)
    }
}

/// The mark itself, as a pure function of how far the flake has opened and how
/// far VPN has been written. Laid out as the icon is: the flake 504 px across
/// with VPN set at 150 px, 42 px below it, all in DM Sans Bold.
struct SplashMark: View {
    var bloom: Double
    var pen: Double
    var still = false

    static let diameter: CGFloat = 180
    static let fontSize = diameter * 150 / 504
    static let gap = diameter * 42 / 504
    static let cap = fontSize * 0.7              // DM Sans's cap height, 700 of 1000
    static let margin: CGFloat = 16              // room for the glow
    static let size = CGSize(width: diameter + 2 * margin,
                             height: margin + diameter + gap + cap + margin)
    static let flakeCentre = CGPoint(x: size.width / 2, y: margin + diameter / 2)
    static let flakeAnchor = UnitPoint(x: 0.5, y: flakeCentre.y / size.height)
    /// Where the flake's centre is from the mark's, which is what gets placed.
    static let flakeOffset = flakeCentre.y - size.height / 2
    /// Points to one of the flake's units.
    private static let unit = diameter / 2 / Flake.radius

    private static let word = Word(size: fontSize,
                                   baseline: CGPoint(x: size.width / 2, y: margin + diameter + gap + cap))

    var body: some View {
        Canvas { ctx, _ in
            drawFlake(ctx)
            drawWord(ctx)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        // An ivory edge, the app's own ground: over a dark wallpaper the
        // caramel flake and the charcoal letters alone would all but disappear,
        // and over a light one it doesn't show. Tight, and twice over rather
        // than wide: a wide glow pools where the chevrons meet the spine and
        // leaves them looking smudged.
        .shadow(color: Theme.ivory, radius: 0.8)
        .shadow(color: Theme.ivory, radius: 0.8)
        .shadow(color: Theme.ivory.opacity(0.35), radius: 6)
    }

    /// The centre first, a little past full and back; then the arms in turn,
    /// clockwise from the top, each a little behind the last, each spine
    /// growing out with its chevrons unfolding from it. The whole flake turns
    /// as it opens, a sixth of a turn behind and home as it finishes, and
    /// grows from three quarters of its size. Caramel arms and an ink centre,
    /// as on the icon.
    private func drawFlake(_ ctx: GraphicsContext) {
        guard bloom > 0 else { return }
        var c = ctx
        let e = easeOut(bloom)
        c.translateBy(x: Self.flakeCentre.x, y: Self.flakeCentre.y)
        c.scaleBy(x: Self.unit, y: Self.unit)
        if !still {
            c.rotate(by: .degrees(-60 * (1 - e)))
            c.scaleBy(x: 0.75 + 0.25 * e, y: 0.75 + 0.25 * e)
        }
        let p = bloom
        let arms = Flake.arms { k in (p - 0.06 - 0.035 * Double(k)) / 0.75 }
        c.stroke(arms, with: .color(Theme.caramel),
                 style: StrokeStyle(lineWidth: Flake.stroke, lineCap: .round, lineJoin: .round))
        let grown = clamp01(p / 0.12)
        let r = Flake.core * (grown < 1 ? easeOut(grown) * 1.15 : 1)
        c.fill(Path(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)), with: .color(Theme.ink))
    }

    /// V, P and N lettered in together, each over the whole of the clock at its
    /// own pace, so they set out and arrive at once. Each is the font's own
    /// letter uncovered by a round pen moving along its spine, so the letters
    /// end exactly as the icon sets them, square corners and all.
    private func drawWord(_ ctx: GraphicsContext) {
        let q = still ? 1 : pen
        guard q > 0 else { return }
        for letter in Self.word.letters {
            var c = ctx
            if q < 1 {
                c.clipToLayer { m in
                    m.stroke(letter.spine.trimmedPath(from: 0, to: q), with: .color(.black),
                             style: StrokeStyle(lineWidth: Self.word.pen, lineCap: .round, lineJoin: .round))
                }
            }
            c.fill(letter.glyph, with: .color(Theme.ink))
        }
    }
}

/// VPN in DM Sans Bold, spaced as the icon sets it (0.08 em apart), with each
/// letter's spine: the line a pen follows to write it, in font units (1000 to
/// the em, y up), on the centre line of the letter's strokes. Each spine starts
/// a pen's radius outside its letter, so the ink grows from nothing where the
/// pen lands rather than appearing as a dot, and ends past it, so the pen's
/// round end covers the square corners.
private struct Word {
    struct Letter { let glyph: Path; let spine: Path }
    let letters: [Letter]
    /// Barely wider than the stems (135 units). A wider pen covers more
    /// loosely but reaches past a stem into what joins it: going up P's stem it
    /// uncovered the ends of the bowl, and the P passed for an F. The spines
    /// are close enough for this one to leave nothing of a letter uncovered.
    let pen: CGFloat

    private static let spines: [(Character, Path)] = [
        // Down the left arm and up the right; the turn is below the letter.
        ("V", Path { $0.addLines([.init(x: 55, y: 790), .init(x: 353, y: -50), .init(x: 651, y: 790)]) }),
        // Up the stem and into its corner, over the top, round the bowl and
        // back to the stem. The bowl's centre line is squarer than an ellipse.
        ("P", Path { p in
            p.addLines([.init(x: 136.5, y: -90), .init(x: 136.5, y: 680), .init(x: 175, y: 645),
                        .init(x: 345, y: 645)])
            p.addCurve(to: .init(x: 513, y: 484), control1: .init(x: 446, y: 645),
                       control2: .init(x: 513, y: 581))
            p.addCurve(to: .init(x: 345, y: 319), control1: .init(x: 513, y: 385),
                       control2: .init(x: 446, y: 319))
            p.addLine(to: .init(x: 170, y: 319))
        }),
        // Up, down the diagonal and up again.
        ("N", Path { $0.addLines([.init(x: 136.5, y: -90), .init(x: 136.5, y: 692), .init(x: 593.5, y: 7),
                                  .init(x: 593.5, y: 790)]) }),
    ]

    init(size: CGFloat, baseline: CGPoint) {
        let font = CTFontCreateWithName("DMSans9pt-Bold" as CFString, size, nil)
        let s = size / 1000
        pen = 144 * s
        var shapes: [(glyph: CGPath?, advance: CGFloat)] = []
        for (ch, _) in Self.spines {
            var u = Array(String(ch).utf16), g: CGGlyph = 0, adv = CGSize.zero
            CTFontGetGlyphsForCharacters(font, &u, &g, 1)
            CTFontGetAdvancesForGlyphs(font, .horizontal, &g, &adv, 1)
            shapes.append((CTFontCreatePathForGlyph(font, g, nil), adv.width))
        }
        var x: CGFloat = 0, at: [CGFloat] = []
        for sh in shapes { at.append(x); x += sh.advance + 80 * s }
        // Centred on the ink, not the advances: the icon's trailing kern
        // leaves its VPN a hair left of the flake's centre.
        let left = at[0] + (shapes[0].glyph?.boundingBox.minX ?? 0)
        let right = at[2] + (shapes[2].glyph?.boundingBox.maxX ?? 0)
        let origin = baseline.x - (left + right) / 2

        letters = zip(Self.spines, zip(shapes, at)).map { spec, placed in
            // Font space (y up) to the canvas (y down), at this letter's place.
            let place = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: origin + placed.1, ty: baseline.y)
            return Letter(glyph: placed.0.glyph.map { Path($0).applying(place) } ?? Path(),
                          spine: spec.1.applying(CGAffineTransform(scaleX: s, y: s).concatenating(place)))
        }
    }
}

/// CSS's cubic-bezier(), the notation the hand-over's curves were designed in.
private enum CubicBezier {
    static func pane(_ t: Double) -> Double { curve(0.65, 0, 0.25, 1, t) }
    static func standard(_ t: Double) -> Double { curve(0.4, 0, 0.2, 1, t) }

    private static func curve(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ t: Double) -> Double {
        func b(_ a: Double, _ c: Double, _ u: Double) -> Double {
            3 * a * u * (1 - u) * (1 - u) + 3 * c * u * u * (1 - u) + u * u * u
        }
        // Solve x(u) = t by bisection; x is monotonic for these curves.
        var lo = 0.0, hi = 1.0
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if b(x1, x2, mid) < t { lo = mid } else { hi = mid }
        }
        return b(y1, y2, (lo + hi) / 2)
    }
}

private func easeInOut(_ v: Double) -> Double { v < 0.5 ? 2 * v * v : 1 - 2 * (1 - v) * (1 - v) }
