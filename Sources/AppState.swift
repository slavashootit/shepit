import Foundation
import AppKit
import AVFoundation
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class AppState: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AppState()
    static var snapshotMode = false

    enum SessionPhase: Equatable {
        case idle
        case recording(handsFree: Bool)
        case transcribing
    }

    @Published var settings: ShepitSettings {
        didSet {
            StorageManager.shared.saveSettings(settings)
            hotkeyManager.settings = settings
            applyAppearance()
        }
    }

    @Published var selectedSection: AppSection = .home
    @Published var statRange: StatRange = .allTime {
        didSet { reloadStats() }
    }

    @Published var sessionPhase: SessionPhase = .idle
    @Published var inputDevices: [AudioInputDevice] = []
    @Published var historyItems: [RecordingItem] = []
    @Published var historySearch: String = "" {
        didSet { reloadHistory() }
    }
    @Published var stats: DashboardStats = .empty
    @Published var workerStatus = WorkerStatusInfo()
    @Published var isOnline: Bool = true

    @Published var hasMicPermission: Bool = false
    @Published var hasAccessibilityPermission: Bool = false
    @Published var launchOnLogin: Bool = false

    @Published var playingItemID: String? = nil
    @Published var capturingShortcutTarget: String? = nil
    @Published var statusBannerMessage: String? = nil

    // UI transient state (avoids SwiftUIMacros dependency on CommandLineTools-only setups)
    @Published var uiShowBaselinePopover: Bool = false
    @Published var uiHoveredDayKey: String? = nil
    @Published var uiHoveredSection: AppSection? = nil
    @Published var uiHoveredQuickAction: String? = nil
    @Published var uiHoveredHistoryID: String? = nil
    @Published var uiChartAppeared: Bool = false
    /// Deleted from the list but still restorable for a few seconds
    @Published var uiPendingDeleteItem: RecordingItem? = nil
    @Published var uiModePendingDeleteID: String? = nil
    @Published var vocabSuggestions: [VocabSuggestion] = []
    @Published var uiEditingModeID: String = ""
    @Published var uiNewVocabWord: String = ""
    @Published var uiNewReplFrom: String = ""
    @Published var uiNewReplTo: String = ""
    @Published var uiCopiedItemID: String? = nil
    @Published var uiIsDropTargeted: Bool = false
    @Published var uiGroqKeyInput: String = ""
    @Published var uiGeminiKeyInput: String = ""
    @Published var uiShowGroqKeyEditor: Bool = false
    @Published var uiShowGeminiKeyEditor: Bool = false
    @Published var isInstallingModel: Bool = false
    @Published var modelInstallStage: String = ""
    @Published var modelInstallProgress: Double = 0.0

    private var downloadProgressObs: NSKeyValueObservation?
    private var activeDownloadTask: URLSessionDownloadTask?

    let storage = StorageManager.shared
    let recorder = AudioRecorder()
    let engine = TranscriptionEngine()
    let hud = FloatingHUDController()
    lazy var hotkeyManager = HotkeyManager(settings: settings)

    private var activeRecordingURL: URL?
    private var targetAppAtStart: NSRunningApplication?
    private var activeSessionMode: ShepitMode?
    private var activeSessionContext: [String: Any]?
    private var previewTimer: Timer?
    private var previewInFlight = false
    private var audioPlayer: AVAudioPlayer?
    private var permissionPollTimer: Timer?

    var onMenuStateChanged: (() -> Void)?
    var onOpenMainWindowRequested: ((AppSection?) -> Void)?

    private override init() {
        let loaded = StorageManager.shared.loadSettings()
        self.settings = loaded
        super.init()

        if !settings.didImportSuperwhisper {
            let imported = storage.importLegacySuperwhisperIfPresent()
            if imported.importedStats > 0 || imported.importedHistory > 0 {
                settings.didImportSuperwhisper = true
            }
        }

        storage.pruneExpiredAudio(retention: settings.audioRetention)
        refreshDevices()
        refreshPermissions()
        refreshLaunchOnLoginState()
        reloadStats()
        reloadHistory()
        applyAppearance()
        wireCallbacks()

        // Snapshot tool renders screens off-screen: no hotkeys, no recognition worker, no network watcher
        guard !AppState.snapshotMode else { return }

        hotkeyManager.start()
        engine.startAndWarmup()

        NetworkMonitor.shared.onChange = { [weak self] online in
            Task { @MainActor in
                guard let self else { return }
                self.isOnline = online
                self.engine.isOnline = online
                self.onMenuStateChanged?()
                if online {
                    // Give the connection a moment to settle before catching up on offline records
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                        self?.redoOfflineItems()
                    }
                }
            }
        }
        NetworkMonitor.shared.start()
        refreshVocabSuggestions()

        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermissions()
            }
        }
    }

    private func wireCallbacks() {
        recorder.onDevicesChanged = { [weak self] in
            Task { @MainActor in self?.refreshDevices() }
        }

        recorder.onWaveformUpdate = { [weak self] levels, elapsed in
            Task { @MainActor in
                self?.hud.updateWaveform(levels: levels, elapsed: elapsed)
                self?.trackSilence(levels: levels)
            }
        }

        engine.onStatusUpdate = { [weak self] st in
            Task { @MainActor in
                self?.workerStatus = st
                self?.onMenuStateChanged?()
            }
        }

        hud.model.onStopTap = { [weak self] in
            Task { @MainActor in self?.stopAndTranscribe() }
        }
        hud.model.onCancelTap = { [weak self] in
            Task { @MainActor in self?.cancelRecording(silent: false) }
        }

        hotkeyManager.onStartPTTRequested = { [weak self] in
            Task { @MainActor in self?.startRecording(handsFree: false) }
        }
        hotkeyManager.onLockHandsFreeRequested = { [weak self] in
            Task { @MainActor in self?.lockHandsFree() }
        }
        hotkeyManager.onStopRequested = { [weak self] in
            Task { @MainActor in self?.stopAndTranscribe() }
        }
        hotkeyManager.onCancelRequested = { [weak self] in
            Task { @MainActor in self?.cancelRecording(silent: false) }
        }
        hotkeyManager.onSilentAbortRequested = { [weak self] in
            Task { @MainActor in self?.cancelRecording(silent: true) }
        }
        hotkeyManager.onCycleModeRequested = { [weak self] in
            Task { @MainActor in self?.cycleActiveMode() }
        }
    }

    // MARK: - Appearance & System Settings

    func applyAppearance() {
        switch settings.theme {
        case .auto:
            NSApp?.appearance = nil
        case .light:
            NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func refreshPermissions() {
        let micAuth = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let axAuth = TextInserter.isAccessibilityGranted
        if micAuth != hasMicPermission || axAuth != hasAccessibilityPermission {
            hasMicPermission = micAuth
            hasAccessibilityPermission = axAuth
        }
    }

    func requestMicPermission() {
        AudioRecorder.checkMicrophonePermission { [weak self] granted in
            self?.hasMicPermission = granted
            if !granted, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func requestAccessibility() {
        TextInserter.promptAccessibilityPermission()
    }

    func refreshLaunchOnLoginState() {
        if #available(macOS 13.0, *) {
            launchOnLogin = (SMAppService.mainApp.status == .enabled)
        }
    }

    func setLaunchOnLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {}
            refreshLaunchOnLoginState()
        }
    }

    // MARK: - Microphones

    func refreshDevices() {
        inputDevices = AudioRecorder.listInputDevices()
        onMenuStateChanged?()
    }

    var currentMicrophoneDisplayName: String {
        if settings.selectedMicUID.isEmpty {
            if let def = inputDevices.first(where: \.isDefault) {
                return "\(def.name) (Типовий)"
            }
            return "Системний мікрофон"
        }
        if let found = inputDevices.first(where: { $0.uid == settings.selectedMicUID }) {
            return found.isDefault ? "\(found.name) (Типовий)" : found.name
        }
        if let def = inputDevices.first(where: \.isDefault) {
            return "\(def.name) (Типовий)"
        }
        return "Системний мікрофон"
    }

    // MARK: - Shortcut Capture for UI

    func beginCapturingShortcut(for target: String) {
        capturingShortcutTarget = target
        hotkeyManager.shortcutCaptureHandler = { [weak self] binding in
            Task { @MainActor in
                guard let self else { return }
                switch target {
                case "ptt":
                    self.settings.pushToTalkShortcut = binding
                case "toggle":
                    self.settings.toggleShortcut = binding
                case "mode":
                    self.settings.changeModeShortcut = binding
                default:
                    break
                }
                self.endCapturingShortcut()
            }
        }
    }

    func endCapturingShortcut() {
        capturingShortcutTarget = nil
        hotkeyManager.shortcutCaptureHandler = nil
    }

    // MARK: - Recording Flow

    func toggleRecordingFromMenuOrButton() {
        switch sessionPhase {
        case .idle:
            startRecording(handsFree: true)
        case .recording:
            stopAndTranscribe()
        case .transcribing:
            break
        }
    }

    func startRecording(handsFree: Bool) {
        guard sessionPhase == .idle else { return }

        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if authStatus == .notDetermined {
            AudioRecorder.checkMicrophonePermission { [weak self] granted in
                guard let self, granted else { return }
                self.hasMicPermission = true
            }
            return
        } else if authStatus != .authorized {
            hud.showToast(style: settings.recordingWindowStyle, icon: "mic.slash.fill", message: "Надайте доступ до мікрофона в Налаштуваннях", isWarning: true, duration: 2.6)
            onOpenMainWindowRequested?(.configuration)
            return
        }

        // Capture frontmost app before recording starts
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            targetAppAtStart = front
        }

        // Pick mode: app-specific override if configured, otherwise active mode
        let chosenMode: ShepitMode
        if let bID = targetAppAtStart?.bundleIdentifier,
           let matchedMode = settings.modes.first(where: { $0.activationBundleIDs.contains(bID) }) {
            chosenMode = matchedMode
        } else {
            chosenMode = settings.activeMode
        }
        activeSessionMode = chosenMode

        if settings.contextAwareness {
            let ctx = TextInserter.captureActiveContext(targetApp: targetAppAtStart)
            var dict: [String: Any] = [:]
            if !ctx.selectedText.isEmpty { dict["selected_text"] = ctx.selectedText }
            if !ctx.surroundingText.isEmpty { dict["surrounding_text"] = ctx.surroundingText }
            if !ctx.appName.isEmpty { dict["app_name"] = ctx.appName }
            if !ctx.appBundleID.isEmpty { dict["app_bundle"] = ctx.appBundleID }
            activeSessionContext = dict.isEmpty ? nil : dict
        } else {
            activeSessionContext = nil
        }

        MediaPlaybackController.shared.beginRecording(behavior: settings.playbackBehavior)

        do {
            let wavURL = try recorder.startRecording(preferredUID: settings.selectedMicUID)
            activeRecordingURL = wavURL
            lastVoiceAt = Date()
            sessionPhase = .recording(handsFree: handsFree)
            hotkeyManager.isRecordingActive = true
            hotkeyManager.isHandsFreeLocked = handsFree

            SoundFX.shared.play(.start, style: settings.soundEffectStyle, volume: settings.soundVolume)
            hud.showRecording(style: settings.recordingWindowStyle, modeName: chosenMode.name, handsFree: handsFree, isOffline: !isOnline)
            onMenuStateChanged?()

            if chosenMode.realtimePreview && settings.recordingWindowStyle == .classic {
                startLivePreviewTimer()
            }
        } catch {
            MediaPlaybackController.shared.endRecording(behavior: settings.playbackBehavior)
            hud.showToast(style: settings.recordingWindowStyle, icon: "exclamationmark.triangle.fill", message: error.localizedDescription, isWarning: true)
        }
    }

    func lockHandsFree() {
        guard case .recording(let hf) = sessionPhase, !hf else { return }
        sessionPhase = .recording(handsFree: true)
        lastVoiceAt = Date()
        hotkeyManager.isHandsFreeLocked = true
        hud.updateHandsFree(true)
        onMenuStateChanged?()
    }

    func cancelRecording(silent: Bool) {
        guard case .recording = sessionPhase else { return }
        stopLivePreviewTimer()
        recorder.cancelRecording()
        activeRecordingURL = nil
        sessionPhase = .idle
        hotkeyManager.isRecordingActive = false
        hotkeyManager.isHandsFreeLocked = false
        MediaPlaybackController.shared.endRecording(behavior: settings.playbackBehavior)
        if silent {
            hud.hide()
        } else {
            hud.showCancelled(style: settings.recordingWindowStyle)
            SoundFX.shared.play(.cancel, style: settings.soundEffectStyle, volume: settings.soundVolume)
        }
        onMenuStateChanged?()
    }

    func stopAndTranscribe() {
        guard case .recording = sessionPhase else { return }
        stopLivePreviewTimer()

        let (wavURL, durationMs) = recorder.stopRecording()
        hotkeyManager.isRecordingActive = false
        hotkeyManager.isHandsFreeLocked = false

        // Ignore ultra-short accidental key brushes (< 220 ms) silently
        guard let wavURL, durationMs >= 220 else {
            if let wavURL { try? FileManager.default.removeItem(at: wavURL) }
            sessionPhase = .idle
            MediaPlaybackController.shared.endRecording(behavior: settings.playbackBehavior)
            hud.hide()
            onMenuStateChanged?()
            return
        }

        SoundFX.shared.play(.stop, style: settings.soundEffectStyle, volume: settings.soundVolume)
        sessionPhase = .transcribing
        let mode = activeSessionMode ?? settings.activeMode
        let label = mode.llmMode.isEmpty ? "Розпізнавання…" : "Розпізнавання й обробка…"
        hud.showTranscribing(style: settings.recordingWindowStyle, label: label)
        onMenuStateChanged?()

        let capturedApp = targetAppAtStart
        let appName = capturedApp?.localizedName ?? ""
        let appBundle = capturedApp?.bundleIdentifier ?? ""
        let capturedContext = activeSessionContext

        engine.transcribe(audioURL: wavURL, mode: mode, settings: settings, context: capturedContext, isFile: false) { [weak self] result in
            guard let self else { return }
            self.sessionPhase = .idle
            MediaPlaybackController.shared.endRecording(behavior: self.settings.playbackBehavior)
            self.onMenuStateChanged?()

            switch result {
            case .success(let resp):
                if resp.noVoice || resp.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try? FileManager.default.removeItem(at: wavURL)
                    if durationMs >= 750 {
                        let emptyItem = RecordingItem(
                            id: UUID().uuidString,
                            timestamp: Date(),
                            durationMs: durationMs,
                            wordCount: 0,
                            charCount: 0,
                            processingMs: resp.processingMs,
                            appName: appName,
                            appBundleID: appBundle,
                            modeName: mode.name,
                            engineUsed: resp.engineUsed,
                            text: "",
                            rawText: "",
                            audioFile: "",
                            noVoice: true,
                            fromFile: false,
                            groqAssisted: false
                        )
                        self.storage.saveRecording(emptyItem)
                        self.reloadHistory()
                    }
                    self.hud.showToast(style: self.settings.recordingWindowStyle, icon: "waveform.slash", message: "Голосу не виявлено", duration: 1.2, tone: .neutral)
                    return
                }

                let finalText = resp.text
                self.learnCorrections(resp.corrections)
                let words = finalText.split(whereSeparator: \.isWhitespace).count
                let recID = UUID().uuidString

                TextInserter.insertText(
                    finalText,
                    autoPaste: mode.autoPaste,
                    restorePreviousClipboard: self.settings.restorePreviousClipboard && !self.settings.keepClipboardCopy,
                    targetApp: capturedApp
                ) { [weak self] pastedViaAX in
                    guard let self else { return }
                    SoundFX.shared.play(.pasteDone, style: self.settings.soundEffectStyle, volume: self.settings.soundVolume)
                    if mode.autoPaste && !pastedViaAX {
                        self.hud.showToast(
                            style: self.settings.recordingWindowStyle,
                            icon: "doc.on.clipboard.fill",
                            message: "У буфері (⌘V) · Увімкніть Доступність для авто-вставки",
                            duration: 2.8,
                            tone: .neutral,
                            onTap: { [weak self] in self?.onOpenMainWindowRequested?(.configuration) }
                        )
                    } else if let note = Self.offlineNote(for: resp) {
                        // Calm, non-alarming: the text is in place, it just skipped an online step
                        self.hud.showToast(
                            style: self.settings.recordingWindowStyle,
                            icon: "wifi.slash",
                            message: note,
                            duration: 1.9,
                            tone: .neutral
                        )
                    } else {
                        self.hud.showDone(style: self.settings.recordingWindowStyle)
                    }
                }

                // Compress & archive audio in background so UI never stalls
                let retention = self.settings.audioRetention
                let storageRef = self.storage
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let archivedFile = storageRef.archiveWAVToM4A(wavURL: wavURL, id: recID, retention: retention)
                    let item = RecordingItem(
                        id: recID,
                        timestamp: Date(),
                        durationMs: durationMs > 0 ? durationMs : resp.durationSec * 1000.0,
                        wordCount: words,
                        charCount: finalText.count,
                        processingMs: resp.processingMs,
                        appName: appName,
                        appBundleID: appBundle,
                        modeName: mode.name,
                        engineUsed: resp.engineUsed,
                        text: finalText,
                        rawText: resp.rawText,
                        audioFile: archivedFile,
                        noVoice: false,
                        fromFile: false,
                        groqAssisted: resp.groqAssisted,
                        netPending: resp.onlineCheckSkipped,
                        llmPending: resp.llmSkipped
                    )
                    storageRef.saveRecording(item)
                    DispatchQueue.main.async {
                        self?.reloadHistory()
                        self?.reloadStats()
                    }
                }

            case .failure(let err):
                // Preserve audio in history even if recognition failed, so user NEVER loses a recording!
                let recID = UUID().uuidString
                let savedFile = self.storage.archiveWAVToM4A(wavURL: wavURL, id: recID, retention: .oneWeek)
                let fallbackItem = RecordingItem(
                    id: recID,
                    timestamp: Date(),
                    durationMs: durationMs,
                    wordCount: 0,
                    charCount: 0,
                    processingMs: 0,
                    appName: appName,
                    appBundleID: appBundle,
                    modeName: mode.name,
                    engineUsed: RecordingItem.failedEngineLabel,
                    text: "[Не вдалося розпізнати — аудіо збережено, натисніть «Повторити» в Історії]",
                    rawText: "",
                    audioFile: savedFile,
                    noVoice: false,
                    fromFile: false,
                    groqAssisted: false
                )
                self.storage.saveRecording(fallbackItem)
                self.reloadHistory()
                // Tapping the error opens History, where the saved audio can be retried
                self.hud.showToast(
                    style: self.settings.recordingWindowStyle,
                    icon: "exclamationmark.triangle.fill",
                    message: err.localizedDescription,
                    duration: 4.0,
                    tone: .error,
                    onTap: { [weak self] in
                        self?.hud.hide()
                        self?.onOpenMainWindowRequested?(.history)
                    }
                )
            }
        }
    }

    // MARK: - Hands-free auto-stop

    private var lastVoiceAt = Date()
    private static let silenceLimitSec: TimeInterval = 20
    /// Waveform level (0…1 after the recorder's boost) above which a slice counts as speech
    private static let voiceLevelThreshold: CGFloat = 0.2

    /// A forgotten hands-free recording stops itself after a long silence instead of running for an hour.
    private func trackSilence(levels: [CGFloat]) {
        guard case .recording(let handsFree) = sessionPhase, handsFree,
              settings.autoStopOnSilence ?? true else { return }
        if (levels.suffix(3).max() ?? 0) > Self.voiceLevelThreshold {
            lastVoiceAt = Date()
        } else if Date().timeIntervalSince(lastVoiceAt) > Self.silenceLimitSec {
            lastVoiceAt = Date()
            stopAndTranscribe()
        }
    }

    // MARK: - Catch-up after offline

    /// Records inserted without the online check or the AI step finish those steps once the network is back.
    /// Only History is updated — nothing is pasted again.
    func redoOfflineItems() {
        guard isOnline, sessionPhase == .idle, settings.autoRedoAfterOffline ?? true else { return }
        let cutoff = Date().addingTimeInterval(-48 * 3600)
        let pending = storage.fetchHistory(limit: 250)
            .filter { ($0.netPending || $0.llmPending) && !$0.noVoice && $0.timestamp > cutoff }
            .prefix(5)
        for item in pending {
            let audioExists = !item.audioFile.isEmpty
                && FileManager.default.fileExists(atPath: storage.resolveAudioURL(item.audioFile).path)
            if item.netPending && audioExists && workerStatus.hasGroqKey {
                retranscribeHistoryItem(item, engineChoice: .hybrid, silent: true)
            } else if item.llmPending {
                applyAIToHistoryItem(item, silent: true)
            }
        }
    }

    // MARK: - Learning vocabulary

    private static let learnedKey = "learnedCorrections"
    private static let dismissedKey = "dismissedCorrections"
    private static let suggestAfter = 3

    private func learnCorrections(_ corrections: [(from: String, to: String)]) {
        guard !corrections.isEmpty else { return }
        var counts = (UserDefaults.standard.dictionary(forKey: Self.learnedKey) as? [String: Int]) ?? [:]
        for c in corrections {
            counts["\(c.from.lowercased())\t\(c.to)", default: 0] += 1
        }
        UserDefaults.standard.set(counts, forKey: Self.learnedKey)
        refreshVocabSuggestions()
    }

    func refreshVocabSuggestions() {
        let counts = (UserDefaults.standard.dictionary(forKey: Self.learnedKey) as? [String: Int]) ?? [:]
        let dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? [])
        let existing = Set(settings.replacements.map { $0.from.lowercased() })
        vocabSuggestions = counts.compactMap { key, count -> VocabSuggestion? in
            let parts = key.components(separatedBy: "\t")
            guard parts.count == 2, count >= Self.suggestAfter,
                  !dismissed.contains(key), !existing.contains(parts[0]) else { return nil }
            return VocabSuggestion(from: parts[0], to: parts[1], count: count)
        }
        .sorted { $0.count > $1.count }
    }

    func acceptVocabSuggestion(_ suggestion: VocabSuggestion) {
        settings.replacements.append(ReplacementRule(from: suggestion.from, to: suggestion.to))
        refreshVocabSuggestions()
    }

    func dismissVocabSuggestion(_ suggestion: VocabSuggestion) {
        var dismissed = UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? []
        dismissed.append(suggestion.id)
        UserDefaults.standard.set(dismissed, forKey: Self.dismissedKey)
        refreshVocabSuggestions()
    }

    private func startLivePreviewTimer() {
        stopLivePreviewTimer()
        previewInFlight = false
        previewTimer = Timer.scheduledTimer(withTimeInterval: 1.35, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      case .recording = self.sessionPhase,
                      !self.previewInFlight,
                      let url = self.activeRecordingURL else { return }
                self.recorder.flushCurrentWAV()
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                self.previewInFlight = true
                self.engine.requestPreview(audioURL: url) { [weak self] txt in
                    guard let self else { return }
                    self.previewInFlight = false
                    if case .recording = self.sessionPhase, !txt.isEmpty {
                        self.hud.updateLivePreview(txt)
                    }
                }
            }
        }
    }

    private func stopLivePreviewTimer() {
        previewTimer?.invalidate()
        previewTimer = nil
        previewInFlight = false
    }

    // MARK: - Mode Switching

    func cycleActiveMode() {
        guard !settings.modes.isEmpty else { return }
        let idx = settings.modes.firstIndex(where: { $0.id == settings.activeModeID }) ?? 0
        let next = settings.modes[(idx + 1) % settings.modes.count]
        settings.activeModeID = next.id
        hud.showToast(style: settings.recordingWindowStyle, icon: next.icon, message: "Режим: \(next.name)", isWarning: false, duration: 1.3)
        onMenuStateChanged?()
    }

    // MARK: - File Transcription & Re-transcribe

    func promptAndTranscribeFile() {
        let panel = NSOpenPanel()
        panel.title = "Виберіть аудіо або відео для розпізнавання"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .quickTimeMovie, .wav, .mp3]

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let fileURL = panel.url else { return }

        transcribeExternalFile(url: fileURL)
    }

    func transcribeExternalFile(url: URL) {
        statusBannerMessage = "Розпізнаємо файл «\(url.lastPathComponent)»…"
        hud.showTranscribing(style: .mini, label: "Файл: \(url.lastPathComponent)…")
        let mode = settings.activeMode

        engine.transcribe(audioURL: url, mode: mode, settings: settings, isFile: true) { [weak self] result in
            guard let self else { return }
            self.hud.hide()
            switch result {
            case .success(let resp):
                let txt = resp.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !txt.isEmpty else {
                    self.statusBannerMessage = "У файлі не виявлено мовлення"
                    return
                }
                TextInserter.copyToClipboard(txt)
                let words = txt.split(whereSeparator: \.isWhitespace).count
                let item = RecordingItem(
                    id: UUID().uuidString,
                    timestamp: Date(),
                    durationMs: resp.durationSec * 1000.0,
                    wordCount: words,
                    charCount: txt.count,
                    processingMs: resp.processingMs,
                    appName: url.lastPathComponent,
                    appBundleID: "",
                    modeName: mode.name,
                    engineUsed: resp.engineUsed,
                    text: txt,
                    rawText: resp.rawText,
                    audioFile: url.path,
                    noVoice: false,
                    fromFile: true,
                    groqAssisted: resp.groqAssisted
                )
                self.storage.saveRecording(item)
                self.reloadHistory()
                self.reloadStats()
                self.selectedSection = .history
                self.statusBannerMessage = "Файл розпізнано (\(words) слів) і скопійовано в буфер!"
                self.onOpenMainWindowRequested?(.history)

            case .failure(let err):
                self.statusBannerMessage = "Помилка: \(err.localizedDescription)"
            }
        }
    }

    /// Mode the recording was made in (so a retry applies the same AI step), else the active one.
    private func modeForItem(_ item: RecordingItem) -> ShepitMode {
        settings.modes.first(where: { $0.name == item.modeName }) ?? settings.activeMode
    }

    static func offlineNote(for resp: TranscriptionResponse) -> String? {
        switch (resp.onlineCheckSkipped, resp.llmSkipped) {
        case (true, true): return "Вставлено без онлайн-перевірки й ШІ"
        case (false, true): return "Вставлено без ШІ-обробки"
        case (true, false): return "Вставлено без онлайн-перевірки"
        default: return nil
        }
    }

    func retranscribeHistoryItem(_ item: RecordingItem, engineChoice: EngineChoice, silent: Bool = false) {
        guard !item.audioFile.isEmpty else { return }
        let url = storage.resolveAudioURL(item.audioFile)
        guard FileManager.default.fileExists(atPath: url.path) else {
            if !silent { statusBannerMessage = "Аудіофайл для цього запису вже очищено" }
            return
        }
        if !silent {
            statusBannerMessage = engineChoice == .parakeet
                ? "Розпізнаємо ще раз локально…"
                : "Перевіряємо онлайн через \(engineChoice.shortBadge)…"
        }
        let mode = modeForItem(item)
        engine.transcribe(
            audioURL: url,
            mode: mode,
            settings: settings,
            forceEngine: engineChoice,
            isFile: true,
            forceNetwork: engineChoice != .parakeet
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let resp):
                guard !resp.text.isEmpty else {
                    if !silent { self.statusBannerMessage = "Мовлення не знайдено" }
                    return
                }
                var updated = item
                updated.text = resp.text
                updated.rawText = resp.rawText
                updated.wordCount = resp.text.split(whereSeparator: \.isWhitespace).count
                updated.charCount = resp.text.count
                updated.engineUsed = resp.engineUsed
                updated.noVoice = false
                updated.groqAssisted = resp.groqAssisted
                updated.netPending = resp.onlineCheckSkipped
                updated.llmPending = resp.llmSkipped
                self.storage.saveRecording(updated)
                self.reloadHistory()
                self.reloadStats()
                guard !silent else { return }
                TextInserter.copyToClipboard(resp.text)
                if let note = Self.offlineNote(for: resp) {
                    self.statusBannerMessage = "Оновлено локально й скопійовано · \(note.lowercased())"
                } else {
                    self.statusBannerMessage = "Оновлено та скопійовано в буфер!"
                }
            case .failure(let err):
                if !silent { self.statusBannerMessage = "Помилка: \(err.localizedDescription)" }
            }
        }
    }

    /// History → «Обробити ШІ»: runs only the AI step the mode asked for over the saved text.
    func applyAIToHistoryItem(_ item: RecordingItem, silent: Bool = false) {
        let mode = modeForItem(item)
        guard !mode.llmMode.isEmpty, !item.text.isEmpty else { return }
        if !silent { statusBannerMessage = "Обробляємо ШІ («\(mode.name)»)…" }
        engine.postprocess(text: item.text, mode: mode, settings: settings) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let out):
                guard out.applied else {
                    if !silent { self.statusBannerMessage = "ШІ зараз недоступний — спробуйте пізніше" }
                    return
                }
                var updated = item
                updated.text = out.text
                updated.wordCount = out.text.split(whereSeparator: \.isWhitespace).count
                updated.charCount = out.text.count
                updated.llmPending = false
                self.storage.saveRecording(updated)
                self.reloadHistory()
                guard !silent else { return }
                TextInserter.copyToClipboard(out.text)
                self.statusBannerMessage = "Оброблено ШІ та скопійовано в буфер!"
            case .failure(let err):
                if !silent { self.statusBannerMessage = "Помилка: \(err.localizedDescription)" }
            }
        }
    }

    // MARK: - History & Audio Playback

    func reloadHistory() {
        let pendingID = uiPendingDeleteItem?.id
        historyItems = storage.fetchHistory(search: historySearch).filter { $0.id != pendingID }
    }

    func reloadStats() {
        stats = storage.fetchStats(range: statRange, typingBaselineWPM: settings.typingBaselineWPM)
    }

    private var pendingDeleteWorkItem: DispatchWorkItem?

    /// Hides the record at once but really deletes it only after a grace period, so it can be restored.
    func deleteItem(_ item: RecordingItem) {
        if playingItemID == item.id {
            stopAudioPlayback()
        }
        commitPendingDelete()
        uiPendingDeleteItem = item
        reloadHistory()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.uiPendingDeleteItem?.id == item.id else { return }
                self.commitPendingDelete()
            }
        }
        pendingDeleteWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: work)
    }

    func undoDelete() {
        pendingDeleteWorkItem?.cancel()
        uiPendingDeleteItem = nil
        reloadHistory()
    }

    func commitPendingDelete() {
        pendingDeleteWorkItem?.cancel()
        guard let item = uiPendingDeleteItem else { return }
        uiPendingDeleteItem = nil
        storage.deleteHistoryItem(item)
        reloadHistory()
        reloadStats()
    }

    func togglePlayAudio(for item: RecordingItem) {
        if playingItemID == item.id {
            stopAudioPlayback()
            return
        }
        stopAudioPlayback()
        guard !item.audioFile.isEmpty else { return }
        let url = storage.resolveAudioURL(item.audioFile)
        guard FileManager.default.fileExists(atPath: url.path) else {
            statusBannerMessage = "Аудіофайл уже видалено за правилом зберігання"
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.play()
            audioPlayer = p
            playingItemID = item.id
        } catch {
            statusBannerMessage = "Не вдалося відтворити аудіо"
        }
    }

    func stopAudioPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        playingItemID = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.playingItemID = nil
            self.audioPlayer = nil
        }
    }

    // MARK: - 1-Click Local Model Installer & API Key Setup (for clean Macs)

    func saveAPIKey(name: String, rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let keysDir = home.appendingPathComponent(".config/keys", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: keysDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let fileURL = keysDir.appendingPathComponent("\(name).key")
            try (trimmed + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

            if name == "groq" {
                uiGroqKeyInput = ""
                uiShowGroqKeyEditor = false
                workerStatus.hasGroqKey = true
            } else if name == "gemini" {
                uiGeminiKeyInput = ""
                uiShowGeminiKeyEditor = false
                workerStatus.hasGeminiKey = true
            }
            engine.refreshStatus()
            statusBannerMessage = "Ключ \(name.uppercased()) збережено в ~/.config/keys/\(name).key"
        } catch {
            statusBannerMessage = "Не вдалося зберегти ключ: \(error.localizedDescription)"
        }
    }

    func installLocalParakeetModel() {
        guard !isInstallingModel else { return }
        isInstallingModel = true
        modelInstallProgress = 0.04
        modelInstallStage = "Крок 1/3 · Підготовка середовища Apple MLX…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let home = FileManager.default.homeDirectoryForCurrentUser
            let pyBin = home.appendingPathComponent(".local/share/uv/tools/parakeet-mlx/bin/python").path

            if !FileManager.default.isExecutableFile(atPath: pyBin) {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
                let cmd = """
                set -e
                export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
                if ! command -v uv >/dev/null 2>&1; then
                  curl -LsSf https://astral.sh/uv/install.sh | sh
                fi
                export PATH="$HOME/.local/bin:$PATH"
                uv tool install parakeet-mlx --python 3.12 --force
                """
                proc.arguments = ["-c", cmd]
                let errPipe = Pipe()
                proc.standardError = errPipe
                proc.standardOutput = Pipe()
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    if proc.terminationStatus != 0 {
                        let errTxt = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        Task { @MainActor in
                            self?.isInstallingModel = false
                            self?.modelInstallStage = ""
                            self?.statusBannerMessage = "Помилка встановлення parakeet-mlx: \(errTxt.prefix(140))"
                        }
                        return
                    }
                } catch {
                    Task { @MainActor in
                        self?.isInstallingModel = false
                        self?.modelInstallStage = ""
                        self?.statusBannerMessage = "Помилка запуску інсталятора: \(error.localizedDescription)"
                    }
                    return
                }
            }

            let modelDir = home.appendingPathComponent(".local/share/models/parakeet-tdt-0.6b-v3", isDirectory: true)
            try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

            let configDest = modelDir.appendingPathComponent("config.json")
            let weightsDest = modelDir.appendingPathComponent("model.safetensors")

            Task { @MainActor in
                self?.modelInstallProgress = 0.16
                self?.modelInstallStage = "Крок 2/3 · Завантаження конфігурації моделі…"
            }

            if !FileManager.default.fileExists(atPath: configDest.path) {
                if let cfgURL = URL(string: "https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3/resolve/main/config.json"),
                   let cfgData = try? Data(contentsOf: cfgURL) {
                    try? cfgData.write(to: configDest, options: .atomic)
                }
            }

            let existingSize = (try? FileManager.default.attributesOfItem(atPath: weightsDest.path)[.size] as? Int64) ?? 0
            if existingSize > 2_000_000_000 {
                Task { @MainActor in
                    self?.finishModelInstallation()
                }
                return
            }

            guard let weightsURL = URL(string: "https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3/resolve/main/model.safetensors") else {
                return
            }

            Task { @MainActor in
                guard let self else { return }
                self.modelInstallProgress = 0.18
                self.modelInstallStage = "Крок 2/3 · Завантаження ваг Parakeet v3 (0%)…"

                let task = URLSession.shared.downloadTask(with: weightsURL) { [weak self] tempURL, _, err in
                    guard let self else { return }
                    if let err {
                        Task { @MainActor in
                            self.downloadProgressObs?.invalidate()
                            self.downloadProgressObs = nil
                            self.isInstallingModel = false
                            self.modelInstallStage = ""
                            self.statusBannerMessage = "Помилка завантаження моделі: \(err.localizedDescription)"
                        }
                        return
                    }
                    guard let tempURL else { return }
                    do {
                        if FileManager.default.fileExists(atPath: weightsDest.path) {
                            try? FileManager.default.removeItem(at: weightsDest)
                        }
                        try FileManager.default.moveItem(at: tempURL, to: weightsDest)
                        Task { @MainActor in
                            self.finishModelInstallation()
                        }
                    } catch {
                        Task { @MainActor in
                            self.downloadProgressObs?.invalidate()
                            self.downloadProgressObs = nil
                            self.isInstallingModel = false
                            self.modelInstallStage = ""
                            self.statusBannerMessage = "Помилка збереження моделі: \(error.localizedDescription)"
                        }
                    }
                }

                self.downloadProgressObs = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] prog, _ in
                    let frac = max(0.0, min(1.0, prog.fractionCompleted))
                    let gb = Double(prog.completedUnitCount) / 1_073_741_824.0
                    Task { @MainActor in
                        guard let self else { return }
                        self.modelInstallProgress = 0.18 + frac * 0.76
                        self.modelInstallStage = String(format: "Крок 2/3 · Завантаження моделі: %.0f%% (%.2f / 2.34 ГБ)…", frac * 100.0, gb)
                    }
                }

                self.activeDownloadTask = task
                task.resume()
            }
        }
    }

    private func finishModelInstallation() {
        downloadProgressObs?.invalidate()
        downloadProgressObs = nil
        activeDownloadTask = nil
        modelInstallProgress = 0.96
        modelInstallStage = "Крок 3/3 · Запуск Parakeet v3 на Apple GPU…"
        engine.restartWorker()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self else { return }
            self.isInstallingModel = false
            self.modelInstallProgress = 1.0
            self.modelInstallStage = ""
            self.statusBannerMessage = "Модель Parakeet v3 встановлено й завантажено в пам'ять!"
        }
    }

    // MARK: - Quick Pastes & History Export

    var recentPastes: [RecordingItem] {
        Array(historyItems.filter { !$0.noVoice && !$0.text.isEmpty }.prefix(5))
    }

    func copyRecentItem(_ item: RecordingItem) {
        TextInserter.copyToClipboard(item.text)
        hud.showToast(
            style: settings.recordingWindowStyle,
            icon: "doc.on.doc.fill",
            message: "Скопійовано в буфер обміну",
            isWarning: false,
            duration: 1.3
        )
    }

    func exportHistory(format: String) -> URL? {
        let items = historyItems.filter { !$0.noVoice && !$0.text.isEmpty }
        guard !items.isEmpty else {
            statusBannerMessage = "Історія порожня для експорту"
            return nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let timestamp = dateFormatter.string(from: Date())
        let tempDir = home.appendingPathComponent("Downloads", isDirectory: true)

        let outURL: URL
        let content: String

        switch format.lowercased() {
        case "markdown", "md":
            outURL = tempDir.appendingPathComponent("Шепіт_Історія_\(timestamp).md")
            var md = "# Історія диктування «Шепіт»\n\n*Експортовано: \(Date().formatted()) · Записів: \(items.count)*\n\n---\n\n"
            for item in items {
                md += "### \(item.timestamp.formatted()) · \(item.appName.isEmpty ? "Застосунок" : item.appName) (\(item.wordCount) слів)\n"
                md += "> Режим: \(item.modeName) · Движок: \(item.engineUsed)\n\n"
                md += "\(item.text)\n\n---\n\n"
            }
            content = md

        case "srt":
            outURL = tempDir.appendingPathComponent("Шепіт_Субтитри_\(timestamp).srt")
            var srt = ""
            var currentSec: Double = 0
            for (idx, item) in items.reversed().enumerated() {
                let start = currentSec
                let dur = max(1.5, item.durationMs / 1000.0)
                let end = start + dur
                currentSec = end + 0.5

                func srtTime(_ sec: Double) -> String {
                    let totalMs = Int(sec * 1000)
                    let h = totalMs / 3600000
                    let m = (totalMs % 3600000) / 60000
                    let s = (totalMs % 60000) / 1000
                    let ms = totalMs % 1000
                    return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
                }

                srt += "\(idx + 1)\n"
                srt += "\(srtTime(start)) --> \(srtTime(end))\n"
                srt += "\(item.text)\n\n"
            }
            content = srt

        default: // txt
            outURL = tempDir.appendingPathComponent("Шепіт_Історія_\(timestamp).txt")
            var txt = "ІСТОРІЯ ДИКТУВАННЯ «ШЕПІТ» (\(items.count) записів)\n\n"
            for item in items {
                txt += "[\(item.timestamp.formatted()) | \(item.appName)]\n\(item.text)\n\n"
            }
            content = txt
        }

        do {
            try content.write(to: outURL, atomically: true, encoding: .utf8)
            statusBannerMessage = "Експортовано у Завантаження: \(outURL.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([outURL])
            return outURL
        } catch {
            statusBannerMessage = "Помилка експорту: \(error.localizedDescription)"
            return nil
        }
    }
}
