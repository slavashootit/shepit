import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 4. Configuration (Settings) View

struct ConfigurationSectionView: View {
    @ObservedObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Appearance & Recording Window Style (matches screenshot #3)
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("Зовнішній вигляд")
                    SectionCard {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Text("Тема інтерфейсу")
                                    .font(.system(size: 13.5, weight: .medium))
                                Spacer()
                                Picker("", selection: $app.settings.theme) {
                                    ForEach(AppTheme.allCases) { t in
                                        Text(t.title).tag(t)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 240)
                            }

                            Divider().opacity(0.25)

                            VStack(alignment: .leading, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Вікно індикатора запису")
                                        .font(.system(size: 13.5, weight: .medium))
                                    Text("Плаває поверх вікон і ніколи не перехоплює фокус клавіатури")
                                        .font(.system(size: 11.5))
                                        .foregroundColor(.secondary)
                                }
                                // Own row: four equal cards never squeeze their captions
                                HStack(spacing: 12) {
                                    ForEach(RecordingWindowStyle.allCases) { st in
                                        hudStyleCard(st)
                                    }
                                }
                            }
                        }
                    }
                }

                // Keyboard Shortcuts
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("Гарячі клавіші")
                    SectionCard {
                        VStack(alignment: .leading, spacing: 14) {
                            shortcutRow(
                                id: "ptt",
                                title: "Утримувати для запису (Push to Talk)",
                                subtitle: app.settings.pushToTalkTapToggle
                                    ? "Тримайте — запис; короткий тап — запис без рук до повторного натискання"
                                    : "Тримайте клавішу, поки говорите, і відпустіть для вставки",
                                binding: app.settings.pushToTalkShortcut,
                                onReset: { app.settings.pushToTalkShortcut = .rightOptionPTT }
                            )

                            Toggle("Короткий тап вмикає фіксацію запису «без рук» (до повторного тапу)", isOn: $app.settings.pushToTalkTapToggle)
                                .font(.system(size: 12.5))
                                .padding(.leading, 4)

                            Toggle("Реагувати на обидві клавіші Option (і праву, і ліву)", isOn: $app.settings.allowAnyOptionForPTT)
                                .font(.system(size: 12.5))
                                .padding(.leading, 4)

                            Divider().opacity(0.25)

                            shortcutRow(
                                id: "toggle",
                                title: "Перемкнути запис (Старт / Стоп)",
                                subtitle: "Запускає або завершує запис без утримання клавіші",
                                binding: app.settings.toggleShortcut,
                                onReset: { app.settings.toggleShortcut = .optionSpaceToggle }
                            )

                            Divider().opacity(0.25)

                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Скасувати запис")
                                        .font(.system(size: 13.5, weight: .medium))
                                    Text("Активна лише під час запису — в інший час Esc працює звичайно")
                                        .font(.system(size: 11.5))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                KeyCapBadge(label: "esc")
                            }

                            Divider().opacity(0.25)

                            shortcutRow(
                                id: "mode",
                                title: "Перемкнути режим",
                                subtitle: "Швидко перемикає між режимами «Голос у текст», «Чиста думка», «Переклад»",
                                binding: app.settings.changeModeShortcut,
                                onReset: { app.settings.changeModeShortcut = .optionShiftKMode }
                            )
                        }
                    }
                }

                // Application & Storage
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("Застосунок і дозволи")
                    SectionCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Toggle(
                                "Запускати «Шепіт» автоматично під час входу в систему",
                                isOn: Binding(
                                    get: { app.launchOnLogin },
                                    set: { app.setLaunchOnLogin($0) }
                                )
                            )

                            Divider().opacity(0.25)

                            Toggle("Лишати останній розпізнаний текст у буфері обміну (страховка ⌘V)", isOn: $app.settings.keepClipboardCopy)

                            if !app.settings.keepClipboardCopy {
                                Toggle("Відновлювати попередній вміст буфера обміну після вставки", isOn: $app.settings.restorePreviousClipboard)
                                    .font(.system(size: 12.5))
                                    .foregroundColor(.secondary)
                            }

                            Divider().opacity(0.25)

                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Зберігати аудіозаписи для прослуховування")
                                        .font(.system(size: 13.5, weight: .medium))
                                    Text("Стискаються в компактний M4A; текстова історія та статистика зберігаються завжди")
                                        .font(.system(size: 11.5))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Picker("", selection: $app.settings.audioRetention) {
                                    ForEach(AudioRetention.allCases) { r in
                                        Text(r.title).tag(r)
                                    }
                                }
                                .frame(width: 190)
                                .onChange(of: app.settings.audioRetention) { _, newVal in
                                    app.storage.pruneExpiredAudio(retention: newVal)
                                }
                            }

                            Divider().opacity(0.25)

                            // System permissions live indicators
                            HStack(spacing: 16) {
                                permissionPill(
                                    title: "Мікрофон",
                                    granted: app.hasMicPermission,
                                    action: { app.requestMicPermission() }
                                )
                                permissionPill(
                                    title: "Доступність (авто-вставка ⌘V)",
                                    granted: app.hasAccessibilityPermission,
                                    action: { app.requestAccessibility() }
                                )
                                Spacer()
                            }
                        }
                    }
                }
                // Dictation & AI enhancements
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("Диктування та ШІ")
                    SectionCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Toggle(isOn: $app.settings.enableVoiceCommands) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Голосові команди під час диктування")
                                        .font(.system(size: 13.5, weight: .medium))
                                    Text("«Новий рядок», «крапка», «скасуй це», «в лапках …» — виконуються на льоту")
                                        .font(.system(size: 11.5))
                                        .foregroundColor(.secondary)
                                }
                            }

                            Divider().opacity(0.25)

                            Toggle(isOn: $app.settings.enableSmartFormatting) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Розумне форматування чисел і валют")
                                        .font(.system(size: 13.5, weight: .medium))
                                    Text("«25 тисяч гривень» → 25 000 ₴, «3 відсотки» → 3% тощо")
                                        .font(.system(size: 11.5))
                                        .foregroundColor(.secondary)
                                }
                            }

                            Divider().opacity(0.25)

                            Toggle(isOn: $app.settings.contextAwareness) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Зчитувати контекст активного вікна")
                                        .font(.system(size: 13.5, weight: .medium))
                                    Text("ШІ-режими враховують виділений текст і назву застосунку для точніших результатів")
                                        .font(.system(size: 11.5))
                                        .foregroundColor(.secondary)
                                }
                            }

                            Divider().opacity(0.25)

                            Toggle(isOn: Binding(
                                get: { app.settings.autoStopOnSilence ?? true },
                                set: { app.settings.autoStopOnSilence = $0 }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Зупиняти запис «без рук» після 20 с тиші")
                                        .font(.system(size: 13.5, weight: .medium))
                                    Text("Забутий запис сам завершиться й вставить текст, а не писатиме годину")
                                        .font(.system(size: 11.5))
                                        .foregroundColor(.secondary)
                                }
                            }

                            Divider().opacity(0.25)

                            Toggle(isOn: Binding(
                                get: { app.settings.autoRedoAfterOffline ?? true },
                                set: { app.settings.autoRedoAfterOffline = $0 }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Доробляти офлайн-записи, коли з'явиться інтернет")
                                        .font(.system(size: 13.5, weight: .medium))
                                    Text("Онлайн-перевірка й ШІ-обробка доганяють самі; оновлюється лише Історія, нічого не вставляється повторно")
                                        .font(.system(size: 11.5))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .padding(22)
        }
    }

    private func hudStyleCard(_ style: RecordingWindowStyle) -> some View {
        let selected = app.settings.recordingWindowStyle == style
        return Button(action: { app.settings.recordingWindowStyle = style }) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.black.opacity(0.45))
                        .frame(height: 46)
                        .frame(maxWidth: .infinity)
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(
                                    selected ? Theme.accent : Color.primary.opacity(0.14),
                                    lineWidth: selected ? 1.8 : 1
                                )
                        )
                    switch style {
                    case .classic:
                        HStack(spacing: 2) {
                            ForEach([0.3, 0.7, 1.0, 0.5, 0.8, 0.4, 0.9, 0.4], id: \.self) { h in
                                Capsule().fill(Color.white.opacity(0.85)).frame(width: 2, height: CGFloat(h * 16))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                    case .mini:
                        HStack(spacing: 2) {
                            ForEach([0.4, 0.9, 0.6, 0.8, 0.4], id: \.self) { h in
                                Capsule().fill(Color.white.opacity(0.85)).frame(width: 2, height: CGFloat(h * 12))
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                    case .notch:
                        // Notch-style preview: centered pill with bars and glow dot
                        HStack(spacing: 2) {
                            Circle().fill(Theme.accent).frame(width: 4, height: 4)
                            ForEach([0.5, 0.8, 0.5], id: \.self) { h in
                                Capsule().fill(Color.white.opacity(0.85)).frame(width: 2, height: CGFloat(h * 10))
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                    case .none:
                        Image(systemName: "eye.slash")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                }
                Text(style.title)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Вигляд індикатора: \(style.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func shortcutRow(
        id: String,
        title: String,
        subtitle: String,
        binding: ShortcutBinding,
        onReset: @escaping () -> Void
    ) -> some View {
        let isCapturing = app.capturingShortcutTarget == id
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
            }
            Spacer()

            Button(action: onReset) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Повернути типову комбінацію")

            Button(action: {
                if isCapturing {
                    app.endCapturingShortcut()
                } else {
                    app.beginCapturingShortcut(for: id)
                }
            }) {
                if isCapturing {
                    Text("Натисніть клавішу…")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(Theme.accent, lineWidth: 1.2)
                        )
                } else {
                    HStack(spacing: 4) {
                        ForEach(binding.displayTokens, id: \.self) { tok in
                            KeyCapBadge(label: tok)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func permissionPill(title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(granted ? Theme.accent : Color.orange)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(granted ? "Активно" : "Надати")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(granted ? .secondary : .orange)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundColor(.secondary)
    }
}

// MARK: - 5. Sound Settings View (matches screenshot #4)

struct SoundSectionView: View {
    @ObservedObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Запис і мікрофон")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.secondary)

                    SectionCard {
                        VStack(alignment: .leading, spacing: 15) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Пристрій запису")
                                        .font(.system(size: 13.5, weight: .medium))
                                    Text("Автоматично перепідключається після сну Мака або зміни гарнітури")
                                        .font(.system(size: 11.5))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Picker("", selection: $app.settings.selectedMicUID) {
                                    Text("Системний типовий").tag("")
                                    ForEach(app.inputDevices) { dev in
                                        Text(dev.isDefault ? "\(dev.name) (Типовий)" : dev.name).tag(dev.uid)
                                    }
                                }
                                .frame(width: 260)
                                Button(action: { app.refreshDevices() }) {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .buttonStyle(.borderless)
                                .help("Оновити список мікрофонів")
                            }

                            Divider().opacity(0.25)

                            Toggle(isOn: $app.settings.autoGain) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Автоматично підсилювати тихий голос")
                                        .font(.system(size: 13.5, weight: .medium))
                                    Text("Допомагає розпізнавати тиху мову або шепіт на відстані від мікрофона")
                                        .font(.system(size: 11.5))
                                        .foregroundColor(.secondary)
                                }
                            }

                            Divider().opacity(0.25)

                            Toggle(isOn: $app.settings.silenceRemoval) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Прибирати тишу на початку та в кінці запису")
                                        .font(.system(size: 13.5, weight: .medium))
                                    Text("Прискорює обробку й захищає від помилкових слів під час пауз")
                                        .font(.system(size: 11.5))
                                        .foregroundColor(.secondary)
                                }
                            }

                            Divider().opacity(0.25)

                            Toggle(isOn: $app.settings.dynamicNormalization) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Динамічна нормалізація гучності")
                                        .font(.system(size: 13.5, weight: .medium))
                                    Text("Вирівнює перепади гучності протягом довгої репліки")
                                        .font(.system(size: 11.5))
                                        .foregroundColor(.secondary)
                                }
                            }

                            Divider().opacity(0.25)

                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Відтворення медіа під час запису")
                                        .font(.system(size: 13.5, weight: .medium))
                                    Text("Ставить музику чи YouTube на паузу під час диктування й відновлює після")
                                        .font(.system(size: 11.5))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Picker("", selection: $app.settings.playbackBehavior) {
                                    ForEach(PlaybackBehavior.allCases) { b in
                                        Text(b.title).tag(b)
                                    }
                                }
                                .frame(width: 165)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Звукові ефекти")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.secondary)

                    SectionCard {
                        VStack(alignment: .leading, spacing: 15) {
                            HStack {
                                Text("Звуковий відгук старту й завершення")
                                    .font(.system(size: 13.5, weight: .medium))
                                Spacer()
                                Picker("", selection: $app.settings.soundEffectStyle) {
                                    ForEach(SoundEffectStyle.allCases) { s in
                                        Text(s.title).tag(s)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 250)
                                .onChange(of: app.settings.soundEffectStyle) { _, newStyle in
                                    SoundFX.shared.play(.start, style: newStyle, volume: app.settings.soundVolume)
                                }
                            }

                            Divider().opacity(0.25)

                            HStack(spacing: 12) {
                                Text("Гучність ефектів")
                                    .font(.system(size: 13.5, weight: .medium))
                                Spacer()
                                Image(systemName: "speaker.fill")
                                    .foregroundColor(.secondary)
                                Slider(value: $app.settings.soundVolume, in: 0.05...1.0)
                                    .frame(width: 240)
                                Image(systemName: "speaker.wave.3.fill")
                                    .foregroundColor(.secondary)
                                Button("Тест") {
                                    SoundFX.shared.play(.start, style: app.settings.soundEffectStyle, volume: app.settings.soundVolume)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
            .padding(22)
        }
    }
}

// MARK: - 6. Models & Engines View

struct ModelsSectionView: View {
    @ObservedObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Движки розпізнавання та ШІ")
                            .font(.system(size: 15, weight: .bold))
                        Text("Локальна модель працює прямо на Apple GPU процесорів Apple Silicon (M1–M4) без підписок і затримок.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: { app.engine.restartWorker() }) {
                        Label("Перезапустити MLX-воркер", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(app.isInstallingModel)
                }

                // Engine 1: Local Parakeet v3 MLX
                SectionCard {
                    HStack(alignment: .top, spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Theme.accent.opacity(0.18))
                                .frame(width: 42, height: 42)
                            Image(systemName: "cpu.fill")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundColor(Theme.accent)
                        }

                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 8) {
                                Text("NVIDIA Parakeet TDT 0.6B v3 (Apple MLX)")
                                    .font(.system(size: 14.5, weight: .bold))
                                statusBadge(
                                    ok: app.workerStatus.isModelLoaded,
                                    okText: "Гаряча в пам'яті",
                                    waitText: app.workerStatus.modelExists ? "Завантаження…" : "Не встановлено"
                                )
                            }
                            Text("Основна мультимовна модель (25 мов включно з українською та англійською). Працює повністю офлайн (~0,25 с на фразу) і зберігається у ~/.local/share/models/parakeet-tdt-0.6b-v3.")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)

                            if app.isInstallingModel {
                                VStack(alignment: .leading, spacing: 6) {
                                    ProgressView(value: app.modelInstallProgress, total: 1.0)
                                        .progressViewStyle(.linear)
                                    Text(app.modelInstallStage)
                                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                                        .foregroundColor(Theme.accent)
                                }
                                .padding(.top, 4)
                            } else if !app.workerStatus.modelExists {
                                HStack(spacing: 10) {
                                    Button(action: { app.installLocalParakeetModel() }) {
                                        Label("Встановити локальну модель (~2,34 ГБ)", systemImage: "arrow.down.circle.fill")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(Color(red: 0.18, green: 0.74, blue: 0.54))

                                    Text("Встановлюється один раз автоматично без термінала")
                                        .font(.system(size: 11.5))
                                        .foregroundColor(.secondary)
                                }
                                .padding(.top, 4)
                            } else {
                                HStack(spacing: 18) {
                                    Label(
                                        String(format: "Пам'ять GPU: %.0f МБ", app.workerStatus.activeMemoryMB),
                                        systemImage: "memorychip"
                                    )
                                    Label(
                                        app.workerStatus.loadTimeMs > 0 ? "Старт: \(app.workerStatus.loadTimeMs) мс" : "Офлайн 100%",
                                        systemImage: "bolt.fill"
                                    )
                                }
                                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                                .foregroundColor(.secondary)
                                .padding(.top, 2)
                            }
                        }
                        Spacer()
                    }
                }

                // Engine 2: Groq Whisper v3 Hybrid
                SectionCard {
                    HStack(alignment: .top, spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(red: 0.98, green: 0.48, blue: 0.24).opacity(0.18))
                                .frame(width: 42, height: 42)
                            Image(systemName: "bolt.horizontal.icloud.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(Color(red: 0.98, green: 0.48, blue: 0.24))
                        }

                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 8) {
                                Text("Groq Whisper Large v3 (Автопідстраховка брендів і складних місць)")
                                    .font(.system(size: 14.5, weight: .bold))
                                statusBadge(
                                    ok: app.workerStatus.hasGroqKey,
                                    okText: "Ключ підключено",
                                    waitText: "Необов'язково"
                                )
                                Spacer()
                                if app.workerStatus.hasGroqKey && !app.uiShowGroqKeyEditor {
                                    Button("Змінити ключ") {
                                        app.uiShowGroqKeyEditor = true
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                            Text("У гібридному режимі вмикається лише тоді, коли Parakeet сумнівається у слові, змішує абетки або чує іноземну назву бренда. Без інтернету чи без ключа миттєво працює офлайн-модель Parakeet.")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)

                            if !app.workerStatus.hasGroqKey || app.uiShowGroqKeyEditor {
                                HStack(spacing: 8) {
                                    SecureField("Вставте безкоштовний ключ Groq (gsk_…)", text: $app.uiGroqKeyInput)
                                        .textFieldStyle(.roundedBorder)
                                    Button("Зберегти") {
                                        app.saveAPIKey(name: "groq", rawValue: app.uiGroqKeyInput)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(app.uiGroqKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                                    Button("Отримати ключ →") {
                                        if let u = URL(string: "https://console.groq.com/keys") {
                                            NSWorkspace.shared.open(u)
                                        }
                                    }
                                    .buttonStyle(.bordered)

                                    if app.uiShowGroqKeyEditor {
                                        Button("Скасувати") {
                                            app.uiShowGroqKeyEditor = false
                                            app.uiGroqKeyInput = ""
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.top, 4)
                            }
                        }
                    }
                }

                // Engine 3: LLM Post-processing
                SectionCard {
                    HStack(alignment: .top, spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(red: 0.40, green: 0.54, blue: 0.98).opacity(0.18))
                                .frame(width: 42, height: 42)
                            Image(systemName: "sparkles")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(Color(red: 0.40, green: 0.54, blue: 0.98))
                        }

                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 8) {
                                Text("ШІ-обробка: Qwen 3.8 (Groq) + Gemini Flash Lite")
                                    .font(.system(size: 14.5, weight: .bold))
                                statusBadge(
                                    ok: app.workerStatus.hasGroqKey || app.workerStatus.hasGeminiKey,
                                    okText: "Готово",
                                    waitText: "Потрібен ключ Groq або Gemini"
                                )
                                Spacer()
                                if !app.uiShowGeminiKeyEditor {
                                    Button(app.workerStatus.hasGeminiKey ? "Змінити Gemini ключ" : "Додати Gemini ключ") {
                                        app.uiShowGeminiKeyEditor = true
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                            Text("Використовуються лише у спеціальних режимах «Чиста думка», «Переклад англійською» та власних ШІ-інструкціях. У звичайному режимі «Голос у текст» постобробка вимкнена для миттєвої вставки.")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)

                            if app.uiShowGeminiKeyEditor {
                                HStack(spacing: 8) {
                                    SecureField("Ключ Google Gemini API (AIza…)", text: $app.uiGeminiKeyInput)
                                        .textFieldStyle(.roundedBorder)
                                    Button("Зберегти") {
                                        app.saveAPIKey(name: "gemini", rawValue: app.uiGeminiKeyInput)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(app.uiGeminiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                                    Button("Google AI Studio →") {
                                        if let u = URL(string: "https://aistudio.google.com/apikey") {
                                            NSWorkspace.shared.open(u)
                                        }
                                    }
                                    .buttonStyle(.bordered)

                                    Button("Скасувати") {
                                        app.uiShowGeminiKeyEditor = false
                                        app.uiGeminiKeyInput = ""
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundColor(.secondary)
                                }
                                .padding(.top, 4)
                            }
                        }
                    }
                }

                if !app.workerStatus.lastError.isEmpty {
                    SectionCard(padding: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                            Text(app.workerStatus.lastError)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding(22)
        }
    }

    private func statusBadge(ok: Bool, okText: String, waitText: String) -> some View {
        Text(ok ? okText : waitText)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundColor(ok ? Theme.accent : .orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 2.5)
            .background(
                Capsule().fill((ok ? Theme.accent : Color.orange).opacity(0.15))
            )
    }
}

// MARK: - 7. History View (matches screenshot #6 + Audio Player & 1-Click Groq Re-run)

struct HistorySectionView: View {
    @ObservedObject var app: AppState

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private let groupDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "uk_UA")
        f.dateFormat = "d MMMM yyyy"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Search & Transcribe File bar
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Пошук по історії записів або програмах…", text: $app.historySearch)
                        .textFieldStyle(.plain)
                    if !app.historySearch.isEmpty {
                        Button(action: { app.historySearch = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))

                Button(action: { app.promptAndTranscribeFile() }) {
                    Label("Розпізнати файл…", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.bordered)

                Spacer()

                if !app.historyItems.isEmpty {
                    Menu {
                        Button("Markdown (.md)") { _ = app.exportHistory(format: "md") }
                        Button("Текст (.txt)") { _ = app.exportHistory(format: "txt") }
                        Button("Субтитри (.srt)") { _ = app.exportHistory(format: "srt") }
                    } label: {
                        Label("Експорт", systemImage: "square.and.arrow.up")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 100)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)

            Divider().opacity(0.2)

            if app.historyItems.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    if app.historySearch.isEmpty {
                        Image(systemName: "waveform.and.mic")
                            .font(.system(size: 34))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("Історія записів поки порожня")
                            .font(.system(size: 14.5, weight: .semibold))
                        Text("Затисніть \(app.settings.pushToTalkShortcut.displayTokens.joined(separator: " ")) і скажіть фразу — або перетягніть сюди аудіо чи відео.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    } else {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 30))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("Нічого не знайдено за «\(app.historySearch)»")
                            .font(.system(size: 14.5, weight: .semibold))
                        Text("Спробуйте інше слово або назву програми.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Button("Очистити пошук") { app.historySearch = "" }
                            .buttonStyle(.bordered)
                            .padding(.top, 4)
                    }
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(groupedHistory, id: \.title) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(group.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .padding(.leading, 4)

                                ForEach(group.items) { item in
                                    historyCard(item)
                                }
                            }
                        }
                    }
                    .padding(22)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if app.uiPendingDeleteItem != nil {
                HStack(spacing: 12) {
                    Image(systemName: "trash")
                        .foregroundColor(.secondary)
                    Text("Запис видалено")
                        .font(Theme.font(12.5, strong: true))
                    Button("Повернути") { app.undoDelete() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .controlSize(.small)
                        .keyboardShortcut("z", modifiers: .command)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                )
                .padding(.bottom, 18)
                .transition(.opacity.combined(with: .offset(y: 10)))
            }
        }
        .animation(Theme.spring, value: app.uiPendingDeleteItem?.id)
        .overlay(
            Group {
                if app.uiIsDropTargeted {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8]))
                        .background(Theme.accent.opacity(0.08))
                        .padding(12)
                }
            }
        )
        .onDrop(of: [.fileURL], isTargeted: $app.uiIsDropTargeted) { providers in
            guard let first = providers.first else { return false }
            _ = first.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    Task { @MainActor in
                        app.transcribeExternalFile(url: url)
                    }
                }
            }
            return true
        }
    }

    private var groupedHistory: [(title: String, items: [RecordingItem])] {
        let cal = Calendar.current
        var buckets: [(title: String, items: [RecordingItem])] = []
        for item in app.historyItems {
            let label: String
            if cal.isDateInToday(item.timestamp) {
                label = "Сьогодні"
            } else if cal.isDateInYesterday(item.timestamp) {
                label = "Вчора"
            } else {
                label = groupDateFormatter.string(from: item.timestamp)
            }
            if let lastIdx = buckets.indices.last, buckets[lastIdx].title == label {
                buckets[lastIdx].items.append(item)
            } else {
                buckets.append((title: label, items: [item]))
            }
        }
        return buckets
    }

    private func historyBadge(_ label: String, tint: Color) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(tint.opacity(0.14)))
    }

    private func historyAction(_ label: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func historyCard(_ item: RecordingItem) -> some View {
        let isCopied = app.uiCopiedItemID == item.id
        let isPlaying = app.playingItemID == item.id
        let hasAudio = !item.audioFile.isEmpty && FileManager.default.fileExists(atPath: app.storage.resolveAudioURL(item.audioFile).path)
        let isHovered = app.uiHoveredHistoryID == item.id
        // Actions stay quiet until the row is pointed at (or is doing something)
        let actionsOpacity: Double = (isHovered || isPlaying || isCopied || item.isFailedRecognition) ? 1 : 0.3

        return VStack(alignment: .leading, spacing: 9) {
            if item.noVoice {
                Text("Голосу не виявлено")
                    .font(.system(size: 13, weight: .regular))
                    .italic()
                    .foregroundColor(.secondary.opacity(0.75))
            } else {
                Text(item.text)
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundColor(.primary.opacity(0.94))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                Text(timeFormatter.string(from: item.timestamp))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(.secondary)

                if !item.appName.isEmpty {
                    Text("· \(item.appName)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                if !item.noVoice && item.wordCount > 0 {
                    Text("· \(item.wordCount) сл. (\(String(format: "%.1f с", item.durationMs / 1000.0)))")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(.secondary.opacity(0.8))
                }

                if item.groqAssisted {
                    historyBadge("Groq", tint: Color(red: 0.98, green: 0.54, blue: 0.24))
                }
                if item.netPending || item.llmPending {
                    historyBadge(item.llmPending && !item.netPending ? "без ШІ" : "офлайн", tint: .secondary)
                        .help(item.llmPending
                              ? "Вставлено без ШІ-обробки — мережі не було"
                              : "Вставлено без онлайн-перевірки — мережі не було")
                }

                Spacer()

                Group {
                if hasAudio {
                    Button(action: { app.togglePlayAudio(for: item) }) {
                        Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle")
                            .font(.system(size: 14))
                            .foregroundColor(isPlaying ? Theme.accent : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isPlaying ? "Зупинити відтворення" : "Прослухати запис")

                    if item.isFailedRecognition {
                        historyAction("Повторити", help: "Розпізнати цей запис ще раз локальною моделлю") {
                            app.retranscribeHistoryItem(item, engineChoice: .parakeet)
                        }
                    } else if app.workerStatus.hasGroqKey {
                        historyAction(
                            item.netPending ? "Перевірити онлайн" : "Groq",
                            help: app.isOnline
                                ? "Перерозпізнати цей запис через Groq Whisper Large v3"
                                : "Немає мережі — перевірка стане доступною, коли з'явиться інтернет"
                        ) {
                            app.retranscribeHistoryItem(item, engineChoice: .groq)
                        }
                        .disabled(!app.isOnline)
                        .opacity(app.isOnline ? 1 : 0.45)
                    }
                }

                if item.llmPending && !item.noVoice {
                    historyAction(
                        "Обробити ШІ",
                        help: app.isOnline
                            ? "Застосувати ШІ-обробку режиму «\(item.modeName)» до цього тексту"
                            : "Немає мережі — обробка стане доступною, коли з'явиться інтернет"
                    ) {
                        app.applyAIToHistoryItem(item)
                    }
                    .disabled(!app.isOnline)
                    .opacity(app.isOnline ? 1 : 0.45)
                }

                if !item.noVoice && !item.text.isEmpty {
                    Button(action: {
                        TextInserter.copyToClipboard(item.text)
                        app.uiCopiedItemID = item.id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                            if app.uiCopiedItemID == item.id { app.uiCopiedItemID = nil }
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11.5, weight: .semibold))
                            if isCopied {
                                Text("Скопійовано")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                        }
                        .foregroundColor(isCopied ? Theme.accent : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Скопіювати текст у буфер обміну")
                }

                Button(action: { app.deleteItem(item) }) {
                    Image(systemName: "trash")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help("Видалити запис (можна повернути протягом 5 с)")
                .accessibilityLabel("Видалити запис")
                }
                .opacity(actionsOpacity)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.07 : 0.045))
        )
        .onHover { inside in
            if inside { app.uiHoveredHistoryID = item.id } else if app.uiHoveredHistoryID == item.id { app.uiHoveredHistoryID = nil }
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}
