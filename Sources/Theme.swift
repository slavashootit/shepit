import SwiftUI
import AppKit

/// One place for the app's visual constants: a single accent, three radii, one type scale.
enum Theme {
    // Accent — the waveform's mint. Everything else stays quiet.
    static let accent = Color(red: 0.24, green: 0.86, blue: 0.66)
    static let handsFree = Color(red: 1.0, green: 0.68, blue: 0.24)
    static let danger = Color(red: 0.98, green: 0.36, blue: 0.34)
    static let warning = Color(red: 0.98, green: 0.62, blue: 0.22)
    static let offline = Color(white: 0.62)

    // Radii: small controls, cards, large surfaces
    static let radiusS: CGFloat = 7
    static let radiusM: CGFloat = 12
    static let radiusL: CGFloat = 16

    // Type scale (pt). Two weights only: regular and semibold.
    static let caption: CGFloat = 11
    static let body: CGFloat = 13
    static let title: CGFloat = 15
    static let headline: CGFloat = 20
    static let display: CGFloat = 34

    static func font(_ size: CGFloat, strong: Bool = false) -> Font {
        .system(size: size, weight: strong ? .semibold : .regular)
    }

    static func digits(_ size: CGFloat, strong: Bool = true) -> Font {
        .system(size: size, weight: strong ? .semibold : .regular, design: .rounded).monospacedDigit()
    }

    /// Snapshot tool only: replace live blur with a flat fill (blur cannot be rendered off-screen).
    static var flatSurfaces = false

    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Standard state-change spring; collapses to a short fade when the system asks for less motion.
    static var spring: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.34, dampingFraction: 0.78)
    }
}

/// System blur material for floating surfaces.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

/// Floating surface: live blur on screen, flat stand-in for off-screen snapshots.
struct HUDSurface: View {
    var body: some View {
        if Theme.flatSurfaces {
            Color(red: 0.10, green: 0.11, blue: 0.13)
        } else {
            VisualEffectBackground().overlay(Color.black.opacity(0.34))
        }
    }
}
