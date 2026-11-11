import Foundation
import AppKit
import SwiftUI

enum HUDPhase: Equatable {
    case hidden
    case recording(handsFree: Bool)
    case transcribing(label: String)
    case toast(icon: String, message: String, isWarning: Bool)
}

@MainActor
final class HUDViewModel: ObservableObject {
    @Published var phase: HUDPhase = .hidden
    @Published var style: RecordingWindowStyle = .classic
    @Published var modeName: String = "Голос у текст"
    @Published var elapsedSeconds: TimeInterval = 0
    @Published var levels: [CGFloat] = Array(repeating: 0.08, count: 28)
    @Published var livePreviewText: String = ""

    var onStopTap: (() -> Void)?
    var onCancelTap: (() -> Void)?
}

final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatingHUDController {
    let model = HUDViewModel()
    private var panel: NonActivatingPanel?
    private var hideToastWorkItem: DispatchWorkItem?

    init() {}

    func showRecording(style: RecordingWindowStyle, modeName: String, handsFree: Bool) {
        hideToastWorkItem?.cancel()
        model.style = style
        model.modeName = modeName
        model.phase = .recording(handsFree: handsFree)
        if style == .none {
            hidePanelImmediately()
            return
        }
        ensurePanel()
        repositionPanel()
        panel?.orderFrontRegardless()
    }

    func updateHandsFree(_ handsFree: Bool) {
        if case .recording = model.phase {
            model.phase = .recording(handsFree: handsFree)
        }
    }

    func updateWaveform(levels: [CGFloat], elapsed: TimeInterval) {
        model.levels = levels
        model.elapsedSeconds = elapsed
    }

    func updateLivePreview(_ text: String) {
        let changed = (model.livePreviewText.isEmpty != text.isEmpty)
        model.livePreviewText = text
        if changed {
            repositionPanel()
        }
    }

    func showTranscribing(style: RecordingWindowStyle, label: String = "Розпізнавання…") {
        hideToastWorkItem?.cancel()
        model.style = style
        model.phase = .transcribing(label: label)
        if style == .none {
            hidePanelImmediately()
            return
        }
        ensurePanel()
        repositionPanel()
        panel?.orderFrontRegardless()
    }

    func showToast(style: RecordingWindowStyle, icon: String, message: String, isWarning: Bool = false, duration: TimeInterval = 1.6) {
        hideToastWorkItem?.cancel()
        if style == .none && !isWarning {
            hidePanelImmediately()
            return
        }
        model.style = style == .none ? .mini : style
        model.livePreviewText = ""
        model.phase = .toast(icon: icon, message: message, isWarning: isWarning)
        ensurePanel()
        repositionPanel()
        panel?.orderFrontRegardless()

        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if case .toast = self.model.phase {
                    self.hide()
                }
            }
        }
        hideToastWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }

    func hide() {
        hideToastWorkItem?.cancel()
        model.phase = .hidden
        model.livePreviewText = ""
        model.elapsedSeconds = 0
        hidePanelImmediately()
    }

    private func hidePanelImmediately() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let p = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 96),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = false

        let rootView = FloatingHUDView(vm: model)
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = p.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        p.contentView = hosting
        panel = p
    }

    private func repositionPanel() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let width: CGFloat = 460
        let height: CGFloat = model.livePreviewText.isEmpty ? 76 : 124
        let x = visible.midX - width / 2.0
        let y = visible.minY + 26
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}

struct FloatingHUDView: View {
    @ObservedObject var vm: HUDViewModel

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)

            if vm.style == .classic, !vm.livePreviewText.isEmpty, case .recording = vm.phase {
                Text(vm.livePreviewText)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(red: 0.08, green: 0.09, blue: 0.12).opacity(0.92))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.11), lineWidth: 1)
                            )
                    )
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            switch vm.phase {
            case .hidden:
                EmptyView()

            case .recording(let handsFree):
                if vm.style == .mini {
                    miniRecordingPill(handsFree: handsFree)
                } else {
                    classicRecordingPill(handsFree: handsFree)
                }

            case .transcribing(let label):
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color(red: 0.34, green: 0.86, blue: 0.72))
                    Text(label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(capsuleBackground(borderTint: Color(red: 0.34, green: 0.86, blue: 0.72).opacity(0.35)))

            case .toast(let icon, let message, let isWarning):
                HStack(spacing: 9) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(isWarning ? Color.orange : Color(red: 0.34, green: 0.86, blue: 0.72))
                    Text(message)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.94))
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(capsuleBackground(borderTint: isWarning ? Color.orange.opacity(0.4) : Color.white.opacity(0.14)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: vm.phase)
    }

    private func classicRecordingPill(handsFree: Bool) -> some View {
        let accent = handsFree
            ? Color(red: 1.0, green: 0.68, blue: 0.24)
            : Color(red: 0.24, green: 0.88, blue: 0.68)

        return HStack(spacing: 12) {
            Button(action: { vm.onStopTap?() }) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.20))
                        .frame(width: 28, height: 28)
                    Image(systemName: handsFree ? "lock.fill" : "mic.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(accent)
                }
            }
            .buttonStyle(.plain)
            .help(handsFree ? "Запис без рук (натисніть, щоб завершити)" : "Йде запис")

            WaveformBarsView(levels: vm.levels, tint: accent, barCount: 24, height: 22)
                .frame(width: 138, height: 24)

            Text(formatElapsed(vm.elapsedSeconds))
                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.88))
                .frame(minWidth: 38, alignment: .leading)

            Divider()
                .frame(height: 14)
                .background(Color.white.opacity(0.16))

            Button(action: { vm.onCancelTap?() }) {
                Text("esc")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.65))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.09))
                    )
            }
            .buttonStyle(.plain)
            .help("Скасувати запис (Esc)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(capsuleBackground(borderTint: accent.opacity(0.38)))
    }

    private func miniRecordingPill(handsFree: Bool) -> some View {
        let accent = handsFree
            ? Color(red: 1.0, green: 0.68, blue: 0.24)
            : Color(red: 0.24, green: 0.88, blue: 0.68)

        return HStack(spacing: 9) {
            Circle()
                .fill(accent)
                .frame(width: 7, height: 7)
            WaveformBarsView(levels: Array(vm.levels.suffix(14)), tint: accent, barCount: 14, height: 16)
                .frame(width: 82, height: 18)
            Text(formatElapsed(vm.elapsedSeconds))
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.82))
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(capsuleBackground(borderTint: accent.opacity(0.35)))
        .onTapGesture { vm.onStopTap?() }
    }

    private func capsuleBackground(borderTint: Color) -> some View {
        Capsule(style: .continuous)
            .fill(Color(red: 0.07, green: 0.08, blue: 0.10).opacity(0.94))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(borderTint, lineWidth: 1.0)
            )
            .shadow(color: Color.black.opacity(0.42), radius: 14, x: 0, y: 6)
    }

    private func formatElapsed(_ sec: TimeInterval) -> String {
        let s = max(0, Int(sec))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct WaveformBarsView: View {
    let levels: [CGFloat]
    let tint: Color
    let barCount: Int
    let height: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<barCount, id: \.self) { idx in
                let val = sampleLevel(at: idx)
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint, tint.opacity(0.62)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 2.8, height: max(3.5, val * height))
                    .animation(.easeOut(duration: 0.08), value: val)
            }
        }
    }

    private func sampleLevel(at idx: Int) -> CGFloat {
        guard !levels.isEmpty else { return 0.1 }
        let mapped = min(levels.count - 1, max(0, idx * levels.count / max(1, barCount)))
        return levels[mapped]
    }
}
