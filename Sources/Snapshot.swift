import AppKit
import SwiftUI

/// Developer tool: `Shepit --snapshot <dir>` renders every screen to PNG off-screen (no window is shown,
/// hotkeys and the recognition worker stay off). Used for before/after design reviews.
@MainActor
enum SnapshotTool {
    static func render<V: View>(_ view: V, size: NSSize, dark: Bool, background: NSColor? = nil, to path: String) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(
            contentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        win.appearance = appearance
        win.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        rep.size = size
        // Paint the window colour first: the hosting view itself is transparent
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            var fill = background ?? NSColor.windowBackgroundColor
            appearance?.performAsCurrentDrawingAppearance {
                fill = fill.usingColorSpace(.deviceRGB) ?? fill
            }
            fill.setFill()
            NSRect(origin: .zero, size: size).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        win.contentView = nil
    }

    static func runMainWindow(outDir: String) {
        let app = AppState.shared
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        for dark in [true, false] {
            for section in AppSection.allCases {
                app.selectedSection = section
                let name = "\(section.rawValue)_\(dark ? "dark" : "light").png"
                render(MainDashboardView(app: app), size: NSSize(width: 960, height: 650), dark: dark, to: "\(outDir)/\(name)")
            }
        }
    }
}
