import Foundation
import AppKit
import Carbon

final class HotkeyManager {
    var settings: ShepitSettings

    // State synced from AppState
    var isRecordingActive: Bool = false
    var isHandsFreeLocked: Bool = false

    // Shortcut recorder hook for Settings UI
    var shortcutCaptureHandler: ((ShortcutBinding) -> Void)?

    // Callbacks
    var onStartPTTRequested: (() -> Void)?
    var onLockHandsFreeRequested: (() -> Void)?
    var onStopRequested: (() -> Void)?
    var onCancelRequested: (() -> Void)?
    var onSilentAbortRequested: (() -> Void)?
    var onCycleModeRequested: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var healthTimer: Timer?

    // PTT tracking
    private var isPTTModifierPhysicallyDown = false
    private var pttDownTime: Date = .distantPast
    private var ignoreNextModifierUp = false
    private var comboKeyPressedDuringPTT = false
    private var lastProcessedTimestamp: TimeInterval = 0

    init(settings: ShepitSettings) {
        self.settings = settings
    }

    func start() {
        installEventTapIfPossible()
        installFallbackMonitors()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        // Periodic self-healing check (picks up Accessibility permission as soon as granted, without app restart!)
        healthTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let tap = self.eventTap {
                if !CGEvent.tapIsEnabled(tap: tap) {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            } else if AXIsProcessTrusted() {
                self.installEventTapIfPossible()
            }
        }
    }

    func stop() {
        healthTimer?.invalidate()
        healthTimer = nil
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        if let gm = globalMonitor {
            NSEvent.removeMonitor(gm)
            globalMonitor = nil
        }
        if let lm = localMonitor {
            NSEvent.removeMonitor(lm)
            localMonitor = nil
        }
    }

    @objc private func handleSystemWake() {
        isPTTModifierPhysicallyDown = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            if let tap = self.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            } else {
                self.installEventTapIfPossible()
            }
        }
    }

    // MARK: - CGEventTap (Primary, Zero-Latency, Swallows Esc During Recording)

    private func installEventTapIfPossible() {
        guard eventTap == nil, AXIsProcessTrusted() else { return }

        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = manager.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            let swallow = manager.processCGEvent(type: type, event: event)
            return swallow ? nil : Unmanaged.passUnretained(event)
        }

        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: refcon
        ) {
            eventTap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    // MARK: - Fallback NSEvent Monitors (Works for Option PTT even BEFORE Accessibility is granted!)

    private func installFallbackMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] nsEvent in
            guard let self, self.eventTap == nil else { return }
            self.processNSEventFallback(nsEvent)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] nsEvent in
            guard let self else { return nsEvent }
            if let capture = self.shortcutCaptureHandler {
                if let binding = Self.captureBinding(from: nsEvent) {
                    DispatchQueue.main.async { capture(binding) }
                    return nil
                }
            }
            if self.eventTap == nil {
                let swallowed = self.processNSEventFallback(nsEvent)
                if swallowed { return nil }
            }
            return nsEvent
        }
    }

    private static func captureBinding(from event: NSEvent) -> ShortcutBinding? {
        let code = event.keyCode
        if event.type == .flagsChanged {
            let modCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62, 63]
            guard modCodes.contains(code) else { return nil }
            let cgFlags = Self.relevantCGFlags(from: event.modifierFlags.cgEventFlags)
            guard cgFlags != 0 else { return nil }
            return ShortcutBinding(keyCode: code, modifiers: cgFlags, isModifierOnly: true, enabled: true)
        } else if event.type == .keyDown {
            if code == 53 { return nil } // Esc cancels capture
            let cgFlags = Self.relevantCGFlags(from: event.modifierFlags.cgEventFlags)
            return ShortcutBinding(keyCode: code, modifiers: cgFlags, isModifierOnly: false, enabled: true)
        }
        return nil
    }

    // MARK: - Core Event Processing

    private func processCGEvent(type: CGEventType, event: CGEvent) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        lastProcessedTimestamp = now

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let rawFlags = Self.relevantCGFlags(from: event.flags)

        if let capture = shortcutCaptureHandler {
            if type == .flagsChanged {
                let modCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62, 63]
                if modCodes.contains(keyCode) && rawFlags != 0 {
                    let b = ShortcutBinding(keyCode: keyCode, modifiers: rawFlags, isModifierOnly: true, enabled: true)
                    DispatchQueue.main.async { capture(b) }
                    return true
                }
            } else if type == .keyDown {
                if keyCode == 53 {
                    return false
                }
                let b = ShortcutBinding(keyCode: keyCode, modifiers: rawFlags, isModifierOnly: false, enabled: true)
                DispatchQueue.main.async { capture(b) }
                return true
            }
        }

        if type == .flagsChanged {
            handleModifierChange(keyCode: keyCode, activeFlags: event.flags)
            return false
        } else if type == .keyDown {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            return handleKeyDown(keyCode: keyCode, activeFlags: event.flags, isRepeat: isRepeat)
        }
        return false
    }

    @discardableResult
    private func processNSEventFallback(_ event: NSEvent) -> Bool {
        if event.type == .flagsChanged {
            handleModifierChange(keyCode: event.keyCode, activeFlags: event.modifierFlags.cgEventFlags)
            return false
        } else if event.type == .keyDown {
            return handleKeyDown(keyCode: event.keyCode, activeFlags: event.modifierFlags.cgEventFlags, isRepeat: event.isARepeat)
        }
        return false
    }

    private func handleModifierChange(keyCode: UInt16, activeFlags: CGEventFlags) {
        let ptt = settings.pushToTalkShortcut
        guard ptt.enabled, ptt.isModifierOnly else { return }

        let matchesKey: Bool
        if settings.allowAnyOptionForPTT && (ptt.keyCode == 61 || ptt.keyCode == 58) {
            matchesKey = (keyCode == 61 || keyCode == 58)
        } else {
            matchesKey = (keyCode == ptt.keyCode)
        }
        guard matchesKey else { return }

        let expectedFlag = Self.modifierFlag(forKeyCode: keyCode)
        let isNowDown = activeFlags.contains(expectedFlag)

        // Ensure no other modifiers (Cmd/Ctrl/Shift) are held when starting PTT
        let otherMask: CGEventFlags = [.maskCommand, .maskControl, .maskShift]
        let hasOtherModifiers = !activeFlags.intersection(otherMask).isEmpty && expectedFlag == .maskAlternate

        if isNowDown && !isPTTModifierPhysicallyDown {
            isPTTModifierPhysicallyDown = true
            guard !hasOtherModifiers else {
                ignoreNextModifierUp = true
                return
            }

            if isRecordingActive {
                // Pressing Right Option while hands-free recording is active -> STOP & TRANSCRIBE!
                ignoreNextModifierUp = true
                DispatchQueue.main.async { [weak self] in
                    self?.onStopRequested?()
                }
            } else {
                pttDownTime = Date()
                comboKeyPressedDuringPTT = false
                ignoreNextModifierUp = false
                DispatchQueue.main.async { [weak self] in
                    self?.onStartPTTRequested?()
                }
            }
        } else if !isNowDown && isPTTModifierPhysicallyDown {
            isPTTModifierPhysicallyDown = false
            if ignoreNextModifierUp || comboKeyPressedDuringPTT {
                ignoreNextModifierUp = false
                comboKeyPressedDuringPTT = false
                return
            }

            let heldDuration = Date().timeIntervalSince(pttDownTime)
            if settings.pushToTalkTapToggle && heldDuration < 0.28 {
                // Quick tap -> Lock into Hands-Free recording until tapped again!
                DispatchQueue.main.async { [weak self] in
                    self?.onLockHandsFreeRequested?()
                }
            } else {
                // Held Push-to-Talk -> Stop and transcribe immediately on release!
                DispatchQueue.main.async { [weak self] in
                    self?.onStopRequested?()
                }
            }
        }
    }

    private func handleKeyDown(keyCode: UInt16, activeFlags: CGEventFlags, isRepeat: Bool) -> Bool {
        if isRepeat { return false }
        let cleanFlags = Self.relevantCGFlags(from: activeFlags)

        // 1. Esc cancels active recording (and swallows Esc so active chat/dialog doesn't close!)
        if keyCode == 53 && isRecordingActive {
            isPTTModifierPhysicallyDown = false
            ignoreNextModifierUp = true
            DispatchQueue.main.async { [weak self] in
                self?.onCancelRequested?()
            }
            return true
        }

        // 2. Toggle Recording shortcut (e.g. Option + Space)
        let tog = settings.toggleShortcut
        if tog.enabled && !tog.isModifierOnly && keyCode == tog.keyCode && cleanFlags == tog.modifiers {
            comboKeyPressedDuringPTT = true
            ignoreNextModifierUp = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.isRecordingActive {
                    if !self.isHandsFreeLocked && Date().timeIntervalSince(self.pttDownTime) < 0.45 {
                        // User pressed Option (which started PTT) + Space -> switch seamlessly to Hands-Free!
                        self.onLockHandsFreeRequested?()
                    } else {
                        self.onStopRequested?()
                    }
                } else {
                    self.onStartPTTRequested?()
                    self.onLockHandsFreeRequested?()
                }
            }
            return true
        }

        // 3. Change Mode shortcut (e.g. Option + Shift + K)
        let modeSC = settings.changeModeShortcut
        if modeSC.enabled && !modeSC.isModifierOnly && keyCode == modeSC.keyCode && cleanFlags == modeSC.modifiers {
            comboKeyPressedDuringPTT = true
            ignoreNextModifierUp = true
            DispatchQueue.main.async { [weak self] in
                self?.onCycleModeRequested?()
            }
            return true
        }

        // 4. If user held Right Option just to type an Option+Letter shortcut within 450 ms, abort empty PTT silently!
        if isPTTModifierPhysicallyDown && !comboKeyPressedDuringPTT {
            comboKeyPressedDuringPTT = true
            if Date().timeIntervalSince(pttDownTime) < 0.45 {
                DispatchQueue.main.async { [weak self] in
                    self?.onSilentAbortRequested?()
                }
            }
        }

        return false
    }

    private static func modifierFlag(forKeyCode code: UInt16) -> CGEventFlags {
        switch code {
        case 58, 61: return .maskAlternate
        case 54, 55: return .maskCommand
        case 56, 60: return .maskShift
        case 59, 62: return .maskControl
        case 63: return .maskSecondaryFn
        default: return .maskAlternate
        }
    }

    static func relevantCGFlags(from flags: CGEventFlags) -> UInt64 {
        let mask: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskControl]
        return flags.intersection(mask).rawValue
    }
}

private extension NSEvent.ModifierFlags {
    var cgEventFlags: CGEventFlags {
        var f: CGEventFlags = []
        if contains(.command) { f.insert(.maskCommand) }
        if contains(.option) { f.insert(.maskAlternate) }
        if contains(.shift) { f.insert(.maskShift) }
        if contains(.control) { f.insert(.maskControl) }
        if contains(.function) { f.insert(.maskSecondaryFn) }
        return f
    }
}
