import SwiftUI
import AppKit

// MARK: - Formatting Helpers

enum Fmt {
    static func number(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = " "
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

// MARK: - Shared UI Components

struct SectionCard<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            )
    }
}

struct KeyCapBadge: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .foregroundColor(.primary.opacity(0.86))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.09))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.8)
                    )
            )
    }
}

// MARK: - Root Dashboard Window View

struct MainDashboardView: View {
    @ObservedObject var app: AppState

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 224)

            Divider()
                .opacity(0.35)

            VStack(spacing: 0) {
                topBar
                Divider().opacity(0.25)

                if let banner = app.statusBannerMessage {
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(Color(red: 0.24, green: 0.82, blue: 0.66))
                        Text(banner)
                            .font(.system(size: 12.5, weight: .medium))
                        Spacer()
                        Button(action: { app.statusBannerMessage = nil }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 9)
                    .background(Color(red: 0.24, green: 0.82, blue: 0.66).opacity(0.10))
                }

                Group {
                    switch app.selectedSection {
                    case .home:
                        HomeSectionView(app: app)
                    case .modes:
                        ModesSectionView(app: app)
                    case .vocabulary:
                        VocabularySectionView(app: app)
                    case .configuration:
                        ConfigurationSectionView(app: app)
                    case .sound:
                        SoundSectionView(app: app)
                    case .models:
                        ModelsSectionView(app: app)
                    case .history:
                        HistorySectionView(app: app)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 920, minHeight: 620)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.20, green: 0.82, blue: 0.68),
                                    Color(red: 0.34, green: 0.48, blue: 0.98)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 30, height: 30)
                    Image(systemName: "waveform")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Шепіт")
                        .font(.system(size: 15, weight: .bold))
                    Text(app.settings.activeMode.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 12)

            ForEach(AppSection.allCases) { sec in
                sidebarButton(sec)
            }

            Spacer()

            // Bottom Engine Live Status Pill
            HStack(spacing: 9) {
                Circle()
                    .fill(engineDotColor)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.workerStatus.isModelLoaded ? "Parakeet v3 у пам'яті" : "Прогрівання моделі…")
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                    Text(app.workerStatus.hasGroqKey ? "Гібрид із Groq активний" : "Локальний офлайн-режим")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
            .onTapGesture {
                app.selectedSection = .models
            }
        }
        .background(Color.primary.opacity(0.02))
    }

    private var engineDotColor: Color {
        if !app.workerStatus.lastError.isEmpty { return .orange }
        if app.workerStatus.isModelLoaded { return Color(red: 0.22, green: 0.86, blue: 0.62) }
        return .yellow
    }

    private func sidebarButton(_ sec: AppSection) -> some View {
        let isSelected = app.selectedSection == sec
        return Button(action: { app.selectedSection = sec }) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: sec.badgeTint))
                        .frame(width: 22, height: 22)
                    Image(systemName: sec.icon)
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundColor(.white)
                }
                Text(sec.title)
                    .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .primary : .primary.opacity(0.82))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.11) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
    }

    // MARK: - Top Bar (Quick Mic Picker & Record Button)

    private var topBar: some View {
        HStack(spacing: 14) {
            Text(app.selectedSection.title)
                .font(.system(size: 16, weight: .bold))

            Spacer()

            // Quick Record / Stop button
            Button(action: { app.toggleRecordingFromMenuOrButton() }) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isRecording ? Color.red : Color(red: 0.22, green: 0.84, blue: 0.64))
                        .frame(width: 7, height: 7)
                    Text(recordButtonLabel)
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(isRecording ? Color.red.opacity(0.16) : Color.primary.opacity(0.07))
                )
            }
            .buttonStyle(.plain)

            // Microphone selector (just like top-right HyperX Quadcast picker!)
            Menu {
                Button(action: { app.settings.selectedMicUID = "" }) {
                    HStack {
                        Text("Системний типовий")
                        if app.settings.selectedMicUID.isEmpty { Image(systemName: "checkmark") }
                    }
                }
                Divider()
                ForEach(app.inputDevices) { dev in
                    Button(action: { app.settings.selectedMicUID = dev.uid }) {
                        HStack {
                            Text(dev.isDefault ? "\(dev.name) (Типовий)" : dev.name)
                            if app.settings.selectedMicUID == dev.uid { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                    Text(app.currentMicrophoneDisplayName)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 11)
    }

    private var isRecording: Bool {
        if case .recording = app.sessionPhase { return true }
        return false
    }

    private var recordButtonLabel: String {
        switch app.sessionPhase {
        case .idle: return "Запис"
        case .recording: return "Зупинити"
        case .transcribing: return "Обробка…"
        }
    }
}

// MARK: - 1. Home & Statistics View

struct HomeSectionView: View {
    @ObservedObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                permissionsBannerIfNeeded

                // Period Picker Header
                HStack {
                    Picker("", selection: $app.statRange) {
                        ForEach(StatRange.allCases) { r in
                            Text(r.title).tag(r)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 340)

                    Spacer()

                    if app.stats.streakDays > 0 {
                        HStack(spacing: 5) {
                            Image(systemName: "flame.fill")
                                .foregroundColor(.orange)
                            Text("\(app.stats.streakDays) дн поспіль")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.orange.opacity(0.13)))
                    }
                }

                // Hero 4-Metric Card (Average Speed, Words, Apps Used, Time Saved)
                SectionCard(padding: 20) {
                    HStack(alignment: .top, spacing: 18) {
                        statMetricColumn(
                            value: "\(app.stats.averageWPM) слів/хв",
                            label: "Середня швидкість",
                            detail: "Загалом наговорено: \(app.stats.formattedDuration)"
                        )
                        Divider().frame(height: 54).opacity(0.35)
                        statMetricColumn(
                            value: Fmt.number(app.stats.totalWords),
                            label: "Слів надиктовано",
                            detail: "\(Fmt.number(app.stats.recordingsCount)) записів"
                        )
                        Divider().frame(height: 54).opacity(0.35)
                        statMetricColumn(
                            value: "\(app.stats.appsUsedCount)",
                            label: "Програм використано",
                            detail: app.stats.peakHour.map { String(format: "Пік о %02d:00", $0) } ?? "Усі робочі вікна"
                        )
                        Divider().frame(height: 54).opacity(0.35)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(app.stats.formattedSavedTime)
                                .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundColor(Color(red: 0.24, green: 0.86, blue: 0.66))
                            HStack(spacing: 4) {
                                Text("Зекономлений час")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(.secondary)
                                Button(action: { app.uiShowBaselinePopover.toggle() }) {
                                    Image(systemName: "gearshape.fill")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                                .popover(isPresented: $app.uiShowBaselinePopover) {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text("Швидкість набору на клавіатурі")
                                            .font(.system(size: 12.5, weight: .semibold))
                                        Text("Порівнюємо твоє мовлення зі швидкістю ручного друку:")
                                            .font(.system(size: 11.5))
                                            .foregroundColor(.secondary)
                                        Stepper(
                                            value: Binding(
                                                get: { app.settings.typingBaselineWPM },
                                                set: { app.settings.typingBaselineWPM = $0; app.reloadStats() }
                                            ),
                                            in: 20...100,
                                            step: 5
                                        ) {
                                            Text("\(app.settings.typingBaselineWPM) слів/хв")
                                                .font(.system(size: 13, weight: .bold).monospacedDigit())
                                        }
                                    }
                                    .padding(14)
                                    .frame(width: 260)
                                }
                            }
                            Text("проти друку \(app.settings.typingBaselineWPM) слів/хв")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary.opacity(0.8))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // Charts Row: 14-day Activity + Top Apps
                HStack(alignment: .top, spacing: 16) {
                    SectionCard {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("Активність за 14 днів")
                                    .font(.system(size: 13.5, weight: .semibold))
                                Spacer()
                                Text("слів за день")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            DailyActivityChart(app: app, series: app.stats.dailySeries)
                                .frame(height: 132)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    SectionCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Топ програм")
                                .font(.system(size: 13.5, weight: .semibold))

                            if app.stats.topApps.isEmpty {
                                Text("Надиктуйте перший текст у будь-яке вікно — статистика програм з'явиться тут.")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .padding(.vertical, 18)
                            } else {
                                let maxWords = max(1, app.stats.topApps.first?.words ?? 1)
                                ForEach(app.stats.topApps.prefix(5)) { item in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(item.appName)
                                                .font(.system(size: 12.5, weight: .medium))
                                                .lineLimit(1)
                                            Spacer()
                                            Text("\(Fmt.number(item.words)) слів")
                                                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                                                .foregroundColor(.secondary)
                                        }
                                        GeometryReader { geo in
                                            ZStack(alignment: .leading) {
                                                Capsule()
                                                    .fill(Color.primary.opacity(0.08))
                                                Capsule()
                                                    .fill(
                                                        LinearGradient(
                                                            colors: [
                                                                Color(red: 0.22, green: 0.84, blue: 0.66),
                                                                Color(red: 0.34, green: 0.54, blue: 0.98)
                                                            ],
                                                            startPoint: .leading,
                                                            endPoint: .trailing
                                                        )
                                                    )
                                                    .frame(width: max(6, geo.size.width * CGFloat(item.words) / CGFloat(maxWords)))
                                            }
                                        }
                                        .frame(height: 5)
                                    }
                                }
                            }
                        }
                    }
                    .frame(width: 285)
                }

                // Quick Actions
                VStack(alignment: .leading, spacing: 10) {
                    Text("Швидкі дії")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)

                    SectionCard(padding: 6) {
                        VStack(spacing: 0) {
                            quickActionRow(
                                icon: "record.circle",
                                title: "Почати запис голосу",
                                subtitle: "Затисніть клавішу й говоріть, або коротко тапніть для запису без рук",
                                keys: app.settings.pushToTalkShortcut.displayTokens
                            ) {
                                app.toggleRecordingFromMenuOrButton()
                            }
                            Divider().padding(.leading, 44).opacity(0.25)
                            quickActionRow(
                                icon: "waveform.badge.plus",
                                title: "Розпізнати аудіо або відео файл…",
                                subtitle: "Перетворює будь-який запис, голосове чи відео на готовий текст у буфері",
                                keys: []
                            ) {
                                app.promptAndTranscribeFile()
                            }
                            Divider().padding(.leading, 44).opacity(0.25)
                            quickActionRow(
                                icon: "keyboard",
                                title: "Налаштувати клавіші та вікно запису",
                                subtitle: "Змініть гарячі клавіші, вигляд пігулки запису та автозапуск",
                                keys: app.settings.toggleShortcut.displayTokens
                            ) {
                                app.selectedSection = .configuration
                            }
                            Divider().padding(.leading, 44).opacity(0.25)
                            quickActionRow(
                                icon: "character.book.closed",
                                title: "Поповнити власний словник",
                                subtitle: "Додайте назви брендів, імена клієнтів та правила автозаміни",
                                keys: []
                            ) {
                                app.selectedSection = .vocabulary
                            }
                        }
                    }
                }
            }
            .padding(22)
        }
    }

    @ViewBuilder
    private var permissionsBannerIfNeeded: some View {
        if !app.hasMicPermission || !app.hasAccessibilityPermission {
            SectionCard(padding: 14) {
                HStack(spacing: 14) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.orange)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Щоб авто-вставка та гарячі клавіші працювали безвідмовно:")
                            .font(.system(size: 13, weight: .semibold))
                        Text(!app.hasMicPermission
                             ? "Дозвольте доступ до мікрофона для запису голосу."
                             : "Увімкніть «Шепіт» у розділі Доступність (Accessibility), щоб програма сама вставляла текст у будь-яке вікно.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if !app.hasMicPermission {
                        Button("Дозволити мікрофон") { app.requestMicPermission() }
                            .buttonStyle(.borderedProminent)
                    }
                    if !app.hasAccessibilityPermission {
                        Button("Увімкнути Доступність") { app.requestAccessibility() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    private func statMetricColumn(value: String, label: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(.secondary)
            Text(detail)
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.8))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func quickActionRow(
        icon: String,
        title: String,
        subtitle: String,
        keys: [String],
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
                HStack(spacing: 4) {
                    ForEach(keys, id: \.self) { k in
                        KeyCapBadge(label: k)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct DailyActivityChart: View {
    @ObservedObject var app: AppState
    let series: [DailyWordStat]

    var body: some View {
        let maxW = max(10, series.map(\.words).max() ?? 10)
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(series) { day in
                    let ratio = CGFloat(day.words) / CGFloat(maxW)
                    let isHovered = app.uiHoveredDayKey == day.dateKey
                    VStack(spacing: 4) {
                        Spacer(minLength: 0)
                        if isHovered && day.words > 0 {
                            Text("\(Fmt.number(day.words))")
                                .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                                .foregroundColor(.primary)
                                .fixedSize()
                        }
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(
                                day.words > 0
                                    ? LinearGradient(
                                        colors: [
                                            Color(red: 0.24, green: 0.86, blue: 0.68),
                                            Color(red: 0.28, green: 0.56, blue: 0.96)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                    : LinearGradient(
                                        colors: [Color.primary.opacity(0.08), Color.primary.opacity(0.08)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                            )
                            .frame(height: max(5, ratio * 94))
                    }
                    .frame(maxWidth: .infinity)
                    .onHover { inside in
                        app.uiHoveredDayKey = inside ? day.dateKey : nil
                    }
                    .help("\(day.label): \(Fmt.number(day.words)) слів (\(day.count) зап.)")
                }
            }
            HStack {
                if let first = series.first {
                    Text(first.label)
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if let last = series.last {
                    Text("Сьогодні (\(last.label))")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - 2. Modes View

struct ModesSectionView: View {
    @ObservedObject var app: AppState

    private var selectedIndex: Int {
        app.settings.modes.firstIndex(where: { $0.id == (app.uiEditingModeID.isEmpty ? app.settings.activeModeID : app.uiEditingModeID) }) ?? 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Режими диктування")
                            .font(.system(size: 15, weight: .bold))
                        Text("Перемикайте активний режим тут або комбінацією клавіш \(app.settings.changeModeShortcut.displayTokens.joined(separator: " ")).")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: addCustomMode) {
                        Label("Новий режим", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }

                // Mode Cards Selector
                HStack(spacing: 12) {
                    ForEach(app.settings.modes) { m in
                        let isActive = app.settings.activeModeID == m.id
                        let isEditing = app.settings.modes[selectedIndex].id == m.id
                        Button(action: {
                            app.settings.activeModeID = m.id
                            app.uiEditingModeID = m.id
                        }) {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Image(systemName: m.icon)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(isActive ? Color(red: 0.22, green: 0.86, blue: 0.66) : .secondary)
                                    Spacer()
                                    if isActive {
                                        Text("Активний")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(Color(red: 0.22, green: 0.86, blue: 0.66))
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(Color(red: 0.22, green: 0.86, blue: 0.66).opacity(0.15)))
                                    }
                                }
                                Text(m.name)
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .lineLimit(1)
                                Text(m.subtitle)
                                    .font(.system(size: 11.5))
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(13)
                            .frame(maxWidth: .infinity, minHeight: 94, alignment: .topLeading)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.primary.opacity(isEditing ? 0.08 : 0.04))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .strokeBorder(
                                                isEditing ? Color(red: 0.24, green: 0.84, blue: 0.66).opacity(0.75) : Color.primary.opacity(0.09),
                                                lineWidth: isEditing ? 1.5 : 1
                                            )
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Detailed Editor for Selected Mode (matches screenshot #7)
                if app.settings.modes.indices.contains(selectedIndex) {
                    let modeBinding = Binding<ShepitMode>(
                        get: { app.settings.modes[selectedIndex] },
                        set: { app.settings.modes[selectedIndex] = $0 }
                    )

                    SectionCard {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("Налаштування режиму «\(modeBinding.wrappedValue.name)»")
                                    .font(.system(size: 14, weight: .bold))
                                Spacer()
                                if app.settings.modes.count > 1 && !["voice-to-text", "clean-thought", "translate-en"].contains(modeBinding.wrappedValue.id) {
                                    Button(role: .destructive) {
                                        let idToRemove = modeBinding.wrappedValue.id
                                        app.settings.modes.removeAll { $0.id == idToRemove }
                                        if app.settings.activeModeID == idToRemove {
                                            app.settings.activeModeID = app.settings.modes.first?.id ?? "voice-to-text"
                                        }
                                        app.uiEditingModeID = app.settings.activeModeID
                                    } label: {
                                        Label("Видалити", systemImage: "trash")
                                            .font(.system(size: 12))
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }

                            HStack {
                                Text("Назва режиму")
                                    .frame(width: 190, alignment: .leading)
                                TextField("Назва", text: modeBinding.name)
                                    .textFieldStyle(.roundedBorder)
                            }

                            Divider().opacity(0.25)

                            HStack {
                                Text("Мова мовлення")
                                    .frame(width: 190, alignment: .leading)
                                Picker("", selection: modeBinding.language) {
                                    Text("Автоматично (Укр / Англ / Європа)").tag("auto")
                                    Text("Українська").tag("uk")
                                    Text("English").tag("en")
                                    Text("Polski").tag("pl")
                                    Text("Deutsch").tag("de")
                                    Text("Français").tag("fr")
                                    Text("Español").tag("es")
                                }
                                .frame(maxWidth: 320)
                                Spacer()
                            }

                            HStack {
                                Text("Движок голосу")
                                    .frame(width: 190, alignment: .leading)
                                Picker("", selection: modeBinding.engine) {
                                    ForEach(EngineChoice.allCases) { eng in
                                        Text(eng.title).tag(eng)
                                    }
                                }
                                .frame(maxWidth: 320)
                                Spacer()
                            }

                            Toggle("Живий попередній перегляд тексту під час запису (Realtime)", isOn: modeBinding.realtimePreview)

                            Divider().opacity(0.25)

                            HStack {
                                Text("Постобробка ШІ")
                                    .frame(width: 190, alignment: .leading)
                                Picker("", selection: modeBinding.llmMode) {
                                    Text("Вимкнено (прямий голос у текст)").tag("")
                                    Text("Чиста думка (прибрати обмовки й «ну»)").tag("clean")
                                    Text("Переклад англійською").tag("translate_en")
                                    Text("Власна інструкція ШІ…").tag("custom")
                                }
                                .frame(maxWidth: 320)
                                Spacer()
                            }

                            if modeBinding.wrappedValue.llmMode == "custom" {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Інструкція для ШІ (виконується через Groq / Gemini):")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                    TextEditor(text: modeBinding.customPrompt)
                                        .font(.system(size: 12.5))
                                        .frame(height: 68)
                                        .padding(6)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                                }
                            }

                            Divider().opacity(0.25)

                            Toggle("Починати речення з великої літери (Autocapitalize)", isOn: modeBinding.autocapitalize)
                            Toggle("Автоматично вставляти текст в активне поле вводу (Auto paste)", isOn: modeBinding.autoPaste)
                        }
                    }
                }
            }
            .padding(22)
        }
    }

    private func addCustomMode() {
        let newID = "custom-\(UUID().uuidString.prefix(6))"
        let mode = ShepitMode(
            id: newID,
            name: "Мій режим",
            subtitle: "Власні параметри розпізнавання й оформлення",
            icon: "bolt.fill",
            language: "auto",
            engine: .hybrid,
            realtimePreview: true,
            llmMode: "custom",
            customPrompt: "Оформи надиктований текст короткими чіткими пунктами українською мовою без води.",
            autocapitalize: true,
            autoPaste: true,
            activationBundleIDs: []
        )
        app.settings.modes.append(mode)
        app.settings.activeModeID = newID
        app.uiEditingModeID = newID
    }
}

// MARK: - 3. Vocabulary & Replacements View

struct VocabularySectionView: View {
    @ObservedObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Custom Vocabulary Words
                SectionCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Власні слова, імена та бренди")
                            .font(.system(size: 14.5, weight: .bold))
                        Text("Підказують розпізнавачу правильне написання спеціалізованих термінів, клієнтів і англійських назв.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        HStack(spacing: 8) {
                            TextField("Додати слово або бренд (напр. GitHub, DaVinci Resolve, Figma)…", text: $app.uiNewVocabWord)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(addVocabWord)
                            Button("Додати", action: addVocabWord)
                                .buttonStyle(.borderedProminent)
                                .disabled(app.uiNewVocabWord.trimmingCharacters(in: .whitespaces).isEmpty)
                        }

                        FlowWrapChips(items: app.settings.vocabulary) { word in
                            app.settings.vocabulary.removeAll { $0 == word }
                        }
                        .padding(.top, 4)
                    }
                }

                // Auto-replacements
                SectionCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Автоматичні заміни")
                            .font(.system(size: 14.5, weight: .bold))
                        Text("Миттєво виправляють типові варіанти вимови на точне написання ще до вставки тексту.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        HStack(spacing: 8) {
                            TextField("Що почуто (напр. гітхаб)", text: $app.uiNewReplFrom)
                                .textFieldStyle(.roundedBorder)
                            Image(systemName: "arrow.right")
                                .foregroundColor(.secondary)
                            TextField("На що замінити (напр. GitHub)", text: $app.uiNewReplTo)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(addReplacement)
                            Button("Додати", action: addReplacement)
                                .buttonStyle(.borderedProminent)
                                .disabled(app.uiNewReplFrom.trimmingCharacters(in: .whitespaces).isEmpty)
                        }

                        VStack(spacing: 6) {
                            ForEach($app.settings.replacements) { $rule in
                                HStack(spacing: 10) {
                                    Toggle("", isOn: $rule.enabled)
                                        .labelsHidden()
                                    Text(rule.from)
                                        .font(.system(size: 13))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Text(rule.to)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(Color(red: 0.24, green: 0.86, blue: 0.66))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Button(action: {
                                        let id = rule.id
                                        app.settings.replacements.removeAll { $0.id == id }
                                    }) {
                                        Image(systemName: "trash")
                                            .font(.system(size: 12))
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                            }
                        }
                    }
                }
            }
            .padding(22)
        }
    }

    private func addVocabWord() {
        let trimmed = app.uiNewVocabWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !app.settings.vocabulary.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            app.settings.vocabulary.append(trimmed)
        }
        app.uiNewVocabWord = ""
    }

    private func addReplacement() {
        let src = app.uiNewReplFrom.trimmingCharacters(in: .whitespacesAndNewlines)
        let dst = app.uiNewReplTo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !src.isEmpty else { return }
        app.settings.replacements.insert(ReplacementRule(from: src, to: dst, enabled: true), at: 0)
        app.uiNewReplFrom = ""
        app.uiNewReplTo = ""
    }
}

struct FlowWrapChips: View {
    let items: [String]
    let onRemove: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                HStack(spacing: 6) {
                    Text(item)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Button(action: { onRemove(item) }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                )
            }
        }
    }
}
