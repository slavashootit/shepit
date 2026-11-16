import AppKit
import SwiftUI

extension SnapshotTool {
    /// Renders every pill and notch state. The live blur cannot be drawn off-screen, so a flat fill stands in.
    static func runHUD(outDir: String) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        Theme.flatSurfaces = true
        var wave: [CGFloat] = []
        for i in 0..<28 {
            let x = CGFloat(i)
            let carrier: CGFloat = abs(sin(x * 0.55))
            let envelope: CGFloat = 0.4 + 0.6 * abs(cos(x * 0.21))
            wave.append(0.18 + 0.7 * carrier * envelope)
        }
        let states: [(String, HUDPhase, Bool, Bool)] = [
            ("recording", .recording(handsFree: false), false, false),
            ("handsfree", .recording(handsFree: true), false, false),
            ("recording_offline", .recording(handsFree: false), true, false),
            ("transcribing", .transcribing(label: "Розпізнавання й обробка…"), false, false),
            ("done", .done, false, false),
            ("cancelled", .cancelled, false, false),
            ("toast_offline", .toast(icon: "wifi.slash", message: "Вставлено без онлайн-перевірки", tone: .neutral), false, false),
            ("toast_error", .toast(icon: "exclamationmark.triangle.fill", message: "Перевищено час очікування розпізнавання — аудіо збережено, його можна повторити з Історії", tone: .error), false, true)
        ]
        let backdrop = NSColor(calibratedRed: 0.36, green: 0.42, blue: 0.52, alpha: 1)
        for style in [RecordingWindowStyle.classic, .mini, .notch] {
            for (name, phase, offline, tappable) in states {
                let vm = HUDViewModel()
                vm.style = style
                vm.phase = phase
                vm.isShown = true
                vm.isOffline = offline
                vm.levels = wave
                vm.elapsedSeconds = 7
                vm.reduceMotion = true
                vm.notchWidth = 185
                vm.notchHeight = 32
                if tappable { vm.onToastTap = {} }
                if style == .classic, name == "recording" { vm.livePreviewText = "… це додаток на диск, мені потрібно змінити там акаунт" }
                let size = style == .notch ? NSSize(width: 520, height: 96) : NSSize(width: 560, height: 170)
                render(FloatingHUDView(vm: vm), size: size, dark: true, background: backdrop, to: "\(outDir)/\(style.rawValue)_\(name).png")
            }
        }
    }
}
