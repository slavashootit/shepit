import AppKit
import SwiftUI

// MARK: - Vector App Icon Renderer (1024x1024 macOS Squircle)

enum AppIconGenerator {
    static func writePNG(to path: String) -> Bool {
        let size = 1024
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return false }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            NSGraphicsContext.restoreGraphicsState()
            return false
        }

        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        ctx.clear(rect)

        let inset: CGFloat = 92
        let cardRect = rect.insetBy(dx: inset, dy: inset)
        let cornerRadius: CGFloat = 196
        let squircle = CGPath(roundedRect: cardRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        // Outer drop shadow
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 44, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.addPath(squircle)
        ctx.setFillColor(NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.12, alpha: 1.0).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // Clipped squircle interior
        ctx.saveGState()
        ctx.addPath(squircle)
        ctx.clip()

        let space = CGColorSpaceCreateDeviceRGB()
        let bgColors = [
            NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.21, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.09, alpha: 1.0).cgColor
        ] as CFArray
        if let bgGrad = CGGradient(colorsSpace: space, colors: bgColors, locations: [0.0, 1.0]) {
            ctx.drawLinearGradient(
                bgGrad,
                start: CGPoint(x: cardRect.midX, y: cardRect.maxY),
                end: CGPoint(x: cardRect.midX, y: cardRect.minY),
                options: []
            )
        }

        // Ambient emerald-indigo aura glow in center
        let glowColors = [
            NSColor(calibratedRed: 0.18, green: 0.84, blue: 0.68, alpha: 0.28).cgColor,
            NSColor(calibratedRed: 0.28, green: 0.44, blue: 0.96, alpha: 0.08).cgColor,
            NSColor.clear.cgColor
        ] as CFArray
        if let glowGrad = CGGradient(colorsSpace: space, colors: glowColors, locations: [0.0, 0.55, 1.0]) {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            ctx.drawRadialGradient(
                glowGrad,
                startCenter: center,
                startRadius: 20,
                endCenter: center,
                endRadius: 360,
                options: []
            )
        }

        // 7 Sculpted Acoustic Waveform Bars
        let heights: [CGFloat] = [148, 256, 396, 504, 396, 256, 148]
        let barWidth: CGFloat = 52
        let spacing: CGFloat = 34
        let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * spacing
        let startX = rect.midX - totalWidth / 2.0

        let barGradColors = [
            NSColor(calibratedRed: 0.30, green: 0.94, blue: 0.74, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.22, green: 0.72, blue: 0.94, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.40, green: 0.48, blue: 0.98, alpha: 1.0).cgColor
        ] as CFArray
        let barGrad = CGGradient(colorsSpace: space, colors: barGradColors, locations: [0.0, 0.52, 1.0])

        for (i, h) in heights.enumerated() {
            let x = startX + CGFloat(i) * (barWidth + spacing)
            let y = rect.midY - h / 2.0
            let barRect = CGRect(x: x, y: y, width: barWidth, height: h)
            let barPath = CGPath(roundedRect: barRect, cornerWidth: barWidth / 2.0, cornerHeight: barWidth / 2.0, transform: nil)

            ctx.saveGState()
            ctx.setShadow(
                offset: CGSize(width: 0, height: -6),
                blur: 22,
                color: NSColor(calibratedRed: 0.22, green: 0.86, blue: 0.70, alpha: 0.38).cgColor
            )
            ctx.addPath(barPath)
            ctx.clip()
            if let barGrad {
                ctx.drawLinearGradient(
                    barGrad,
                    start: CGPoint(x: barRect.midX, y: cardRect.maxY - 120),
                    end: CGPoint(x: barRect.midX, y: cardRect.minY + 120),
                    options: []
                )
            }
            ctx.restoreGState()
        }

        ctx.restoreGState()

        // Crisp inner glass rim
        ctx.saveGState()
        ctx.addPath(squircle)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.15).cgColor)
        ctx.setLineWidth(4.0)
        ctx.strokePath()
        ctx.restoreGState()

        NSGraphicsContext.restoreGraphicsState()

        guard let pngData = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try pngData.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Application Delegate & Menu Bar Controller

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = AppState.shared
        setupMainMenu()
        setupStatusBarItem()

        app.onMenuStateChanged = { [weak self] in
            self?.rebuildStatusMenu()
            self?.updateStatusButtonIcon()
        }
        app.onOpenMainWindowRequested = { [weak self] section in
            if let section {
                app.selectedSection = section
            }
            self?.showMainWindow()
        }

        showMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running quietly in Menu Bar so Right Option hotkey always works instantaneously!
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.hotkeyManager.stop()
        AppState.shared.engine.shutdown()
    }

    // MARK: - Main Dashboard Window

    func showMainWindow() {
        if mainWindow == nil {
            let rootView = MainDashboardView(app: AppState.shared)
            let hosting = NSHostingController(rootView: rootView)
            let win = NSWindow(contentViewController: hosting)
            win.title = "Шепіт"
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.setContentSize(NSSize(width: 960, height: 650))
            win.center()
            win.isReleasedWhenClosed = false
            win.delegate = self
            mainWindow = win
        }
        AppState.shared.reloadStats()
        AppState.shared.reloadHistory()
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Menu Bar Status Item

    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusButtonIcon()
        rebuildStatusMenu()
    }

    private func updateStatusButtonIcon() {
        guard let btn = statusItem?.button else { return }
        let symbolName: String
        switch AppState.shared.sessionPhase {
        case .idle:
            symbolName = "waveform"
        case .recording:
            symbolName = "waveform.circle.fill"
        case .transcribing:
            symbolName = "ellipsis.circle"
        }

        let cfg = NSImage.SymbolConfiguration(pointSize: 14.5, weight: .semibold)
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Шепіт")?.withSymbolConfiguration(cfg) {
            img.isTemplate = true
            btn.image = img
        }
    }

    private func rebuildStatusMenu() {
        let app = AppState.shared
        let menu = NSMenu()

        let recTitle: String
        switch app.sessionPhase {
        case .idle: recTitle = "Почати запис"
        case .recording: recTitle = "Зупинити запис"
        case .transcribing: recTitle = "Розпізнавання…"
        }
        let toggleItem = NSMenuItem(title: recTitle, action: #selector(menuToggleRecording), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let fileItem = NSMenuItem(title: "Розпізнати файл…", action: #selector(menuTranscribeFile), keyEquivalent: "")
        fileItem.target = self
        menu.addItem(fileItem)

        let histItem = NSMenuItem(title: "Історія…", action: #selector(menuOpenHistory), keyEquivalent: "")
        histItem.target = self
        menu.addItem(histItem)

        let setItem = NSMenuItem(title: "Налаштування…", action: #selector(menuOpenSettings), keyEquivalent: ",")
        setItem.target = self
        menu.addItem(setItem)

        menu.addItem(.separator())

        // Modes Submenu
        let modeSub = NSMenu()
        for m in app.settings.modes {
            let mi = NSMenuItem(title: m.name, action: #selector(menuSelectMode(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = m.id
            mi.state = (m.id == app.settings.activeModeID) ? .on : .off
            modeSub.addItem(mi)
        }
        let modeParent = NSMenuItem(title: "Режим: \(app.settings.activeMode.name)", action: nil, keyEquivalent: "")
        modeParent.submenu = modeSub
        menu.addItem(modeParent)

        // Microphones Submenu (just like screenshot #1: HyperX Quadcast (Default) >)
        let micSub = NSMenu()
        let sysDef = NSMenuItem(title: "Системний типовий", action: #selector(menuSelectMic(_:)), keyEquivalent: "")
        sysDef.target = self
        sysDef.representedObject = ""
        sysDef.state = app.settings.selectedMicUID.isEmpty ? .on : .off
        micSub.addItem(sysDef)
        micSub.addItem(.separator())

        for dev in app.inputDevices {
            let title = dev.isDefault ? "\(dev.name) (Типовий)" : dev.name
            let di = NSMenuItem(title: title, action: #selector(menuSelectMic(_:)), keyEquivalent: "")
            di.target = self
            di.representedObject = dev.uid
            di.state = (app.settings.selectedMicUID == dev.uid) ? .on : .off
            micSub.addItem(di)
        }
        let micParent = NSMenuItem(title: app.currentMicrophoneDisplayName, action: nil, keyEquivalent: "")
        micParent.submenu = micSub
        menu.addItem(micParent)

        menu.addItem(.separator())

        let dashItem = NSMenuItem(title: "Відкрити «Шепіт»", action: #selector(menuOpenHome), keyEquivalent: "")
        dashItem.target = self
        menu.addItem(dashItem)

        let restartEngineItem = NSMenuItem(title: "Перезапустити MLX-воркер", action: #selector(menuRestartWorker), keyEquivalent: "")
        restartEngineItem.target = self
        menu.addItem(restartEngineItem)

        menu.addItem(.separator())

        let verItem = NSMenuItem(title: "Шепіт 1.0 · Apple Silicon", action: nil, keyEquivalent: "")
        verItem.isEnabled = false
        menu.addItem(verItem)

        let quitItem = NSMenuItem(title: "Вийти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    // MARK: - Standard macOS App Menu (Enables Cmd+C/V/X/A in TextFields + Cmd+, / Cmd+W / Cmd+Q)

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let toggleRec = NSMenuItem(title: "Почати / Зупинити запис", action: #selector(menuToggleRecording), keyEquivalent: "")
        toggleRec.target = self
        appMenu.addItem(toggleRec)

        let transFile = NSMenuItem(title: "Розпізнати файл…", action: #selector(menuTranscribeFile), keyEquivalent: "o")
        transFile.target = self
        appMenu.addItem(transFile)

        let hist = NSMenuItem(title: "Історія…", action: #selector(menuOpenHistory), keyEquivalent: "y")
        hist.target = self
        appMenu.addItem(hist)

        let prefs = NSMenuItem(title: "Налаштування…", action: #selector(menuOpenSettings), keyEquivalent: ",")
        prefs.target = self
        appMenu.addItem(prefs)

        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Сховати Шепіт", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Сховати інші", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "Показати всі", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Вийти з Шепіт", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu (essential for Cmd+C / Cmd+V / Cmd+A inside SwiftUI TextFields!)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Редагування")
        editMenu.addItem(withTitle: "Скасувати", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Повторити", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Вирізати", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Скопіювати", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Вставити", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Вибрати все", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Window menu
        let winMenuItem = NSMenuItem()
        let winMenu = NSMenu(title: "Вікно")
        let openDash = NSMenuItem(title: "Головне вікно", action: #selector(menuOpenHome), keyEquivalent: "1")
        openDash.target = self
        winMenu.addItem(openDash)
        winMenu.addItem(withTitle: "Згорнути", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "Закрити вікно", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winMenuItem.submenu = winMenu
        mainMenu.addItem(winMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu Actions

    @objc private func menuToggleRecording() {
        AppState.shared.toggleRecordingFromMenuOrButton()
    }

    @objc private func menuTranscribeFile() {
        AppState.shared.promptAndTranscribeFile()
    }

    @objc private func menuOpenHistory() {
        AppState.shared.selectedSection = .history
        showMainWindow()
    }

    @objc private func menuOpenSettings() {
        AppState.shared.selectedSection = .configuration
        showMainWindow()
    }

    @objc private func menuOpenHome() {
        AppState.shared.selectedSection = .home
        showMainWindow()
    }

    @objc private func menuRestartWorker() {
        AppState.shared.engine.restartWorker()
    }

    @objc private func menuSelectMode(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            AppState.shared.settings.activeModeID = id
            rebuildStatusMenu()
        }
    }

    @objc private func menuSelectMic(_ sender: NSMenuItem) {
        if let uid = sender.representedObject as? String {
            AppState.shared.settings.selectedMicUID = uid
            rebuildStatusMenu()
        }
    }
}

// MARK: - Entry Point

@main
@MainActor
struct ShepitMain {
    private static var retainedDelegate: AppDelegate?

    static func main() {
        let args = CommandLine.arguments
        if args.count >= 3 && args[1] == "--icon" {
            let ok = AppIconGenerator.writePNG(to: args[2])
            exit(ok ? 0 : 1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        retainedDelegate = delegate
        app.delegate = delegate
        app.run()
    }
}
