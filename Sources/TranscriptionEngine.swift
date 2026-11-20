import Foundation

struct TranscriptionResponse {
    var noVoice: Bool
    var text: String
    var rawText: String
    var durationSec: Double
    var processingMs: Double
    var engineUsed: String
    var groqAssisted: Bool
    var llmApplied: Bool
    /// ok | not_needed | offline | timeout | failed — what happened to the online double-check
    var netStatus: String = "not_needed"
    /// none | applied | offline | failed — what happened to the AI post-processing
    var llmStatus: String = "none"
    /// Single-word swaps Groq made over the local model (feeds the learning vocabulary)
    var corrections: [(from: String, to: String)] = []

    var onlineCheckSkipped: Bool { netStatus == "offline" || netStatus == "timeout" || netStatus == "failed" }
    var llmSkipped: Bool { llmStatus == "offline" || llmStatus == "failed" }
}

final class TranscriptionEngine {
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutBuffer = Data()

    private let ioQueue = DispatchQueue(label: "ua.slava.shepit.worker.io", qos: .userInitiated)
    private var pendingCallbacks: [String: (Result<[String: Any], Error>) -> Void] = [:]

    var onStatusUpdate: ((WorkerStatusInfo) -> Void)?
    /// Mirrors NetworkMonitor; written from the main queue, read when a request is built.
    var isOnline = true
    private var currentStatus = WorkerStatusInfo()

    init() {}

    func startAndWarmup() {
        ioQueue.async { [weak self] in
            self?.ensureProcessStarted()
            self?.sendRawCommand(["cmd": "warmup"], timeout: 45.0) { [weak self] res in
                guard let self else { return }
                if case .success(let dict) = res {
                    self.applyStatusDict(dict)
                }
            }
        }
    }

    func refreshStatus() {
        ioQueue.async { [weak self] in
            self?.ensureProcessStarted()
            self?.sendRawCommand(["cmd": "ping"], timeout: 4.0) { [weak self] res in
                guard let self else { return }
                if case .success(let dict) = res {
                    self.applyStatusDict(dict)
                }
            }
        }
    }

    func restartWorker() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.killProcessNow()
            self.ensureProcessStarted()
            self.sendRawCommand(["cmd": "warmup"], timeout: 45.0) { [weak self] res in
                if case .success(let dict) = res {
                    self?.applyStatusDict(dict)
                }
            }
        }
    }

    func shutdown() {
        ioQueue.sync {
            killProcessNow()
        }
    }

    func requestPreview(audioURL: URL, completion: @escaping (String) -> Void) {
        ioQueue.async { [weak self] in
            guard let self, self.process?.isRunning == true else { return }
            let payload: [String: Any] = [
                "cmd": "preview",
                "audio_path": audioURL.path
            ]
            self.sendRawCommand(payload, timeout: 2.5) { result in
                if case .success(let dict) = result, let txt = dict["text"] as? String {
                    DispatchQueue.main.async { completion(txt) }
                }
            }
        }
    }

    func transcribe(
        audioURL: URL,
        mode: ShepitMode,
        settings: ShepitSettings,
        forceEngine: EngineChoice? = nil,
        context: [String: Any]? = nil,
        isFile: Bool = false,
        forceNetwork: Bool = false,
        completion: @escaping (Result<TranscriptionResponse, Error>) -> Void
    ) {
        let online = isOnline
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.ensureProcessStarted()

            let activeReplacements: [[String: String]] = settings.replacements
                .filter { $0.enabled && !$0.from.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { ["from": $0.from, "to": $0.to] }

            let chosenEngine = forceEngine ?? mode.engine
            var payload: [String: Any] = [
                "cmd": "transcribe",
                "audio_path": audioURL.path,
                "engine": chosenEngine.rawValue,
                "language": mode.language,
                "auto_gain": settings.autoGain,
                "silence_removal": settings.silenceRemoval,
                "dynamic_normalization": settings.dynamicNormalization,
                "vocabulary": settings.vocabulary,
                "replacements": activeReplacements,
                "llm_mode": mode.llmMode,
                "custom_prompt": mode.customPrompt,
                "autocapitalize": mode.autocapitalize,
                "enable_voice_commands": settings.enableVoiceCommands,
                "enable_smart_formatting": settings.enableSmartFormatting,
                "is_file": isFile,
                "online": online,
                "force_network": forceNetwork
            ]
            if let context, !context.isEmpty {
                payload["context"] = context
            }

            let timeoutSec = isFile ? 240.0 : 22.0
            self.sendRawCommand(payload, timeout: timeoutSec) { [weak self] result in
                switch result {
                case .success(let dict):
                    let resp = Self.parseResponse(dict, fallbackEngine: chosenEngine.shortBadge)
                    DispatchQueue.main.async { completion(.success(resp)) }
                    self?.refreshStatus()
                case .failure(let err):
                    // The worker hung or was reset: the audio is still on disk, so try once more
                    // with the local model only — no network, no AI — before reporting a failure.
                    let code = (err as NSError).code
                    guard let self, !isFile, code == -4 || code == -9 else {
                        DispatchQueue.main.async { completion(.failure(err)) }
                        return
                    }
                    var localPayload = payload
                    localPayload["engine"] = EngineChoice.parakeet.rawValue
                    localPayload["llm_mode"] = ""
                    localPayload["online"] = false
                    localPayload["force_network"] = false
                    self.ensureProcessStarted()
                    self.sendRawCommand(localPayload, timeout: 30.0) { retry in
                        switch retry {
                        case .success(let dict):
                            var resp = Self.parseResponse(dict, fallbackEngine: EngineChoice.parakeet.shortBadge)
                            resp.netStatus = "timeout"
                            resp.llmStatus = mode.llmMode.isEmpty ? "none" : "offline"
                            DispatchQueue.main.async { completion(.success(resp)) }
                        case .failure:
                            DispatchQueue.main.async { completion(.failure(err)) }
                        }
                    }
                }
            }
        }
    }

    /// AI-only pass over an already recognised text (History → «Обробити ШІ»).
    func postprocess(
        text: String,
        mode: ShepitMode,
        settings: ShepitSettings,
        completion: @escaping (Result<(text: String, applied: Bool), Error>) -> Void
    ) {
        let online = isOnline
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.ensureProcessStarted()
            let activeReplacements: [[String: String]] = settings.replacements
                .filter { $0.enabled && !$0.from.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { ["from": $0.from, "to": $0.to] }
            let payload: [String: Any] = [
                "cmd": "postprocess",
                "text": text,
                "llm_mode": mode.llmMode,
                "custom_prompt": mode.customPrompt,
                "autocapitalize": mode.autocapitalize,
                "replacements": activeReplacements,
                "online": online
            ]
            self.sendRawCommand(payload, timeout: 30.0) { result in
                switch result {
                case .success(let dict):
                    let out = (dict["text"] as? String) ?? text
                    let applied = (dict["llm_applied"] as? Bool) ?? false
                    DispatchQueue.main.async { completion(.success((out, applied))) }
                case .failure(let err):
                    DispatchQueue.main.async { completion(.failure(err)) }
                }
            }
        }
    }

    private static func parseResponse(_ dict: [String: Any], fallbackEngine: String) -> TranscriptionResponse {
        var resp = TranscriptionResponse(
            noVoice: (dict["no_voice"] as? Bool) ?? false,
            text: (dict["text"] as? String) ?? "",
            rawText: (dict["raw_text"] as? String) ?? "",
            durationSec: (dict["duration_sec"] as? Double) ?? 0,
            processingMs: (dict["processing_ms"] as? Double) ?? 0,
            engineUsed: (dict["engine_used"] as? String) ?? fallbackEngine,
            groqAssisted: (dict["groq_assisted"] as? Bool) ?? false,
            llmApplied: (dict["llm_applied"] as? Bool) ?? false
        )
        resp.netStatus = (dict["net_status"] as? String) ?? "not_needed"
        resp.llmStatus = (dict["llm_status"] as? String) ?? "none"
        if let list = dict["corrections"] as? [[String: Any]] {
            resp.corrections = list.compactMap { item in
                guard let from = item["from"] as? String, let to = item["to"] as? String else { return nil }
                return (from: from, to: to)
            }
        }
        return resp
    }

    // MARK: - Subprocess Management

    private func resolvePythonBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let direct = "\(home)/.local/share/uv/tools/parakeet-mlx/bin/python"
        if FileManager.default.isExecutableFile(atPath: direct) {
            return direct
        }
        let wrapper = "\(home)/.local/bin/parakeet-mlx"
        if let txt = try? String(contentsOfFile: wrapper, encoding: .utf8),
           let firstLine = txt.split(separator: "\n").first,
           firstLine.hasPrefix("#!") {
            let candidate = String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/Library/Developer/CommandLineTools/usr/bin/python3",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private func localKeyExists(_ name: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(".config/keys/\(name).key")
        guard let txt = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return !txt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func resolveWorkerScript() -> String {
        if let bundled = Bundle.main.path(forResource: "shepit_worker", ofType: "py") {
            return bundled
        }
        // Fallback during local dev runs
        let devPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("worker/shepit_worker.py").path
        return devPath
    }

    private func ensureProcessStarted() {
        if let proc = process, proc.isRunning { return }
        killProcessNow()

        guard let py = resolvePythonBinary() else {
            currentStatus.isRunning = false
            currentStatus.isModelLoaded = false
            currentStatus.modelExists = false
            currentStatus.hasGroqKey = localKeyExists("groq")
            currentStatus.hasGeminiKey = localKeyExists("gemini")
            currentStatus.lastError = ""
            let snapshot = currentStatus
            DispatchQueue.main.async { [weak self] in self?.onStatusUpdate?(snapshot) }
            return
        }

        let script = resolveWorkerScript()
        guard FileManager.default.fileExists(atPath: script) else {
            updateError("Скрипт воркера не знайдено: \(script)")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: py)
        proc.arguments = ["-u", script]

        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.ioQueue.async {
                self?.consumeStdout(chunk)
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        proc.terminationHandler = { [weak self] _ in
            self?.ioQueue.async {
                self?.failAllPending(with: "Воркер розпізнавання перезапущено")
                self?.currentStatus.isRunning = false
                self?.currentStatus.isModelLoaded = false
                if let st = self?.currentStatus {
                    DispatchQueue.main.async { self?.onStatusUpdate?(st) }
                }
            }
        }

        do {
            try proc.run()
            process = proc
            stdinHandle = inPipe.fileHandleForWriting
            currentStatus.isRunning = true
            currentStatus.lastError = ""
            let snapshot = currentStatus
            DispatchQueue.main.async { [weak self] in self?.onStatusUpdate?(snapshot) }
        } catch {
            updateError("Не вдалося запустити MLX-воркер: \(error.localizedDescription)")
        }
    }

    private func killProcessNow() {
        if let proc = process {
            if let outPipe = proc.standardOutput as? Pipe {
                outPipe.fileHandleForReading.readabilityHandler = nil
            }
            if let errPipe = proc.standardError as? Pipe {
                errPipe.fileHandleForReading.readabilityHandler = nil
            }
            if proc.isRunning {
                proc.terminate()
            }
        }
        process = nil
        stdinHandle = nil
        stdoutBuffer.removeAll()
        failAllPending(with: "Сесію воркера скинуто")
    }

    private func sendRawCommand(
        _ payload: [String: Any],
        timeout: TimeInterval,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        guard let stdinHandle, process?.isRunning == true else {
            completion(.failure(NSError(domain: "ShepitWorker", code: -2, userInfo: [NSLocalizedDescriptionKey: "Відкрийте «Моделі» та встановіть Parakeet v3 в один клік"])))
            return
        }

        let reqID = UUID().uuidString
        var fullPayload = payload
        fullPayload["id"] = reqID

        guard let jsonData = try? JSONSerialization.data(withJSONObject: fullPayload),
              var lineData = String(data: jsonData, encoding: .utf8)?.data(using: .utf8) else {
            completion(.failure(NSError(domain: "ShepitWorker", code: -3, userInfo: [NSLocalizedDescriptionKey: "Помилка серіалізації запиту"])))
            return
        }
        lineData.append(0x0A) // newline

        pendingCallbacks[reqID] = completion

        do {
            try stdinHandle.write(contentsOf: lineData)
        } catch {
            pendingCallbacks.removeValue(forKey: reqID)
            completion(.failure(error))
            return
        }

        // Watchdog timeout: auto-recover hung worker so Shepit never freezes!
        ioQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, let cb = self.pendingCallbacks.removeValue(forKey: reqID) else { return }
            let isPreview = (payload["cmd"] as? String) == "preview"
            if !isPreview {
                self.killProcessNow()
                self.ensureProcessStarted()
            }
            cb(.failure(NSError(domain: "ShepitWorker", code: -4, userInfo: [NSLocalizedDescriptionKey: "Перевищено час очікування розпізнавання"])))
        }
    }

    private func consumeStdout(_ chunk: Data) {
        stdoutBuffer.append(chunk)
        while let nlRange = stdoutBuffer.range(of: Data([0x0A])) {
            let lineData = stdoutBuffer.subdata(in: 0..<nlRange.lowerBound)
            stdoutBuffer.removeSubrange(0..<nlRange.upperBound)
            guard !lineData.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            if let event = obj["event"] as? String, event == "started",
               let st = obj["status"] as? [String: Any] {
                applyStatusDict(st)
                continue
            }

            if let gone = obj["gone_models"] as? [String: String], gone != currentStatus.goneModels {
                currentStatus.goneModels = gone
                let snapshot = currentStatus
                DispatchQueue.main.async { [weak self] in self?.onStatusUpdate?(snapshot) }
            }

            guard let reqID = obj["id"] as? String,
                  let cb = pendingCallbacks.removeValue(forKey: reqID) else {
                continue
            }

            let ok = (obj["ok"] as? Bool) ?? false
            if ok {
                let res = (obj["result"] as? [String: Any]) ?? [:]
                cb(.success(res))
            } else {
                let errMsg = (obj["error"] as? String) ?? "Помилка розпізнавання"
                updateError(errMsg)
                cb(.failure(NSError(domain: "ShepitWorker", code: -5, userInfo: [NSLocalizedDescriptionKey: errMsg])))
            }
        }
    }

    private func applyStatusDict(_ dict: [String: Any]) {
        currentStatus.isRunning = process?.isRunning == true
        currentStatus.isModelLoaded = (dict["loaded"] as? Bool) ?? currentStatus.isModelLoaded
        currentStatus.modelExists = (dict["model_exists"] as? Bool) ?? true
        currentStatus.loadTimeMs = (dict["load_time_ms"] as? Int) ?? currentStatus.loadTimeMs
        currentStatus.activeMemoryMB = (dict["active_memory_mb"] as? Double) ?? currentStatus.activeMemoryMB
        currentStatus.hasGroqKey = (dict["has_groq_key"] as? Bool) ?? currentStatus.hasGroqKey
        currentStatus.hasGeminiKey = (dict["has_gemini_key"] as? Bool) ?? currentStatus.hasGeminiKey
        if let gone = dict["gone_models"] as? [String: String] { currentStatus.goneModels = gone }
        let snapshot = currentStatus
        DispatchQueue.main.async { [weak self] in
            self?.onStatusUpdate?(snapshot)
        }
    }

    private func updateError(_ message: String) {
        currentStatus.lastError = message
        let snapshot = currentStatus
        DispatchQueue.main.async { [weak self] in
            self?.onStatusUpdate?(snapshot)
        }
    }

    private func failAllPending(with reason: String) {
        let callbacks = pendingCallbacks.values
        pendingCallbacks.removeAll()
        let err = NSError(domain: "ShepitWorker", code: -9, userInfo: [NSLocalizedDescriptionKey: reason])
        for cb in callbacks {
            cb(.failure(err))
        }
    }
}
