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
            // Grouping by surface and air, not by outlines
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusL, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
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

                UpdateBannerView(updater: app.updater)
                GoneModelsBannerView(gone: app.workerStatus.goneModels)

                if let banner = app.statusBannerMessage {
                    HStack(spacing: 10) {
                        Image(systemName: bannerIsError(banner) ? "exclamationmark.triangle.fill" : "info.circle.fill")
                            .foregroundColor(bannerIsError(banner) ? Theme.danger : Theme.accent)
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
                    .background((bannerIsError(banner) ? Theme.danger : Theme.accent).opacity(0.10))
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
                        .fill(Theme.accent)
                        .frame(width: 30, height: 30)
                    HStack(alignment: .center, spacing: 2) {
                        ForEach([0.38, 1.0, 1.0, 1.0, 0.38], id: \.self.hashValue) { share in
                            Capsule().fill(Color.black.opacity(0.78)).frame(width: 2.4, height: 15 * CGFloat(share))
                        }
                    }
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
                    Text(networkStatusLine)
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
            .onTapGesture {
                app.selectedSection = .models
            }
        }
        .background(Color.primary.opacity(0.02))
    }

    private var networkStatusLine: String {
        if !app.isOnline { return "Немає мережі · працює локально" }
        return app.workerStatus.hasGroqKey ? "Гібрид із Groq активний" : "Локальний офлайн-режим"
    }

    private var engineDotColor: Color {
        if !app.workerStatus.lastError.isEmpty { return Theme.warning }
        if !app.isOnline { return Theme.offline }
        if app.workerStatus.isModelLoaded { return Theme.accent }
        return .yellow
    }

    private func bannerIsError(_ text: String) -> Bool {
        text.hasPrefix("Помилка") || text.contains("недоступний") || text.contains("очищено")
    }

    private func sidebarButton(_ sec: AppSection) -> some View {
        let isSelected = app.selectedSection == sec
        let isHovered = app.uiHoveredSection == sec
        let index = (AppSection.allCases.firstIndex(of: sec) ?? 0) + 1
        return Button(action: { app.selectedSection = sec }) {
            HStack(spacing: 11) {
                // One accent for the whole app: the icon lights up only for the current section
                Image(systemName: sec.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isSelected ? Theme.accent : .secondary)
                    .frame(width: 22, height: 22)
                Text(sec.title)
                    .font(Theme.font(13.5, strong: isSelected))
                    .foregroundColor(isSelected ? .primary : .primary.opacity(0.82))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusS + 2, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.10 : (isHovered ? 0.05 : 0)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .onHover { inside in
            if inside { app.uiHoveredSection = sec } else if app.uiHoveredSection == sec { app.uiHoveredSection = nil }
        }
        .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
        .help("\(sec.title)  ⌘\(index)")
        .accessibilityLabel(sec.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
                        .fill(isRecording ? Color.red : Theme.accent)
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
                            detail: "Наговорено \(app.stats.formattedDuration)"
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
                            label: "Програм",
                            detail: app.stats.peakHour.map { String(format: "Пік о %02d:00", $0) } ?? "Усі робочі вікна"
                        )
                        Divider().frame(height: 54).opacity(0.35)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(app.stats.formattedSavedTime)
                                .font(Theme.digits(22))
                                .foregroundColor(Theme.accent)
                                .contentTransition(.numericText())
                                .animation(Theme.spring, value: app.stats.formattedSavedTime)
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
                                                    .fill(Theme.accent.opacity(0.85))
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
                .font(Theme.digits(22))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentTransition(.numericText())
                .animation(Theme.spring, value: value)
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
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous)
                    .fill(Color.primary.opacity(app.uiHoveredQuickAction == title ? 0.06 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { app.uiHoveredQuickAction = title } else if app.uiHoveredQuickAction == title { app.uiHoveredQuickAction = nil }
        }
    }
}

struct DailyActivityChart: View {
    @ObservedObject var app: AppState
    let series: [DailyWordStat]

    private let plotHeight: CGFloat = 92

    var body: some View {
        let maxW = max(10, series.map(\.words).max() ?? 10)
        VStack(spacing: 5) {
            ZStack(alignment: .topLeading) {
                // Scale reference: the busiest day sets the top line
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Text("\(Fmt.number(maxW))")
                            .font(Theme.digits(9.5, strong: false))
                            .foregroundColor(.secondary.opacity(0.8))
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: plotHeight + 16)

                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(series) { day in
                        let ratio = CGFloat(day.words) / CGFloat(maxW)
                        let isHovered = app.uiHoveredDayKey == day.dateKey
                        let grown = app.uiChartAppeared || Theme.reduceMotion
                        VStack(spacing: 3) {
                            Spacer(minLength: 0)
                            Text(isHovered && day.words > 0 ? Fmt.number(day.words) : " ")
                                .font(Theme.digits(9.5))
                                .foregroundColor(.primary)
                                .fixedSize()
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(day.words > 0
                                      ? Theme.accent.opacity(isHovered ? 1 : 0.82)
                                      : Color.primary.opacity(0.08))
                                .frame(height: max(4, (grown ? ratio : 0) * plotHeight))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: plotHeight + 16, alignment: .bottom)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            app.uiHoveredDayKey = inside ? day.dateKey : nil
                        }
                        .help("\(day.label): \(Fmt.number(day.words)) слів (\(day.count) зап.)")
                        .accessibilityLabel("\(day.label): \(day.words) слів")
                    }
                }
            }
            // Day-of-month under every bar, so a bar can be read without hovering
            HStack(alignment: .top, spacing: 6) {
                ForEach(series) { day in
                    Text(day.label.split(separator: " ").first.map(String.init) ?? "")
                        .font(Theme.digits(9.5, strong: false))
                        .foregroundColor(day.dateKey == series.last?.dateKey ? .primary : .secondary.opacity(0.8))
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { app.uiChartAppeared = true }
        }
        .onDisappear { app.uiChartAppeared = false }
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

                // Mode Cards Selector — a grid, so six modes keep readable names instead of squeezing into one row
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
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
                                        .foregroundColor(isActive ? Theme.accent : .secondary)
                                    Spacer()
                                    if isActive {
                                        Text("Активний")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(Theme.accent)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(Theme.accent.opacity(0.15)))
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
                                RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous)
                                    .fill(Color.primary.opacity(isEditing ? 0.08 : 0.045))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous)
                                            .strokeBorder(isEditing ? Theme.accent.opacity(0.75) : Color.clear, lineWidth: 1.5)
                                    )
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Режим \(m.name)\(isActive ? ", активний" : "")")
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
                                    // Two-step delete: the first click only arms the button for a few seconds
                                    let armed = app.uiModePendingDeleteID == modeBinding.wrappedValue.id
                                    Button(role: .destructive) {
                                        let idToRemove = modeBinding.wrappedValue.id
                                        guard armed else {
                                            app.uiModePendingDeleteID = idToRemove
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                                                if app.uiModePendingDeleteID == idToRemove { app.uiModePendingDeleteID = nil }
                                            }
                                            return
                                        }
                                        app.uiModePendingDeleteID = nil
                                        app.settings.modes.removeAll { $0.id == idToRemove }
                                        if app.settings.activeModeID == idToRemove {
                                            app.settings.activeModeID = app.settings.modes.first?.id ?? "voice-to-text"
                                        }
                                        app.uiEditingModeID = app.settings.activeModeID
                                    } label: {
                                        Label(armed ? "Точно видалити?" : "Видалити", systemImage: "trash")
                                            .font(.system(size: 12, weight: armed ? .semibold : .regular))
                                            .foregroundColor(armed ? Theme.danger : nil)
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
                if !app.vocabSuggestions.isEmpty {
                    SectionCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("«Шепіт» помітив повторювані виправлення")
                                .font(.system(size: 14.5, weight: .bold))
                            Text("Ці слова онлайн-перевірка щоразу виправляє після локальної моделі. Додайте заміну — і вони будуть правильними навіть без інтернету.")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            ForEach(app.vocabSuggestions) { suggestion in
                                HStack(spacing: 10) {
                                    Text("«\(suggestion.from)» → «\(suggestion.to)»")
                                        .font(Theme.font(13, strong: true))
                                    Text("\(suggestion.count) рази")
                                        .font(Theme.digits(11, strong: false))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Button("Додати заміну") { app.acceptVocabSuggestion(suggestion) }
                                        .buttonStyle(.borderedProminent)
                                        .tint(Theme.accent)
                                        .controlSize(.small)
                                    Button("Не треба") { app.dismissVocabSuggestion(suggestion) }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                }

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
                                        .foregroundColor(Theme.accent)
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


// MARK: - Update and retired-model banners

/// "Є оновлення" with a one-click install; silent when the app is up to date.
struct UpdateBannerView: View {
    @ObservedObject var updater: Updater

    var body: some View {
        if let release = updater.available {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Є оновлення: Шепіт \(release.version)")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Що нового") { NSWorkspace.shared.open(release.page) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                Button(action: { updater.install() }) {
                    Text(isInstalling ? "Оновлюю…" : "Оновити")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isInstalling)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 9)
            .background(Theme.accent.opacity(0.10))
        }
    }

    private var isInstalling: Bool {
        if case .installing = updater.phase { return true }
        return false
    }

    private var subtitle: String {
        switch updater.phase {
        case .installing(let text): return text
        case .failed(let text): return "Не вийшло: \(text). Спробуй ще раз."
        default: return "Зараз у тебе \(Updater.current). Оновлення займе кілька секунд, налаштування й історія лишаються."
        }
    }
}

/// A provider retired a model Шепіт relies on: say so instead of failing silently.
struct GoneModelsBannerView: View {
    let gone: [String: String]

    var body: some View {
        if !gone.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(Theme.warning)
                Text(text)
                    .font(.system(size: 12.5, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 9)
            .background(Theme.warning.opacity(0.12))
        }
    }

    private var text: String {
        let list = gone.sorted { $0.key < $1.key }.map { "\($0.value) · \($0.key)" }.joined(separator: ", ")
        return "Провайдер більше не приймає модель \(list). Шепіт працює на запасній, але це знак, що потрібне оновлення — перевір «Є оновлення» або напиши в чат."
    }
}
