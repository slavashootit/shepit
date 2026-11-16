import Foundation
import AppKit
import SwiftUI

enum HUDTone: Equatable {
    case success
    case neutral
    case warning
    case error

    var color: Color {
        switch self {
        case .success: return Theme.accent
        case .neutral: return Color.white.opacity(0.78)
        case .warning: return Theme.warning
        case .error: return Theme.danger
        }
    }
}

enum HUDPhase: Equatable {
    case hidden
    case recording(handsFree: Bool)
    case transcribing(label: String)
    case done
    case cancelled
    case toast(icon: String, message: String, tone: HUDTone)
}

@MainActor
final class HUDViewModel: ObservableObject {
    @Published var phase: HUDPhase = .hidden
    @Published var style: RecordingWindowStyle = .classic
    @Published var modeName: String = "Голос у текст"
    @Published var elapsedSeconds: TimeInterval = 0
    @Published var levels: [CGFloat] = Array(repeating: 0.08, count: 28)
    @Published var livePreviewText: String = ""
    /// Drives the appear / disappear transition; the panel itself is ordered in and out around it.
    @Published var isShown: Bool = false
    @Published var isOffline: Bool = false
    @Published var reduceMotion: Bool = false
    /// Real notch geometry of the target screen (zero width when the screen has none)
    @Published var notchWidth: CGFloat = 0
    @Published var notchHeight: CGFloat = 32

    var onStopTap: (() -> Void)?
    var onCancelTap: (() -> Void)?
    var onToastTap: (() -> Void)?

    /// Loudness of the most recent slice of audio, 0…1
    var currentLevel: CGFloat {
        let tail = levels.suffix(4)
        guard !tail.isEmpty else { return 0 }
        return min(1, tail.reduce(0, +) / CGFloat(tail.count))
    }
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
    private var orderOutWorkItem: DispatchWorkItem?

    init() {}

    func showRecording(style: RecordingWindowStyle, modeName: String, handsFree: Bool, isOffline: Bool = false) {
        hideToastWorkItem?.cancel()
        model.onToastTap = nil
        model.style = style
        model.modeName = modeName
        model.isOffline = isOffline
        model.livePreviewText = ""
        setPhase(.recording(handsFree: handsFree))
        if style == .none {
            hidePanelImmediately()
            return
        }
        present()
    }

    func updateHandsFree(_ handsFree: Bool) {
        if case .recording = model.phase {
            setPhase(.recording(handsFree: handsFree))
        }
    }

    func updateWaveform(levels: [CGFloat], elapsed: TimeInterval) {
        model.levels = levels
        model.elapsedSeconds = elapsed
    }

    func updateLivePreview(_ text: String) {
        withAnimation(Theme.spring) {
            model.livePreviewText = text
        }
    }

    func showTranscribing(style: RecordingWindowStyle, label: String = "Розпізнавання…") {
        hideToastWorkItem?.cancel()
        model.onToastTap = nil
        model.style = style
        model.livePreviewText = ""
        setPhase(.transcribing(label: label))
        if style == .none {
            hidePanelImmediately()
            return
        }
        present()
    }

    /// Brief confirmation that the text landed, then the pill leaves on its own.
    func showDone(style: RecordingWindowStyle) {
        showTransient(.done, style: style, duration: 0.7)
    }

    /// Makes a cancelled recording visible instead of the pill just vanishing.
    func showCancelled(style: RecordingWindowStyle) {
        showTransient(.cancelled, style: style, duration: 0.6)
    }

    private func showTransient(_ phase: HUDPhase, style: RecordingWindowStyle, duration: TimeInterval) {
        hideToastWorkItem?.cancel()
        model.onToastTap = nil
        guard style != .none else {
            hide()
            return
        }
        model.style = style
        model.livePreviewText = ""
        setPhase(phase)
        present()
        scheduleHide(after: duration) { $0 == phase }
    }

    func showToast(
        style: RecordingWindowStyle,
        icon: String,
        message: String,
        isWarning: Bool = false,
        duration: TimeInterval = 1.6,
        tone: HUDTone? = nil,
        onTap: (() -> Void)? = nil
    ) {
        hideToastWorkItem?.cancel()
        let resolvedTone = tone ?? (isWarning ? .warning : .success)
        let important = resolvedTone == .warning || resolvedTone == .error
        if style == .none && !important {
            hidePanelImmediately()
            return
        }
        model.style = style == .none ? .mini : style
        model.livePreviewText = ""
        model.onToastTap = onTap
        setPhase(.toast(icon: icon, message: message, tone: resolvedTone))
        present()
        scheduleHide(after: duration) { phase in
            if case .toast = phase { return true }
            return false
        }
    }

    func hide() {
        hideToastWorkItem?.cancel()
        model.onToastTap = nil
        withAnimation(Theme.spring) {
            model.isShown = false
        }
        // Let the exit transition play before the window leaves the screen
        orderOutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, !self.model.isShown else { return }
                self.model.phase = .hidden
                self.model.livePreviewText = ""
                self.model.elapsedSeconds = 0
                self.panel?.orderOut(nil)
            }
        }
        orderOutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: item)
    }

    private func scheduleHide(after duration: TimeInterval, ifStill matches: @escaping (HUDPhase) -> Bool) {
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, matches(self.model.phase) else { return }
                self.hide()
            }
        }
        hideToastWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }

    private func setPhase(_ phase: HUDPhase) {
        if model.isShown {
            withAnimation(Theme.spring) { model.phase = phase }
        } else {
            model.phase = phase
        }
    }

    private func present() {
        orderOutWorkItem?.cancel()
        model.reduceMotion = Theme.reduceMotion
        ensurePanel()
        repositionPanel()
        panel?.orderFrontRegardless()
        guard !model.isShown else { return }
        // Next runloop turn, so SwiftUI sees the hidden state first and animates from it
        DispatchQueue.main.async { [weak self] in
            withAnimation(Theme.spring) {
                self?.model.isShown = true
            }
        }
    }

    private func hidePanelImmediately() {
        orderOutWorkItem?.cancel()
        model.isShown = false
        panel?.orderOut(nil)
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let p = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 170),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = false

        let rootView = FloatingHUDView(vm: model)
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = p.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        p.contentView = hosting
        panel = p
    }

    /// The screen the user is looking at: the one under the pointer, not the one with the key window.
    private func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func repositionPanel() {
        guard let panel, let screen = targetScreen() else { return }
        let visible = screen.visibleFrame
        let full = screen.frame

        if model.style == .notch {
            // Real notch geometry: the gap between the two usable strips beside the camera housing
            var notchWidth: CGFloat = 0
            var notchHeight: CGFloat = max(24, full.maxY - visible.maxY)
            if screen.safeAreaInsets.top > 0,
               let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                notchWidth = max(0, full.width - left.width - right.width)
                notchHeight = screen.safeAreaInsets.top
            }
            model.notchWidth = notchWidth
            model.notchHeight = notchHeight
            let width: CGFloat = max(520, notchWidth + 320)
            let height: CGFloat = notchHeight + 64
            panel.setFrame(NSRect(x: full.midX - width / 2.0, y: full.maxY - height, width: width, height: height), display: true)
        } else {
            let width: CGFloat = 560
            let height: CGFloat = 170
            panel.setFrame(NSRect(x: visible.midX - width / 2.0, y: visible.minY + 8, width: width, height: height), display: true)
        }
    }
}

// MARK: - Root view

struct FloatingHUDView: View {
    @ObservedObject var vm: HUDViewModel

    var body: some View {
        Group {
            if vm.style == .notch {
                NotchHUDView(vm: vm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                bottomStack
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var accent: Color {
        if case .recording(let handsFree) = vm.phase, handsFree { return Theme.handsFree }
        return Theme.accent
    }

    private var bottomStack: some View {
        VStack(spacing: 8) {
            if vm.style == .classic, !vm.livePreviewText.isEmpty, case .recording = vm.phase {
                Text(vm.livePreviewText)
                    .font(Theme.font(12.5))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        HUDSurface()
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusL, style: .continuous))
                    )
                    .frame(maxWidth: 440)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }

            pill
        }
        .padding(.bottom, 22)
        .scaleEffect(vm.isShown ? 1 : (vm.reduceMotion ? 1 : 0.86), anchor: .bottom)
        .offset(y: vm.isShown || vm.reduceMotion ? 0 : 14)
        .opacity(vm.isShown ? 1 : 0)
    }

    /// One capsule that changes size and content between states instead of being swapped out.
    private var pill: some View {
        let level: CGFloat = isRecording ? vm.currentLevel : 0
        return pillContent
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(minHeight: 44)
            .background(pillBackground(level: level))
            .contentShape(Capsule())
            .onTapGesture { handleTap() }
            .animation(.easeOut(duration: 0.12), value: level)
    }

    private func pillBackground(level: CGFloat) -> some View {
        // Edge light that breathes with the voice; grey when there is no network
        let glowOpacity: Double = vm.reduceMotion ? 0.18 : 0.14 + 0.5 * Double(level)
        let glowRadius: CGFloat = vm.reduceMotion ? 8 : 6 + 16 * level
        let surface = HUDSurface()
            .clipShape(Capsule(style: .continuous))
        let rim = Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
        return surface
            .overlay(rim)
            .shadow(color: glowColor.opacity(glowOpacity), radius: glowRadius)
            .shadow(color: Color.black.opacity(0.35), radius: 12, x: 0, y: 6)
    }

    private var isRecording: Bool {
        if case .recording = vm.phase { return true }
        return false
    }

    private var glowColor: Color {
        switch vm.phase {
        case .recording: return vm.isOffline ? Theme.offline : accent
        case .cancelled: return Theme.danger
        case .toast(_, _, let tone): return tone == .neutral ? .clear : tone.color
        default: return Theme.accent
        }
    }

    private func handleTap() {
        switch vm.phase {
        case .recording:
            if vm.style == .mini { vm.onStopTap?() }
        case .toast:
            vm.onToastTap?()
        default:
            break
        }
    }

    @ViewBuilder
    private var pillContent: some View {
        switch vm.phase {
        case .hidden:
            Color.clear.frame(width: 44, height: 26)

        case .recording(let handsFree):
            if vm.style == .mini {
                miniRecording(handsFree: handsFree)
                    .transition(.opacity)
            } else {
                classicRecording(handsFree: handsFree)
                    .transition(.opacity)
            }

        case .transcribing(let label):
            HStack(spacing: 10) {
                ThinkingDots(tint: Theme.accent, animated: !vm.reduceMotion)
                Text(label)
                    .font(Theme.font(Theme.body, strong: true))
                    .foregroundColor(.white.opacity(0.92))
            }
            .padding(.horizontal, 4)
            .transition(.opacity)

        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Theme.accent)
                .frame(width: 26, height: 26)
                .transition(.scale(scale: 0.4).combined(with: .opacity))

        case .cancelled:
            HStack(spacing: 7) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                Text("Скасовано")
                    .font(Theme.font(12.5, strong: true))
            }
            .foregroundColor(Theme.danger)
            .padding(.horizontal, 2)
            .transition(.opacity)

        case .toast(let icon, let message, let tone):
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(tone.color)
                Text(message)
                    .font(Theme.font(12.5, strong: true))
                    .foregroundColor(.white.opacity(0.94))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if vm.onToastTap != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            // Short notes hug their text; long errors wrap to two lines at a fixed width
            .frame(width: message.count > 48 ? 400 : nil)
            .fixedSize(horizontal: message.count <= 48, vertical: false)
            .padding(.horizontal, 2)
            .transition(.opacity)
        }
    }

    private func classicRecording(handsFree: Bool) -> some View {
        let tint = handsFree ? Theme.handsFree : Theme.accent
        return HStack(spacing: 12) {
            Button(action: { vm.onStopTap?() }) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.20))
                        .frame(width: 28, height: 28)
                    Image(systemName: handsFree ? "lock.fill" : "mic.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(tint)
                }
            }
            .buttonStyle(.plain)
            .help(handsFree ? "Запис без рук (натисніть, щоб завершити)" : "Йде запис")
            .accessibilityLabel("Завершити запис")

            WaveformBarsView(levels: vm.levels, tint: tint, barCount: 24, height: 22)
                .frame(width: 138, height: 24)

            Text(formatElapsed(vm.elapsedSeconds))
                .font(Theme.digits(12.5))
                .foregroundColor(.white.opacity(0.88))
                .frame(minWidth: 34, alignment: .leading)

            if vm.isOffline {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.offline)
                    .help("Немає мережі — працює локальна модель")
            }

            Button(action: { vm.onCancelTap?() }) {
                Text("esc")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.65))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.10))
                    )
            }
            .buttonStyle(.plain)
            .help("Скасувати запис (Esc)")
            .accessibilityLabel("Скасувати запис")
        }
    }

    private func miniRecording(handsFree: Bool) -> some View {
        let tint = handsFree ? Theme.handsFree : Theme.accent
        return HStack(spacing: 9) {
            Circle()
                .fill(vm.isOffline ? Theme.offline : tint)
                .frame(width: 7, height: 7)
            WaveformBarsView(levels: Array(vm.levels.suffix(14)), tint: tint, barCount: 14, height: 16)
                .frame(width: 82, height: 18)
            Text(formatElapsed(vm.elapsedSeconds))
                .font(Theme.digits(11.5))
                .foregroundColor(.white.opacity(0.82))
        }
    }
}

func formatElapsed(_ sec: TimeInterval) -> String {
    let s = max(0, Int(sec))
    return String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Notch HUD: grows out of the camera housing and retreats into it

struct NotchHUDView: View {
    @ObservedObject var vm: HUDViewModel

    private var hasNotch: Bool { vm.notchWidth > 0 }
    private let wing: CGFloat = 96

    private var showsLowerRow: Bool {
        switch vm.phase {
        case .transcribing, .toast, .cancelled, .done: return true
        default: return false
        }
    }

    var body: some View {
        let core = hasNotch ? vm.notchWidth : 120
        let fullWidth = core + wing * 2
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 0, bottomLeadingRadius: 16, bottomTrailingRadius: 16, topTrailingRadius: 0,
            style: .continuous
        )
        let tint = accent
        return VStack(spacing: 0) {
            // Row beside the notch: wave on the left wing, time and cancel on the right
            HStack(spacing: 0) {
                leftWing(tint: tint)
                    .frame(width: wing, height: vm.notchHeight)
                Color.clear.frame(width: core, height: vm.notchHeight)
                rightWing
                    .frame(width: wing, height: vm.notchHeight)
            }
            if showsLowerRow {
                lowerRow
                    .frame(minHeight: 30)
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }
        }
        .frame(width: fullWidth)
        .background(
            shape.fill(Color.black)
                .shadow(color: glowColor.opacity(0.10 + 0.4 * Double(isRecording ? vm.currentLevel : 0)), radius: 12, y: 3)
        )
        .clipShape(shape)
        // Collapsed state has exactly the notch's own width, so the HUD reads as the notch widening
        .scaleEffect(
            x: vm.isShown ? 1 : (vm.reduceMotion ? 1 : max(0.3, core / fullWidth)),
            y: vm.isShown || vm.reduceMotion ? 1 : 0.6,
            anchor: .top
        )
        .opacity(vm.isShown ? 1 : (hasNotch && !vm.reduceMotion ? 0.0 : 0))
        .contentShape(Rectangle())
        .onTapGesture { if case .toast = vm.phase { vm.onToastTap?() } }
    }

    private var isRecording: Bool {
        if case .recording = vm.phase { return true }
        return false
    }

    private var accent: Color {
        if case .recording(let handsFree) = vm.phase, handsFree { return Theme.handsFree }
        return Theme.accent
    }

    private var glowColor: Color {
        switch vm.phase {
        case .cancelled: return Theme.danger
        case .toast(_, _, let tone): return tone.color
        default: return vm.isOffline ? Theme.offline : accent
        }
    }

    @ViewBuilder
    private func leftWing(tint: Color) -> some View {
        if isRecording {
            HStack(spacing: 7) {
                Circle()
                    .fill(vm.isOffline ? Theme.offline : tint)
                    .frame(width: 7, height: 7)
                WaveformBarsView(levels: Array(vm.levels.suffix(10)), tint: tint, barCount: 10, height: 16)
                    .frame(width: 56, height: 18)
            }
            .transition(.opacity)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var rightWing: some View {
        if isRecording {
            HStack(spacing: 8) {
                Text(formatElapsed(vm.elapsedSeconds))
                    .font(Theme.digits(12))
                    .foregroundColor(.white.opacity(0.92))
                Button(action: { vm.onCancelTap?() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("Скасувати запис (Esc)")
                .accessibilityLabel("Скасувати запис")
            }
            .transition(.opacity)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var lowerRow: some View {
        switch vm.phase {
        case .transcribing(let label):
            HStack(spacing: 9) {
                ThinkingDots(tint: Theme.accent, animated: !vm.reduceMotion)
                Text(label)
                    .font(Theme.font(12, strong: true))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
            }
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Theme.accent)
        case .cancelled:
            Label("Скасовано", systemImage: "xmark")
                .font(Theme.font(12, strong: true))
                .foregroundColor(Theme.danger)
        case .toast(let icon, let message, let tone):
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(tone.color)
                Text(message)
                    .font(Theme.font(11.5, strong: true))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
        default:
            EmptyView()
        }
    }
}

// MARK: - Pieces

/// Three dots that rise in turn while the text is being recognised.
struct ThinkingDots: View {
    let tint: Color
    var animated: Bool = true

    var body: some View {
        if animated {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                dots(time: timeline.date.timeIntervalSinceReferenceDate)
            }
        } else {
            dots(time: nil)
        }
    }

    private func dots(time: TimeInterval?) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { idx in
                let lift: CGFloat = {
                    guard let time else { return 0 }
                    let phase = time * 5.2 - Double(idx) * 0.7
                    return CGFloat(max(0, sin(phase))) * 4
                }()
                Circle()
                    .fill(tint.opacity(time == nil ? 0.9 : 0.55 + 0.45 * Double(lift / 4)))
                    .frame(width: 5, height: 5)
                    .offset(y: -lift)
            }
        }
        .frame(height: 14)
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
                    .fill(tint.opacity(0.55 + 0.45 * Double(min(1, val * 1.4))))
                    .frame(width: 2.8, height: max(3.5, val * height))
                    .animation(.easeOut(duration: 0.09), value: val)
            }
        }
        .accessibilityHidden(true)
    }

    private func sampleLevel(at idx: Int) -> CGFloat {
        guard !levels.isEmpty else { return 0.1 }
        let mapped = min(levels.count - 1, max(0, idx * levels.count / max(1, barCount)))
        return levels[mapped]
    }
}
