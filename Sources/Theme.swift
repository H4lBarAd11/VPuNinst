// VPuNinst. Copyright (c) 2026 Riccardo Nevoso. GPL-3.0-or-later; see LICENSE.
import AppKit
import SwiftUI

// House style: DM Sans, ivory ground (never flat white), charcoal ink.
// Caramel is the accent; it marks the tunnels, their actions and the flake,
// nothing else. #ADAFB0 never carries text.
enum Theme {
    static let ivory = Color(hex: 0xF9F8EF)
    static let card = Color(hex: 0xF1EFE3)
    static let ink = Color(hex: 0x404040)
    static let inkSoft = Color(hex: 0x404040).opacity(0.78)
    static let neutral = Color(hex: 0xADAFB0)
    static let caramel = Color(hex: 0x9A6636)
    static let caramelTint = Color(hex: 0xF8F1E8)
    static let hairline = Color(hex: 0x404040).opacity(0.12)

    static func registerFonts() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("fonts") else { return }
        for w in ["400", "500", "700"] {
            let url = dir.appendingPathComponent("dm-sans-\(w).woff2")
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    enum Weight: String { case regular = "Regular", medium = "Medium", bold = "Bold" }

    // Size-specific tracking: tighter as type grows, open at caption sizes.
    static func font(_ size: CGFloat, _ w: Weight = .regular) -> Font {
        .custom("DMSans9pt-\(w.rawValue)", fixedSize: size)
    }
    static func tracking(_ size: CGFloat) -> CGFloat {
        size >= 20 ? -0.4 : size <= 12 ? 0.2 : 0
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}

extension Text {
    func house(_ size: CGFloat, _ w: Theme.Weight = .regular, _ color: Color = Theme.ink) -> some View {
        self.font(Theme.font(size, w)).tracking(Theme.tracking(size)).foregroundStyle(color)
    }
}

/// Press feedback: scale to .97, no overshoot, and none at all under Reduce Motion.
struct PressScale: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
