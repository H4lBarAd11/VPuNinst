// VPuNinst. Copyright (c) 2026 Riccardo Nevoso. GPL-3.0-or-later; see LICENSE.
// Builds docs/splash.gif for the README: the launch splash's mark, drawn by
// the app's own SplashMark, on the house ivory.
//
//   swiftc -parse-as-library -o "$TMPDIR/make-splash" tools/make-splash.swift \
//     Sources/Splash.swift Sources/Flake.swift Sources/Theme.swift && "$TMPDIR/make-splash"
//
// The flake blooms and VPN is written in, on the splash's own clock, then
// it holds a moment and starts again. The window opening out of the flake is
// left out: it is the window, not the mark.
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@main
struct MakeSplash {
    @MainActor
    static func main() {
        for w in ["400", "500", "700"] {
            CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: "Resources/fonts/dm-sans-\(w).woff2") as CFURL, .process, nil)
        }
        let fps = 25.0, length = 2.0, hold = 1.6
        let out = URL(fileURLWithPath: "docs/splash.gif")
        let count = Int(length * fps) + 1
        guard let gif = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            print("couldn't write \(out.path)"); exit(1)
        }
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for i in 0..<count {
            let t = Double(i) / fps
            // As SplashView computes them.
            let bloom = min(1, max(0, (t - Splash.bloomStart) / Splash.bloomTime))
            let eased = bloom < 0.5 ? 2 * bloom * bloom : 1 - 2 * (1 - bloom) * (1 - bloom)
            let pen = 0.5 - 0.5 * cos(.pi * min(1, max(0, (t - Splash.penStart) / Splash.penTime)))
            let frame = SplashMark(bloom: eased, pen: pen)
                .frame(width: 340, height: 300)
                .background(Theme.ivory)
            let r = ImageRenderer(content: frame)
            r.scale = 2
            guard let img = r.cgImage else { print("couldn't draw frame \(i)"); exit(1) }
            let delay = i == count - 1 ? hold : 1 / fps
            CGImageDestinationAddImage(gif, img, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(gif) else { print("couldn't finish \(out.path)"); exit(1) }
        print("wrote docs/splash.gif, \(count) frames")
    }
}
