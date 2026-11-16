import Foundation
import SQLite3
import AVFoundation

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class StorageManager: @unchecked Sendable {
    static let shared = StorageManager()

    let baseDir: URL
    let recordingsDir: URL
    let settingsURL: URL
    let dbURL: URL

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "ua.slava.shepit.storage", qos: .userInitiated)

    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private let shortDayLabelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "uk_UA")
        f.dateFormat = "d MMM"
        return f
    }()

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        baseDir = appSupport.appendingPathComponent("Shepit", isDirectory: true)
        recordingsDir = baseDir.appendingPathComponent("recordings", isDirectory: true)
        settingsURL = baseDir.appendingPathComponent("settings.json")
        dbURL = baseDir.appendingPathComponent("shepit.sqlite")

        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        openDatabase()
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    // MARK: - Settings

    func loadSettings() -> ShepitSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let decoded = try? JSONDecoder().decode(ShepitSettings.self, from: data) else {
            var initial = ShepitSettings()
            mergeLegacyVocabulary(into: &initial)
            saveSettings(initial)
            return initial
        }
        return decoded
    }

    func saveSettings(_ settings: ShepitSettings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(settings) {
            try? data.write(to: settingsURL, options: .atomic)
        }
    }

    private func mergeLegacyVocabulary(into settings: inout ShepitSettings) {
        let legacySettingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/superwhisper/settings/settings.json")
        guard let data = try? Data(contentsOf: legacySettingsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if let vocab = obj["vocabulary"] as? [String] {
            for word in vocab {
                let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
                if !w.isEmpty && !settings.vocabulary.contains(where: { $0.caseInsensitiveCompare(w) == .orderedSame }) {
                    settings.vocabulary.append(w)
                }
            }
        }
        if let repls = obj["replacements"] as? [[String: Any]] {
            for r in repls {
                guard let orig = (r["original"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let target = (r["with"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !orig.isEmpty else { continue }
                if !settings.replacements.contains(where: { $0.from.caseInsensitiveCompare(orig) == .orderedSame }) {
                    settings.replacements.append(ReplacementRule(from: orig, to: target, enabled: true))
                }
            }
        }
    }

    // MARK: - Database Setup

    private func openDatabase() {
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            return
        }
        execSQL("PRAGMA journal_mode=WAL;")
        execSQL("PRAGMA synchronous=NORMAL;")

        execSQL("""
        CREATE TABLE IF NOT EXISTS stat_events (
            id TEXT PRIMARY KEY,
            timestamp REAL NOT NULL,
            date_day TEXT NOT NULL,
            hour_of_day INTEGER NOT NULL,
            app_name TEXT NOT NULL DEFAULT '',
            mode_name TEXT NOT NULL DEFAULT '',
            word_count INTEGER NOT NULL DEFAULT 0,
            char_count INTEGER NOT NULL DEFAULT 0,
            duration_ms REAL NOT NULL DEFAULT 0,
            processing_ms REAL NOT NULL DEFAULT 0,
            from_file INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_stat_events_ts ON stat_events(timestamp);
        CREATE INDEX IF NOT EXISTS idx_stat_events_day ON stat_events(date_day);
        """)

        execSQL("""
        CREATE TABLE IF NOT EXISTS history_items (
            id TEXT PRIMARY KEY,
            timestamp REAL NOT NULL,
            duration_ms REAL NOT NULL DEFAULT 0,
            word_count INTEGER NOT NULL DEFAULT 0,
            char_count INTEGER NOT NULL DEFAULT 0,
            processing_ms REAL NOT NULL DEFAULT 0,
            app_name TEXT NOT NULL DEFAULT '',
            app_bundle_id TEXT NOT NULL DEFAULT '',
            mode_name TEXT NOT NULL DEFAULT '',
            engine_used TEXT NOT NULL DEFAULT '',
            text TEXT NOT NULL DEFAULT '',
            raw_text TEXT NOT NULL DEFAULT '',
            audio_file TEXT NOT NULL DEFAULT '',
            no_voice INTEGER NOT NULL DEFAULT 0,
            from_file INTEGER NOT NULL DEFAULT 0,
            groq_assisted INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_history_ts ON history_items(timestamp DESC);
        """)

        // Additive migrations: sqlite reports "duplicate column" on later launches, which execSQL ignores
        execSQL("ALTER TABLE history_items ADD COLUMN net_pending INTEGER NOT NULL DEFAULT 0;")
        execSQL("ALTER TABLE history_items ADD COLUMN llm_pending INTEGER NOT NULL DEFAULT 0;")
    }

    private func execSQL(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    // MARK: - Recording Insert & Update

    func saveRecording(_ item: RecordingItem) {
        queue.sync {
            guard let db else { return }
            let ts = item.timestamp.timeIntervalSince1970
            let dayStr = dayFormatter.string(from: item.timestamp)
            let hour = Calendar.current.component(.hour, from: item.timestamp)

            let histSQL = """
            INSERT OR REPLACE INTO history_items
            (id, timestamp, duration_ms, word_count, char_count, processing_ms, app_name, app_bundle_id,
             mode_name, engine_used, text, raw_text, audio_file, no_voice, from_file, groq_assisted,
             net_pending, llm_pending)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, histSQL, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, item.id, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 2, ts)
                sqlite3_bind_double(stmt, 3, item.durationMs)
                sqlite3_bind_int(stmt, 4, Int32(item.wordCount))
                sqlite3_bind_int(stmt, 5, Int32(item.charCount))
                sqlite3_bind_double(stmt, 6, item.processingMs)
                sqlite3_bind_text(stmt, 7, item.appName, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 8, item.appBundleID, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 9, item.modeName, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 10, item.engineUsed, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 11, item.text, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 12, item.rawText, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 13, item.audioFile, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 14, item.noVoice ? 1 : 0)
                sqlite3_bind_int(stmt, 15, item.fromFile ? 1 : 0)
                sqlite3_bind_int(stmt, 16, item.groqAssisted ? 1 : 0)
                sqlite3_bind_int(stmt, 17, item.netPending ? 1 : 0)
                sqlite3_bind_int(stmt, 18, item.llmPending ? 1 : 0)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }

            if !item.noVoice && item.wordCount > 0 {
                let statSQL = """
                INSERT OR REPLACE INTO stat_events
                (id, timestamp, date_day, hour_of_day, app_name, mode_name, word_count, char_count, duration_ms, processing_ms, from_file)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
                var stStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, statSQL, -1, &stStmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stStmt, 1, item.id, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_double(stStmt, 2, ts)
                    sqlite3_bind_text(stStmt, 3, dayStr, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int(stStmt, 4, Int32(hour))
                    sqlite3_bind_text(stStmt, 5, item.appName, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stStmt, 6, item.modeName, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int(stStmt, 7, Int32(item.wordCount))
                    sqlite3_bind_int(stStmt, 8, Int32(item.charCount))
                    sqlite3_bind_double(stStmt, 9, item.durationMs)
                    sqlite3_bind_double(stStmt, 10, item.processingMs)
                    sqlite3_bind_int(stStmt, 11, item.fromFile ? 1 : 0)
                    sqlite3_step(stStmt)
                    sqlite3_finalize(stStmt)
                }
            }
        }
    }

    func deleteHistoryItem(_ item: RecordingItem) {
        queue.sync {
            guard let db else { return }
            if !item.audioFile.isEmpty {
                let url = resolveAudioURL(item.audioFile)
                if url.path.hasPrefix(recordingsDir.path) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM history_items WHERE id = ?;", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, item.id, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    func resolveAudioURL(_ audioFile: String) -> URL {
        if audioFile.hasPrefix("/") {
            return URL(fileURLWithPath: audioFile)
        }
        return recordingsDir.appendingPathComponent(audioFile)
    }

    // MARK: - Queries

    func fetchHistory(search: String = "", limit: Int = 250) -> [RecordingItem] {
        queue.sync {
            guard let db else { return [] }
            let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
            let sql: String
            if trimmed.isEmpty {
                sql = """
                SELECT id, timestamp, duration_ms, word_count, char_count, processing_ms,
                       app_name, app_bundle_id, mode_name, engine_used, text, raw_text,
                       audio_file, no_voice, from_file, groq_assisted, net_pending, llm_pending
                FROM history_items
                ORDER BY timestamp DESC
                LIMIT ?;
                """
            } else {
                sql = """
                SELECT id, timestamp, duration_ms, word_count, char_count, processing_ms,
                       app_name, app_bundle_id, mode_name, engine_used, text, raw_text,
                       audio_file, no_voice, from_file, groq_assisted, net_pending, llm_pending
                FROM history_items
                WHERE text LIKE ? OR app_name LIKE ? OR mode_name LIKE ?
                ORDER BY timestamp DESC
                LIMIT ?;
                """
            }

            var items: [RecordingItem] = []
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                if trimmed.isEmpty {
                    sqlite3_bind_int(stmt, 1, Int32(limit))
                } else {
                    let pattern = "%\(trimmed)%"
                    sqlite3_bind_text(stmt, 1, pattern, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 2, pattern, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 3, pattern, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int(stmt, 4, Int32(limit))
                }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let item = RecordingItem(
                        id: colString(stmt, 0),
                        timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                        durationMs: sqlite3_column_double(stmt, 2),
                        wordCount: Int(sqlite3_column_int(stmt, 3)),
                        charCount: Int(sqlite3_column_int(stmt, 4)),
                        processingMs: sqlite3_column_double(stmt, 5),
                        appName: colString(stmt, 6),
                        appBundleID: colString(stmt, 7),
                        modeName: colString(stmt, 8),
                        engineUsed: colString(stmt, 9),
                        text: colString(stmt, 10),
                        rawText: colString(stmt, 11),
                        audioFile: colString(stmt, 12),
                        noVoice: sqlite3_column_int(stmt, 13) != 0,
                        fromFile: sqlite3_column_int(stmt, 14) != 0,
                        groqAssisted: sqlite3_column_int(stmt, 15) != 0,
                        netPending: sqlite3_column_int(stmt, 16) != 0,
                        llmPending: sqlite3_column_int(stmt, 17) != 0
                    )
                    items.append(item)
                }
                sqlite3_finalize(stmt)
            }
            return items
        }
    }

    func fetchStats(range: StatRange, typingBaselineWPM: Int) -> DashboardStats {
        queue.sync {
            guard let db else { return .empty }
            var stats = DashboardStats()
            let cutoffTS = range.cutoffDate?.timeIntervalSince1970 ?? 0
            let hasCutoff = range.cutoffDate != nil

            let aggSQL = hasCutoff
                ? "SELECT COUNT(*), COALESCE(SUM(word_count),0), COALESCE(SUM(char_count),0), COALESCE(SUM(duration_ms),0), COUNT(DISTINCT NULLIF(app_name,'')) FROM stat_events WHERE timestamp >= ?;"
                : "SELECT COUNT(*), COALESCE(SUM(word_count),0), COALESCE(SUM(char_count),0), COALESCE(SUM(duration_ms),0), COUNT(DISTINCT NULLIF(app_name,'')) FROM stat_events;"

            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, aggSQL, -1, &stmt, nil) == SQLITE_OK {
                if hasCutoff { sqlite3_bind_double(stmt, 1, cutoffTS) }
                if sqlite3_step(stmt) == SQLITE_ROW {
                    stats.recordingsCount = Int(sqlite3_column_int(stmt, 0))
                    stats.totalWords = Int(sqlite3_column_int(stmt, 1))
                    stats.totalChars = Int(sqlite3_column_int(stmt, 2))
                    stats.totalDurationMs = sqlite3_column_double(stmt, 3)
                    stats.appsUsedCount = Int(sqlite3_column_int(stmt, 4))
                }
                sqlite3_finalize(stmt)
            }

            if stats.totalDurationMs > 1000 && stats.totalWords > 0 {
                let mins = stats.totalDurationMs / 60_000.0
                stats.averageWPM = Int(round(Double(stats.totalWords) / mins))
            }

            let typingWPM = max(15, Double(typingBaselineWPM))
            let typingSeconds = (Double(stats.totalWords) / typingWPM) * 60.0
            let spokenSeconds = stats.totalDurationMs / 1000.0
            stats.savedSeconds = max(0, typingSeconds - spokenSeconds)

            // Top apps
            let appsSQL = hasCutoff
                ? "SELECT app_name, SUM(word_count) as w, COUNT(*), SUM(duration_ms) FROM stat_events WHERE timestamp >= ? AND app_name != '' GROUP BY app_name ORDER BY w DESC LIMIT 8;"
                : "SELECT app_name, SUM(word_count) as w, COUNT(*), SUM(duration_ms) FROM stat_events WHERE app_name != '' GROUP BY app_name ORDER BY w DESC LIMIT 8;"

            if sqlite3_prepare_v2(db, appsSQL, -1, &stmt, nil) == SQLITE_OK {
                if hasCutoff { sqlite3_bind_double(stmt, 1, cutoffTS) }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    stats.topApps.append(
                        AppUsageStat(
                            appName: colString(stmt, 0),
                            words: Int(sqlite3_column_int(stmt, 1)),
                            count: Int(sqlite3_column_int(stmt, 2)),
                            durationMs: sqlite3_column_double(stmt, 3)
                        )
                    )
                }
                sqlite3_finalize(stmt)
            }

            // Peak hour
            let hourSQL = hasCutoff
                ? "SELECT hour_of_day, SUM(word_count) as w FROM stat_events WHERE timestamp >= ? GROUP BY hour_of_day ORDER BY w DESC LIMIT 1;"
                : "SELECT hour_of_day, SUM(word_count) as w FROM stat_events GROUP BY hour_of_day ORDER BY w DESC LIMIT 1;"
            if sqlite3_prepare_v2(db, hourSQL, -1, &stmt, nil) == SQLITE_OK {
                if hasCutoff { sqlite3_bind_double(stmt, 1, cutoffTS) }
                if sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 1) > 0 {
                    stats.peakHour = Int(sqlite3_column_int(stmt, 0))
                }
                sqlite3_finalize(stmt)
            }

            // Last 14 days daily bar series
            let cal = Calendar.current
            let todayStart = cal.startOfDay(for: Date())
            var dayMap: [String: (Int, Int)] = [:]
            if let twoWeeksAgo = cal.date(byAdding: .day, value: -13, to: todayStart) {
                let seriesSQL = "SELECT date_day, SUM(word_count), COUNT(*) FROM stat_events WHERE timestamp >= ? GROUP BY date_day;"
                if sqlite3_prepare_v2(db, seriesSQL, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_double(stmt, 1, twoWeeksAgo.timeIntervalSince1970)
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        dayMap[colString(stmt, 0)] = (Int(sqlite3_column_int(stmt, 1)), Int(sqlite3_column_int(stmt, 2)))
                    }
                    sqlite3_finalize(stmt)
                }
                for offset in stride(from: -13, through: 0, by: 1) {
                    if let d = cal.date(byAdding: .day, value: offset, to: todayStart) {
                        let key = dayFormatter.string(from: d)
                        let lbl = shortDayLabelFormatter.string(from: d)
                        let vals = dayMap[key] ?? (0, 0)
                        stats.dailySeries.append(DailyWordStat(dateKey: key, label: lbl, words: vals.0, count: vals.1))
                    }
                }
            }

            // Current streak in days
            var allDays = Set<String>()
            if sqlite3_prepare_v2(db, "SELECT DISTINCT date_day FROM stat_events WHERE word_count > 0;", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    allDays.insert(colString(stmt, 0))
                }
                sqlite3_finalize(stmt)
            }
            var streak = 0
            var cursor = todayStart
            if !allDays.contains(dayFormatter.string(from: cursor)),
               let yesterday = cal.date(byAdding: .day, value: -1, to: cursor),
               allDays.contains(dayFormatter.string(from: yesterday)) {
                cursor = yesterday
            }
            while allDays.contains(dayFormatter.string(from: cursor)) {
                streak += 1
                guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
                cursor = prev
            }
            stats.streakDays = streak

            return stats
        }
    }

    // MARK: - Audio Compression & Retention

    /// Compress 16 kHz WAV into tiny ~64 kbps mono M4A for compact history playback, then delete temporary WAV.
    func archiveWAVToM4A(wavURL: URL, id: String, retention: AudioRetention) -> String {
        if retention == .never {
            try? FileManager.default.removeItem(at: wavURL)
            return ""
        }
        let m4aName = "\(id).m4a"
        let dstURL = recordingsDir.appendingPathComponent(m4aName)
        let proc = Process()
        let ffmpegPath = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg")
            ? "/opt/homebrew/bin/ffmpeg"
            : "/usr/local/bin/ffmpeg"

        if FileManager.default.isExecutableFile(atPath: ffmpegPath) {
            proc.executableURL = URL(fileURLWithPath: ffmpegPath)
            proc.arguments = [
                "-nostdin", "-y", "-v", "error",
                "-i", wavURL.path,
                "-c:a", "aac", "-b:a", "48k", "-ac", "1",
                dstURL.path
            ]
            do {
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 && FileManager.default.fileExists(atPath: dstURL.path) {
                    try? FileManager.default.removeItem(at: wavURL)
                    return m4aName
                }
            } catch {}
        }

        // Fallback if ffmpeg unavailable: copy WAV
        let wavName = "\(id).wav"
        let fallbackURL = recordingsDir.appendingPathComponent(wavName)
        try? FileManager.default.removeItem(at: fallbackURL)
        if (try? FileManager.default.moveItem(at: wavURL, to: fallbackURL)) != nil {
            return wavName
        }
        return ""
    }

    func pruneExpiredAudio(retention: AudioRetention) {
        guard let maxAge = retention.maxAgeSeconds else { return }
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let cutoff = Date().timeIntervalSince1970 - maxAge
            let sql = "SELECT id, audio_file FROM history_items WHERE audio_file != '' AND timestamp < ?;"
            var toClear: [(String, String)] = []
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_double(stmt, 1, cutoff)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    toClear.append((self.colString(stmt, 0), self.colString(stmt, 1)))
                }
                sqlite3_finalize(stmt)
            }
            for (id, file) in toClear {
                let url = self.resolveAudioURL(file)
                if url.path.hasPrefix(self.recordingsDir.path) {
                    try? FileManager.default.removeItem(at: url)
                }
                var upd: OpaquePointer?
                if sqlite3_prepare_v2(db, "UPDATE history_items SET audio_file = '' WHERE id = ?;", -1, &upd, nil) == SQLITE_OK {
                    sqlite3_bind_text(upd, 1, id, -1, SQLITE_TRANSIENT)
                    sqlite3_step(upd)
                    sqlite3_finalize(upd)
                }
            }
        }
    }

    // MARK: - Legacy Database Import (Auto-migrates stats & history on first launch)

    @discardableResult
    func importLegacySuperwhisperIfPresent() -> (importedStats: Int, importedHistory: Int) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let swDBPath = home.appendingPathComponent("Library/Application Support/superwhisper/database/superwhisper.sqlite").path
        let swRecDir = home.appendingPathComponent("Documents/superwhisper/recordings")

        guard FileManager.default.fileExists(atPath: swDBPath) else {
            return (0, 0)
        }

        return queue.sync {
            guard let db else { return (0, 0) }
            var srcDB: OpaquePointer?
            guard sqlite3_open_v2(swDBPath, &srcDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let srcDB else {
                return (0, 0)
            }
            defer { sqlite3_close(srcDB) }

            let utcMillisFormatter = DateFormatter()
            utcMillisFormatter.locale = Locale(identifier: "en_US_POSIX")
            utcMillisFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            utcMillisFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

            let utcSecFormatter = DateFormatter()
            utcSecFormatter.locale = Locale(identifier: "en_US_POSIX")
            utcSecFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            utcSecFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

            func parseUTC(_ raw: String) -> Date {
                if let d = utcMillisFormatter.date(from: raw) { return d }
                if let d = utcSecFormatter.date(from: raw) { return d }
                return Date()
            }

            execSQL("BEGIN TRANSACTION;")
            var statsCount = 0
            var histCount = 0

            // 1. Import all historical stat lines (6161+ records)
            let statReadSQL = """
            SELECT folderName, datetime, fromFile, appName, modeName, wordCount, duration, processingTime
            FROM recording_stat_lines;
            """
            let statInsertSQL = """
            INSERT OR IGNORE INTO stat_events
            (id, timestamp, date_day, hour_of_day, app_name, mode_name, word_count, char_count, duration_ms, processing_ms, from_file)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var rStmt: OpaquePointer?
            var wStmt: OpaquePointer?
            if sqlite3_prepare_v2(srcDB, statReadSQL, -1, &rStmt, nil) == SQLITE_OK,
               sqlite3_prepare_v2(db, statInsertSQL, -1, &wStmt, nil) == SQLITE_OK {
                while sqlite3_step(rStmt) == SQLITE_ROW {
                    let folder = colString(rStmt, 0)
                    let dtStr = colString(rStmt, 1)
                    let fromFile = sqlite3_column_int(rStmt, 2)
                    let appName = colString(rStmt, 3)
                    let modeName = colString(rStmt, 4)
                    let words = Int(sqlite3_column_int(rStmt, 5))
                    let durMs = sqlite3_column_double(rStmt, 6)
                    let procMs = sqlite3_column_double(rStmt, 7)

                    let date = parseUTC(dtStr)
                    let ts = date.timeIntervalSince1970
                    let dayStr = dayFormatter.string(from: date)
                    let hour = Calendar.current.component(.hour, from: date)
                    let recID = "sw_\(folder)"

                    sqlite3_reset(wStmt)
                    sqlite3_clear_bindings(wStmt)
                    sqlite3_bind_text(wStmt, 1, recID, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_double(wStmt, 2, ts)
                    sqlite3_bind_text(wStmt, 3, dayStr, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int(wStmt, 4, Int32(hour))
                    sqlite3_bind_text(wStmt, 5, appName, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(wStmt, 6, modeName, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int(wStmt, 7, Int32(words))
                    sqlite3_bind_int(wStmt, 8, Int32(words * 6))
                    sqlite3_bind_double(wStmt, 9, durMs)
                    sqlite3_bind_double(wStmt, 10, procMs)
                    sqlite3_bind_int(wStmt, 11, fromFile)
                    if sqlite3_step(wStmt) == SQLITE_DONE && sqlite3_changes(db) > 0 {
                        statsCount += 1
                    }
                }
            }
            if let rStmt { sqlite3_finalize(rStmt) }
            if let wStmt { sqlite3_finalize(wStmt) }

            // 2. Import recent history items with full text
            let histReadSQL = """
            SELECT r.folderName, r.datetime, r.duration, r.rawWordCount, r.llmWordCount,
                   r.processingTime, r.modeName, r.modelName, r.promptContext, r.fromFile,
                   COALESCE(NULLIF(f.result, ''), f.rawResult, ''), COALESCE(f.rawResult, '')
            FROM recording r
            LEFT JOIN recording_fts f ON f.recordingId = r.id
            ORDER BY r.datetime DESC;
            """
            let histInsertSQL = """
            INSERT OR IGNORE INTO history_items
            (id, timestamp, duration_ms, word_count, char_count, processing_ms, app_name, app_bundle_id,
             mode_name, engine_used, text, raw_text, audio_file, no_voice, from_file, groq_assisted)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0);
            """
            var hrStmt: OpaquePointer?
            var hwStmt: OpaquePointer?
            if sqlite3_prepare_v2(srcDB, histReadSQL, -1, &hrStmt, nil) == SQLITE_OK,
               sqlite3_prepare_v2(db, histInsertSQL, -1, &hwStmt, nil) == SQLITE_OK {
                while sqlite3_step(hrStmt) == SQLITE_ROW {
                    let folder = colString(hrStmt, 0)
                    let dtStr = colString(hrStmt, 1)
                    let durMs = sqlite3_column_double(hrStmt, 2)
                    let rawWC = Int(sqlite3_column_int(hrStmt, 3))
                    let llmWC = Int(sqlite3_column_int(hrStmt, 4))
                    let procMs = sqlite3_column_double(hrStmt, 5)
                    let modeName = colString(hrStmt, 6)
                    let modelName = colString(hrStmt, 7)
                    let ctxJSON = colString(hrStmt, 8)
                    let fromFile = sqlite3_column_int(hrStmt, 9)
                    let resultText = colString(hrStmt, 10).trimmingCharacters(in: .whitespacesAndNewlines)
                    let rawText = colString(hrStmt, 11).trimmingCharacters(in: .whitespacesAndNewlines)

                    var appName = ""
                    var bundleID = ""
                    if let ctxData = ctxJSON.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: ctxData) as? [String: Any],
                       let appCtx = obj["applicationContext"] as? [String: Any] {
                        appName = (appCtx["name"] as? String) ?? ""
                        bundleID = (appCtx["bundleIdentifier"] as? String) ?? ""
                    }

                    let wc = llmWC > 0 ? llmWC : (rawWC > 0 ? rawWC : resultText.split(whereSeparator: \.isWhitespace).count)
                    let noVoice = resultText.isEmpty && wc == 0
                    let date = parseUTC(dtStr)
                    let recID = "sw_\(folder)"

                    // Copy recent audio wav so playback still works even after user deletes Superwhisper
                    var savedAudio = ""
                    let legacyWav = swRecDir.appendingPathComponent(folder).appendingPathComponent("output.wav")
                    if FileManager.default.fileExists(atPath: legacyWav.path) {
                        let copiedName = "\(recID).wav"
                        let dst = recordingsDir.appendingPathComponent(copiedName)
                        if !FileManager.default.fileExists(atPath: dst.path) {
                            try? FileManager.default.copyItem(at: legacyWav, to: dst)
                        }
                        if FileManager.default.fileExists(atPath: dst.path) {
                            savedAudio = copiedName
                        }
                    }

                    sqlite3_reset(hwStmt)
                    sqlite3_clear_bindings(hwStmt)
                    sqlite3_bind_text(hwStmt, 1, recID, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_double(hwStmt, 2, date.timeIntervalSince1970)
                    sqlite3_bind_double(hwStmt, 3, durMs)
                    sqlite3_bind_int(hwStmt, 4, Int32(wc))
                    sqlite3_bind_int(hwStmt, 5, Int32(resultText.count))
                    sqlite3_bind_double(hwStmt, 6, procMs)
                    sqlite3_bind_text(hwStmt, 7, appName, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(hwStmt, 8, bundleID, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(hwStmt, 9, modeName.isEmpty ? "Голос у текст" : modeName, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(hwStmt, 10, modelName.isEmpty ? "Parakeet v3" : modelName, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(hwStmt, 11, resultText, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(hwStmt, 12, rawText, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(hwStmt, 13, savedAudio, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int(hwStmt, 14, noVoice ? 1 : 0)
                    sqlite3_bind_int(hwStmt, 15, fromFile)
                    if sqlite3_step(hwStmt) == SQLITE_DONE && sqlite3_changes(db) > 0 {
                        histCount += 1
                    }
                }
            }
            if let hrStmt { sqlite3_finalize(hrStmt) }
            if let hwStmt { sqlite3_finalize(hwStmt) }

            execSQL("COMMIT;")
            return (statsCount, histCount)
        }
    }

    private func colString(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let cStr = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cStr)
    }
}
