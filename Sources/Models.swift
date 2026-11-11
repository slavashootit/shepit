import Foundation
import AppKit

enum AppSection: String, CaseIterable, Identifiable {
    case home = "home"
    case modes = "modes"
    case vocabulary = "vocabulary"
    case configuration = "configuration"
    case sound = "sound"
    case models = "models"
    case history = "history"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Головна"
        case .modes: return "Режими"
        case .vocabulary: return "Словник"
        case .configuration: return "Налаштування"
        case .sound: return "Звук"
        case .models: return "Моделі"
        case .history: return "Історія"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .modes: return "sparkles"
        case .vocabulary: return "character.book.closed.fill"
        case .configuration: return "gearshape.fill"
        case .sound: return "speaker.wave.2.fill"
        case .models: return "cpu.fill"
        case .history: return "clock.arrow.circlepath"
        }
    }

    var badgeTint: NSColor {
        switch self {
        case .home: return NSColor(calibratedRed: 0.98, green: 0.45, blue: 0.22, alpha: 1)
        case .modes: return NSColor(calibratedRed: 0.20, green: 0.62, blue: 1.00, alpha: 1)
        case .vocabulary: return NSColor(calibratedRed: 0.16, green: 0.54, blue: 0.96, alpha: 1)
        case .configuration: return NSColor(calibratedRed: 0.56, green: 0.58, blue: 0.64, alpha: 1)
        case .sound: return NSColor(calibratedRed: 0.22, green: 0.80, blue: 0.62, alpha: 1)
        case .models: return NSColor(calibratedRed: 0.64, green: 0.48, blue: 0.98, alpha: 1)
        case .history: return NSColor(calibratedRed: 0.52, green: 0.44, blue: 0.96, alpha: 1)
        }
    }
}

enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case auto
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Авто"
        case .light: return "Світла"
        case .dark: return "Темна"
        }
    }
}

enum RecordingWindowStyle: String, Codable, CaseIterable, Identifiable {
    case classic
    case mini
    case notch
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return "Класичне"
        case .mini: return "Міні"
        case .notch: return "Виріз (Notch)"
        case .none: return "Сховане"
        }
    }
}

enum EngineChoice: String, Codable, CaseIterable, Identifiable {
    case hybrid
    case parakeet
    case groq

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hybrid: return "Parakeet v3 + Groq (Гібрид)"
        case .parakeet: return "Parakeet v3 (Локально)"
        case .groq: return "Groq Whisper v3 (Хмара)"
        }
    }

    var shortBadge: String {
        switch self {
        case .hybrid: return "Parakeet + Groq"
        case .parakeet: return "Parakeet Офлайн"
        case .groq: return "Groq Cloud"
        }
    }
}

enum PlaybackBehavior: String, Codable, CaseIterable, Identifiable {
    case pause
    case mute
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pause: return "Пауза"
        case .mute: return "Притишити"
        case .none: return "Не чіпати"
        }
    }
}

enum SoundEffectStyle: String, Codable, CaseIterable, Identifiable {
    case simple
    case classic
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simple: return "М'які"
        case .classic: return "Класичні"
        case .off: return "Вимкнено"
        }
    }
}

enum AudioRetention: String, Codable, CaseIterable, Identifiable {
    case never
    case oneDay
    case oneWeek
    case oneMonth
    case forever

    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: return "Лише текст (без аудіо)"
        case .oneDay: return "1 день"
        case .oneWeek: return "1 тиждень"
        case .oneMonth: return "1 місяць"
        case .forever: return "Назавжди"
        }
    }

    var maxAgeSeconds: TimeInterval? {
        switch self {
        case .never: return 0
        case .oneDay: return 86_400
        case .oneWeek: return 7 * 86_400
        case .oneMonth: return 30 * 86_400
        case .forever: return nil
        }
    }
}

enum StatRange: String, CaseIterable, Identifiable {
    case today
    case week
    case month
    case allTime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Сьогодні"
        case .week: return "7 днів"
        case .month: return "30 днів"
        case .allTime: return "Весь час"
        }
    }

    var cutoffDate: Date? {
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .today:
            return cal.startOfDay(for: now)
        case .week:
            return cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now))
        case .month:
            return cal.date(byAdding: .day, value: -29, to: cal.startOfDay(for: now))
        case .allTime:
            return nil
        }
    }
}

struct ShortcutBinding: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt64 // CGEventFlags rawValue (maskCommand, maskAlternate, maskShift, maskControl)
    var isModifierOnly: Bool
    var enabled: Bool

    static let rightOptionPTT = ShortcutBinding(
        keyCode: 61, // kVK_RightOption
        modifiers: CGEventFlags.maskAlternate.rawValue,
        isModifierOnly: true,
        enabled: true
    )

    static let optionSpaceToggle = ShortcutBinding(
        keyCode: 49, // kVK_Space
        modifiers: CGEventFlags.maskAlternate.rawValue,
        isModifierOnly: false,
        enabled: true
    )

    static let optionShiftKMode = ShortcutBinding(
        keyCode: 40, // kVK_ANSI_K
        modifiers: CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskShift.rawValue,
        isModifierOnly: false,
        enabled: true
    )

    var displayTokens: [String] {
        if !enabled { return ["Вимкнено"] }
        if isModifierOnly {
            switch keyCode {
            case 61: return ["⌥ Правий"]
            case 58: return ["⌥ Лівий"]
            case 54: return ["⌘ Правий"]
            case 55: return ["⌘ Лівий"]
            case 60: return ["⇧ Правий"]
            case 56: return ["⇧ Лівий"]
            case 62: return ["⌃ Правий"]
            case 59: return ["⌃ Лівий"]
            case 63: return ["fn"]
            default: return ["Клавіша \(keyCode)"]
            }
        }
        var parts: [String] = []
        let flags = CGEventFlags(rawValue: modifiers)
        if flags.contains(.maskControl) { parts.append("⌃") }
        if flags.contains(.maskAlternate) { parts.append("⌥") }
        if flags.contains(.maskShift) { parts.append("⇧") }
        if flags.contains(.maskCommand) { parts.append("⌘") }
        parts.append(Self.keyName(for: keyCode))
        return parts
    }

    static func keyName(for code: UInt16) -> String {
        let map: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
            44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`",
            51: "⌫", 53: "esc", 96: "F5", 97: "F6", 98: "F7", 99: "F3",
            100: "F8", 101: "F9", 103: "F11", 109: "F10", 111: "F12",
            118: "F4", 120: "F2", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        return map[code] ?? "Key \(code)"
    }
}

struct ShepitMode: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var subtitle: String
    var icon: String
    var language: String // "auto", "uk", "en", "pl", "de", "fr", "es", "it"
    var engine: EngineChoice
    var realtimePreview: Bool
    var llmMode: String // "", "clean", "translate_en", "custom"
    var customPrompt: String
    var autocapitalize: Bool
    var autoPaste: Bool
    var activationBundleIDs: [String]

    static let defaultModes: [ShepitMode] = [
        ShepitMode(
            id: "voice-to-text",
            name: "Голос у текст",
            subtitle: "Пряма точна транскрибація без затримки",
            icon: "mic.fill",
            language: "auto",
            engine: .hybrid,
            realtimePreview: true,
            llmMode: "",
            customPrompt: "",
            autocapitalize: true,
            autoPaste: true,
            activationBundleIDs: []
        ),
        ShepitMode(
            id: "clean-thought",
            name: "Чиста думка",
            subtitle: "Прибирає обмовки, «ну» та самовиправлення, зберігаючи твій тон",
            icon: "wand.and.stars",
            language: "auto",
            engine: .hybrid,
            realtimePreview: true,
            llmMode: "clean",
            customPrompt: "",
            autocapitalize: true,
            autoPaste: true,
            activationBundleIDs: []
        ),
        ShepitMode(
            id: "translate-en",
            name: "Переклад англійською",
            subtitle: "Говориш українською — вставляє природною англійською",
            icon: "globe",
            language: "auto",
            engine: .hybrid,
            realtimePreview: false,
            llmMode: "translate_en",
            customPrompt: "",
            autocapitalize: true,
            autoPaste: true,
            activationBundleIDs: []
        ),
        ShepitMode(
            id: "business-email",
            name: "Діловий тон",
            subtitle: "Ввічливий, структурований лист чи відповідь клієнту",
            icon: "briefcase.fill",
            language: "auto",
            engine: .hybrid,
            realtimePreview: false,
            llmMode: "custom",
            customPrompt: "Перетвори розмовну думку на ввічливий, чіткий і структурований діловий лист або повідомлення клієнту чи партнеру. Без бюрократизму, природною живою мовою. Якщо передано контекст повідомлення співрозмовника, дай влучну відповідь по суті.",
            autocapitalize: true,
            autoPaste: true,
            activationBundleIDs: []
        ),
        ShepitMode(
            id: "git-commit",
            name: "Git Commit",
            subtitle: "Conventional Commit англійською для розробників",
            icon: "terminal.fill",
            language: "auto",
            engine: .hybrid,
            realtimePreview: false,
            llmMode: "custom",
            customPrompt: "Сформулюй лаконічне Conventional Commit повідомлення англійською мовою (наприклад: feat(hud): add notch integration, fix(audio): prevent engine stall). Тільки одне повідомлення комміту без лапок, пояснень і вступних слів.",
            autocapitalize: false,
            autoPaste: true,
            activationBundleIDs: []
        ),
        ShepitMode(
            id: "bullet-tasks",
            name: "Список задач",
            subtitle: "Структурований чек-лист дій у Markdown (- [ ])",
            icon: "checklist",
            language: "auto",
            engine: .hybrid,
            realtimePreview: false,
            llmMode: "custom",
            customPrompt: "Перетвори потік думок на структурований список завдань у форматі Markdown (- [ ] Завдання). Виділи конкретні дії, відповідальних і терміни, якщо вони названі.",
            autocapitalize: true,
            autoPaste: true,
            activationBundleIDs: []
        )
    ]
}

struct ReplacementRule: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var from: String
    var to: String
    var enabled: Bool = true
}

struct ShepitSettings: Codable, Equatable {
    var theme: AppTheme = .dark
    var recordingWindowStyle: RecordingWindowStyle = .classic

    var pushToTalkShortcut: ShortcutBinding = .rightOptionPTT
    var pushToTalkTapToggle: Bool = true
    var toggleShortcut: ShortcutBinding = .optionSpaceToggle
    var changeModeShortcut: ShortcutBinding = .optionShiftKMode
    var allowAnyOptionForPTT: Bool = false

    var selectedMicUID: String = "" // "" = System Default

    var autoGain: Bool = true
    var silenceRemoval: Bool = true
    var dynamicNormalization: Bool = true
    var playbackBehavior: PlaybackBehavior = .pause

    var enableVoiceCommands: Bool = true
    var enableSmartFormatting: Bool = true
    var contextAwareness: Bool = true

    var soundEffectStyle: SoundEffectStyle = .classic
    var soundVolume: Double = 0.78

    var keepClipboardCopy: Bool = true
    var restorePreviousClipboard: Bool = false
    var audioRetention: AudioRetention = .oneWeek
    var typingBaselineWPM: Int = 40

    var activeModeID: String = "voice-to-text"
    var modes: [ShepitMode] = ShepitMode.defaultModes

    var vocabulary: [String] = [
        "Шепіт", "Apple Silicon", "Claude", "Claude Code",
        "GitHub", "Telegram", "YouTube", "DaVinci Resolve",
        "Figma", "Notion", "ChatGPT", "Reels"
    ]

    var replacements: [ReplacementRule] = [
        ReplacementRule(from: "клод код", to: "Claude Code"),
        ReplacementRule(from: "гітхаб", to: "GitHub"),
        ReplacementRule(from: "ейпл сілікон", to: "Apple Silicon")
    ]

    var didImportSuperwhisper: Bool = false

    var activeMode: ShepitMode {
        modes.first(where: { $0.id == activeModeID }) ?? modes.first ?? ShepitMode.defaultModes[0]
    }
}

struct AudioInputDevice: Identifiable, Equatable {
    var id: UInt32 // AudioDeviceID
    var uid: String
    var name: String
    var isDefault: Bool
}

struct RecordingItem: Identifiable, Equatable {
    var id: String
    var timestamp: Date
    var durationMs: Double
    var wordCount: Int
    var charCount: Int
    var processingMs: Double
    var appName: String
    var appBundleID: String
    var modeName: String
    var engineUsed: String
    var text: String
    var rawText: String
    var audioFile: String // filename inside Application Support/Shepit/recordings or full legacy path
    var noVoice: Bool
    var fromFile: Bool
    var groqAssisted: Bool

    var wpm: Int {
        guard durationMs > 400, wordCount > 0 else { return 0 }
        let minutes = durationMs / 60_000.0
        return Int(round(Double(wordCount) / minutes))
    }
}

struct DailyWordStat: Identifiable, Equatable {
    var id: String { dateKey }
    var dateKey: String // YYYY-MM-DD
    var label: String
    var words: Int
    var count: Int
}

struct AppUsageStat: Identifiable, Equatable {
    var id: String { appName }
    var appName: String
    var words: Int
    var count: Int
    var durationMs: Double
}

struct DashboardStats: Equatable {
    var totalWords: Int = 0
    var totalChars: Int = 0
    var totalDurationMs: Double = 0
    var recordingsCount: Int = 0
    var averageWPM: Int = 0
    var appsUsedCount: Int = 0
    var savedSeconds: Double = 0
    var streakDays: Int = 0
    var dailySeries: [DailyWordStat] = []
    var topApps: [AppUsageStat] = []
    var peakHour: Int? = nil

    static let empty = DashboardStats()

    var formattedSavedTime: String {
        let sec = max(0, Int(savedSeconds))
        if sec < 60 { return "\(sec) с" }
        let mins = sec / 60
        if mins < 60 { return "\(mins) хв" }
        let hours = mins / 60
        let remMins = mins % 60
        if hours < 24 {
            return remMins > 0 ? "\(hours) год \(remMins) хв" : "\(hours) год"
        }
        let days = Double(hours) / 24.0
        if days >= 2.0 {
            let wholeDays = hours / 24
            let remHours = hours % 24
            return remHours > 0 ? "\(wholeDays) дн \(remHours) год" : "\(wholeDays) дн"
        }
        return String(format: "%.1f дн", days)
    }

    var formattedDuration: String {
        let totalSec = Int(totalDurationMs / 1000.0)
        let hours = totalSec / 3600
        let mins = (totalSec % 3600) / 60
        if hours > 0 { return "\(hours) год \(mins) хв" }
        if mins > 0 { return "\(mins) хв" }
        return "\(totalSec) с"
    }
}

struct WorkerStatusInfo: Equatable {
    var isRunning: Bool = false
    var isModelLoaded: Bool = false
    var modelExists: Bool = true
    var loadTimeMs: Int = 0
    var activeMemoryMB: Double = 0
    var hasGroqKey: Bool = false
    var hasGeminiKey: Bool = false
    var lastError: String = ""
}
