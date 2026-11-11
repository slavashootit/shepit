import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

final class AudioRecorder {
    private var engine: AVAudioEngine?
    private let sampleLock = NSLock()
    private var recordedSamples16k: [Int16] = []
    private var isCapturing = false
    private var startTime: Date?
    private var currentWAVURL: URL?
    private var flushTimer: DispatchSourceTimer?
    private var watchdogWorkItem: DispatchWorkItem?
    private var didAttemptRecovery = false

    var onWaveformUpdate: (([CGFloat], TimeInterval) -> Void)?
    var onDevicesChanged: (() -> Void)?

    private var rollingBands: [CGFloat] = Array(repeating: 0.08, count: 28)

    init() {
        registerDeviceListeners()
    }

    // MARK: - Device Enumeration

    static func listInputDevices() -> [AudioInputDevice] {
        var defaultID = AudioDeviceID(0)
        var defSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defAddr, 0, nil, &defSize, &defaultID)

        var propSize: UInt32 = 0
        var devsAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &devsAddr, 0, nil, &propSize) == noErr,
              propSize > 0 else { return [] }

        let count = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &devsAddr, 0, nil, &propSize, &ids) == noErr else {
            return []
        }

        var result: [AudioInputDevice] = []
        for devID in ids {
            guard inputChannelCount(for: devID) > 0 else { continue }
            let name = deviceStringProperty(devID, selector: kAudioObjectPropertyName) ?? "Мікрофон \(devID)"
            let uid = deviceStringProperty(devID, selector: kAudioDevicePropertyDeviceUID) ?? "\(devID)"
            // Skip aggregate virtual taps created internally by macOS if unnamed
            if name.hasPrefix("CADefaultDeviceAggregate") { continue }
            result.append(AudioInputDevice(id: devID, uid: uid, name: name, isDefault: devID == defaultID))
        }

        result.sort { a, b in
            if a.isDefault != b.isDefault { return a.isDefault }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return result
    }

    private static func inputChannelCount(for deviceID: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let rawPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawPtr.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, rawPtr) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(rawPtr.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func deviceStringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfStr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &cfStr) == noErr,
              let unwrapped = cfStr?.takeUnretainedValue() else { return nil }
        return unwrapped as String
    }

    private func registerDeviceListeners() {
        let sysObj = AudioObjectID(kAudioObjectSystemObject)
        var devsAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(sysObj, &devsAddr, DispatchQueue.main) { [weak self] _, _ in
            self?.onDevicesChanged?()
        }
        AudioObjectAddPropertyListenerBlock(sysObj, &defAddr, DispatchQueue.main) { [weak self] _, _ in
            self?.onDevicesChanged?()
        }
    }

    // MARK: - Permission Check

    static func checkMicrophonePermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    // MARK: - Recording Lifecycle

    func startRecording(preferredUID: String) throws -> URL {
        stopEngineOnly()

        sampleLock.lock()
        recordedSamples16k.removeAll(keepingCapacity: true)
        recordedSamples16k.reserveCapacity(16_000 * 60)
        sampleLock.unlock()

        rollingBands = Array(repeating: 0.08, count: 28)
        didAttemptRecovery = false
        isCapturing = true
        startTime = Date()

        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("shepit_live_\(UUID().uuidString).wav")
        currentWAVURL = url

        try setupAndStartEngine(preferredUID: preferredUID)

        // Periodic flush to disk every 900 ms so realtime preview worker can read live audio
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 0.9, repeating: 0.9)
        timer.setEventHandler { [weak self] in
            self?.flushCurrentWAV()
        }
        timer.resume()
        flushTimer = timer

        // Anti-zombie USB mic watchdog after sleep/wake
        let wd = DispatchWorkItem { [weak self] in
            guard let self, self.isCapturing, !self.didAttemptRecovery else { return }
            self.sampleLock.lock()
            let count = self.recordedSamples16k.count
            let nonZero = self.recordedSamples16k.prefix(4000).contains { $0 != 0 }
            self.sampleLock.unlock()

            if count < 100 || !nonZero {
                self.didAttemptRecovery = true
                try? self.setupAndStartEngine(preferredUID: "")
            }
        }
        watchdogWorkItem = wd
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: wd)

        return url
    }

    private func setupAndStartEngine(preferredUID: String) throws {
        stopEngineInstance()

        let newEngine = AVAudioEngine()
        let inputNode = newEngine.inputNode

        if !preferredUID.isEmpty,
           let matched = Self.listInputDevices().first(where: { $0.uid == preferredUID }),
           let audioUnit = inputNode.audioUnit {
            var devID = matched.id
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &devID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        let hwFormat = inputNode.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 && hwFormat.channelCount > 0 else {
            throw NSError(domain: "ShepitAudio", code: -1, userInfo: [NSLocalizedDescriptionKey: "Мікрофон тимчасово недоступний"])
        }

        let srcRate = hwFormat.sampleRate
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer, sourceSampleRate: srcRate)
        }

        newEngine.prepare()
        try newEngine.start()
        engine = newEngine
    }

    func stopRecording() -> (wavURL: URL?, durationMs: Double) {
        isCapturing = false
        watchdogWorkItem?.cancel()
        watchdogWorkItem = nil
        flushTimer?.cancel()
        flushTimer = nil
        stopEngineInstance()

        let elapsedMs: Double
        if let st = startTime {
            elapsedMs = Date().timeIntervalSince(st) * 1000.0
        } else {
            elapsedMs = 0
        }

        flushCurrentWAV()
        return (currentWAVURL, elapsedMs)
    }

    func cancelRecording() {
        isCapturing = false
        watchdogWorkItem?.cancel()
        watchdogWorkItem = nil
        flushTimer?.cancel()
        flushTimer = nil
        stopEngineInstance()

        if let url = currentWAVURL {
            try? FileManager.default.removeItem(at: url)
        }
        currentWAVURL = nil
        sampleLock.lock()
        recordedSamples16k.removeAll()
        sampleLock.unlock()
    }

    private func stopEngineOnly() {
        watchdogWorkItem?.cancel()
        flushTimer?.cancel()
        stopEngineInstance()
    }

    private func stopEngineInstance() {
        if let eng = engine {
            eng.inputNode.removeTap(onBus: 0)
            eng.stop()
            engine = nil
        }
    }

    // MARK: - Real-time Resampling (any rate -> 16 kHz mono PCM16) & Waveform

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, sourceSampleRate: Double) {
        guard isCapturing else { return }
        let frameCount = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frameCount > 0, channels > 0 else { return }

        var mono = [Float](repeating: 0, count: frameCount)
        if let floatData = buffer.floatChannelData {
            if channels == 1 {
                let ch0 = floatData[0]
                for i in 0..<frameCount { mono[i] = ch0[i] }
            } else {
                let scale = 1.0 / Float(channels)
                for c in 0..<channels {
                    let ch = floatData[c]
                    for i in 0..<frameCount { mono[i] += ch[i] * scale }
                }
            }
        } else if let int16Data = buffer.int16ChannelData {
            let ch0 = int16Data[0]
            for i in 0..<frameCount { mono[i] = Float(ch0[i]) / 32768.0 }
        } else {
            return
        }

        // Compute RMS for live HUD waveform
        var sumSq: Float = 0
        for v in mono { sumSq += v * v }
        let rms = sqrt(sumSq / Float(frameCount))
        // Non-linear perceptual boost so normal conversational voice moves smoothly
        let normalizedLevel = CGFloat(min(1.0, max(0.06, pow(Double(rms) * 8.5, 0.62))))

        // Resample to 16000 Hz via linear interpolation
        let ratio = sourceSampleRate / 16000.0
        let outCount = max(1, Int(Double(frameCount) / ratio))
        var resampled = [Int16](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let srcPos = Double(i) * ratio
            let idx0 = min(frameCount - 1, Int(srcPos))
            let idx1 = min(frameCount - 1, idx0 + 1)
            let frac = Float(srcPos - Double(idx0))
            let sample = mono[idx0] * (1.0 - frac) + mono[idx1] * frac
            let clamped = max(-1.0, min(1.0, sample))
            resampled[i] = Int16(clamped * 32767.0)
        }

        sampleLock.lock()
        recordedSamples16k.append(contentsOf: resampled)
        sampleLock.unlock()

        let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCapturing else { return }
            self.rollingBands.removeFirst()
            self.rollingBands.append(normalizedLevel)
            self.onWaveformUpdate?(self.rollingBands, elapsed)
        }
    }

    func flushCurrentWAV() {
        guard let url = currentWAVURL else { return }
        sampleLock.lock()
        let snapshot = recordedSamples16k
        sampleLock.unlock()
        guard !snapshot.isEmpty else { return }

        let dataBytes = snapshot.count * 2
        var wav = Data(capacity: 44 + dataBytes)
        func putASCII(_ s: String) { wav.append(contentsOf: s.utf8) }
        func putU32(_ v: UInt32) { var le = v.littleEndian; wav.append(Data(bytes: &le, count: 4)) }
        func putU16(_ v: UInt16) { var le = v.littleEndian; wav.append(Data(bytes: &le, count: 2)) }

        putASCII("RIFF")
        putU32(UInt32(36 + dataBytes))
        putASCII("WAVE")
        putASCII("fmt ")
        putU32(16)
        putU16(1) // PCM
        putU16(1) // Mono
        putU32(16000)
        putU32(32000)
        putU16(2)
        putU16(16)
        putASCII("data")
        putU32(UInt32(dataBytes))

        snapshot.withUnsafeBytes { ptr in
            wav.append(contentsOf: ptr)
        }
        try? wav.write(to: url, options: .atomic)
    }
}
