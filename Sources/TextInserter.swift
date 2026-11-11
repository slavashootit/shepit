import Foundation
import AppKit
import ApplicationServices

enum TextInserter {
    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    static func promptAccessibilityPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Reliably pastes `text` into the active text input (or re-activates `targetApp` if Shepit window took focus).
    static func insertText(
        _ text: String,
        autoPaste: Bool,
        restorePreviousClipboard: Bool,
        targetApp: NSRunningApplication?,
        completion: @escaping (Bool) -> Void
    ) {
        guard !text.isEmpty else {
            completion(false)
            return
        }

        let pb = NSPasteboard.general
        var savedItems: [[NSPasteboard.PasteboardType: Data]] = []

        if restorePreviousClipboard, let items = pb.pasteboardItems {
            for item in items {
                var dict: [NSPasteboard.PasteboardType: Data] = [:]
                for t in item.types {
                    if let d = item.data(forType: t) { dict[t] = d }
                }
                if !dict.isEmpty { savedItems.append(dict) }
            }
        }

        pb.clearContents()
        pb.setString(text, forType: .string)
        let expectedChangeCount = pb.changeCount

        guard autoPaste else {
            completion(true)
            return
        }

        guard AXIsProcessTrusted() else {
            // Text is safely in clipboard even if Accessibility is not enabled yet
            completion(false)
            return
        }

        let performKeystroke = {
            guard let src = CGEventSource(stateID: .combinedSessionState) else {
                completion(false)
                return
            }
            // kVK_ANSI_V = 9; explicitly force ONLY .maskCommand so lingering Option modifier never turns it into Cmd+Opt+V!
            guard let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false) else {
                completion(false)
                return
            }
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            keyDown.post(tap: .cgAnnotatedSessionEventTap)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
                keyUp.post(tap: .cgAnnotatedSessionEventTap)
                completion(true)

                if restorePreviousClipboard && !savedItems.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                        guard pb.changeCount == expectedChangeCount else { return }
                        pb.clearContents()
                        var restored: [NSPasteboardItem] = []
                        for dict in savedItems {
                            let pItem = NSPasteboardItem()
                            for (t, d) in dict { pItem.setData(d, forType: t) }
                            restored.append(pItem)
                        }
                        pb.writeObjects(restored)
                    }
                }
            }
        }

        let frontApp = NSWorkspace.shared.frontmostApplication
        let ownBundle = Bundle.main.bundleIdentifier
        if let targetApp,
           targetApp.bundleIdentifier != ownBundle,
           frontApp?.bundleIdentifier == ownBundle {
            targetApp.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: performKeystroke)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: performKeystroke)
        }
    }
}
