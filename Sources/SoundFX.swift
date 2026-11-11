import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

enum SoundCue {
    case start
    case stop
    case cancel
    case pasteDone
}

final class SoundFX {
    static let shared = SoundFX()

    private var players: [String: AVAudioPlayer] = [:]
    private let sampleRate = 48_000

    private init() {
        preloadSounds()
    }

    func play(_ cue: SoundCue, style: SoundEffectStyle, volume: Double) {
        guard style != .off, volume > 0.01 else { return }
        let key = "\(style.rawValue)_\(cueKey(cue))"
        guard let data = soundBuffers[key] else { return }
        do {
            let player = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
            player.volume = Float(min(1.0, max(0.0, volume)))
            player.prepareToPlay()
            player.play()
            players[key] = player
        } catch {}
    }

    private var soundBuffers: [String: Data] = [:]

    private func cueKey(_ cue: SoundCue) -> String {
        switch cue {
        case .start: return "start"
        case .stop: return "stop"
        case .cancel: return "cancel"
        case .pasteDone: return "done"
        }
    }

    private func preloadSounds() {
        // Classic: warm two-tone acoustic chime
        soundBuffers["classic_start"] = makeTwoToneWAV(f1: 523.25, f2: 783.99, dur1: 0.042, dur2: 0.058, amp: 0.28)
        soundBuffers["classic_stop"] = makeTwoToneWAV(f1: 659.25, f2: 493.88, dur1: 0.038, dur2: 0.052, amp: 0.24)
        soundBuffers["classic_cancel"] = makeTwoToneWAV(f1: 349.23, f2: 233.08, dur1: 0.045, dur2: 0.065, amp: 0.25)
        soundBuffers["classic_done"] = makeSingleToneWAV(freqStart: 880, freqEnd: 1046.5, duration: 0.038, amp: 0.14)

        // Simple: subtle minimal tactile pop
        soundBuffers["simple_start"] = makeSingleToneWAV(freqStart: 420, freqEnd: 600, duration: 0.040, amp: 0.22)
        soundBuffers["simple_stop"] = makeSingleToneWAV(freqStart: 540, freqEnd: 390, duration: 0.038, amp: 0.20)
        soundBuffers["simple_cancel"] = makeSingleToneWAV(freqStart: 300, freqEnd: 195, duration: 0.055, amp: 0.22)
        soundBuffers["simple_done"] = makeSingleToneWAV(freqStart: 760, freqEnd: 880, duration: 0.030, amp: 0.12)
    }

    private func makeSingleToneWAV(freqStart: Double, freqEnd: Double, duration: Double, amp: Double) -> Data {
        let count = Int(Double(sampleRate) * duration)
        var samples = [Int16](repeating: 0, count: count)
        var phase = 0.0
        for i in 0..<count {
            let t = Double(i) / Double(max(1, count - 1))
            let freq = freqStart + (freqEnd - freqStart) * t
            phase += 2.0 * Double.pi * freq / Double(sampleRate)
            let attack = min(1.0, Double(i) / (Double(sampleRate) * 0.004))
            let decay = pow(1.0 - t, 1.85)
            let val = sin(phase) * attack * decay * amp
            samples[i] = Int16(max(-1.0, min(1.0, val)) * 32767.0)
        }
        return encodeWAV(samples: samples)
    }

    private func makeTwoToneWAV(f1: Double, f2: Double, dur1: Double, dur2: Double, amp: Double) -> Data {
        let n1 = Int(Double(sampleRate) * dur1)
        let n2 = Int(Double(sampleRate) * dur2)
        let total = n1 + n2
        var samples = [Int16](repeating: 0, count: total)
        var phase = 0.0
        for i in 0..<total {
            let inFirst = i < n1
            let localIdx = inFirst ? i : (i - n1)
            let localLen = inFirst ? n1 : n2
            let freq = inFirst ? f1 : f2
            let t = Double(localIdx) / Double(max(1, localLen - 1))
            phase += 2.0 * Double.pi * freq / Double(sampleRate)
            let attack = min(1.0, Double(localIdx) / (Double(sampleRate) * 0.004))
            let decay = pow(1.0 - t, inFirst ? 1.5 : 2.1)
            let harmonic = sin(phase) * 0.85 + sin(phase * 2.0) * 0.15
            let val = harmonic * attack * decay * amp
            samples[i] = Int16(max(-1.0, min(1.0, val)) * 32767.0)
        }
        return encodeWAV(samples: samples)
    }

    private func encodeWAV(samples: [Int16]) -> Data {
        let dataBytes = samples.count * 2
        var header = Data()

        func appendASCII(_ s: String) { header.append(contentsOf: s.utf8) }
        func appendU32(_ v: UInt32) { var le = v.littleEndian; header.append(Data(bytes: &le, count: 4)) }
        func appendU16(_ v: UInt16) { var le = v.littleEndian; header.append(Data(bytes: &le, count: 2)) }

        appendASCII("RIFF")
        appendU32(UInt32(36 + dataBytes))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendU32(16)
        appendU16(1) // PCM
        appendU16(1) // Mono
        appendU32(UInt32(sampleRate))
        appendU32(UInt32(sampleRate * 2))
        appendU16(2)
        appendU16(16)
        appendASCII("data")
        appendU32(UInt32(dataBytes))

        samples.withUnsafeBytes { raw in
            header.append(contentsOf: raw)
        }
        return header
    }
}

// MARK: - Media Playback Pause / Mute Controller

final class MediaPlaybackController {
    static let shared = MediaPlaybackController()

    private typealias MRIsPlayingFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
    private typealias MRSendCmdFn = @convention(c) (UInt32, AnyObject?) -> Bool

    private var mrHandle: UnsafeMutableRawPointer?
    private var isPlayingFn: MRIsPlayingFn?
    private var sendCmdFn: MRSendCmdFn?

    private var didPauseMedia = false
    private var savedMuteState: UInt32?
    private var mutedDeviceID: AudioDeviceID = 0

    private init() {
        if let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY) {
            mrHandle = h
            if let sym1 = dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") {
                isPlayingFn = unsafeBitCast(sym1, to: MRIsPlayingFn.self)
            }
            if let sym2 = dlsym(h, "MRMediaRemoteSendCommand") {
                sendCmdFn = unsafeBitCast(sym2, to: MRSendCmdFn.self)
            }
        }
    }

    func beginRecording(behavior: PlaybackBehavior) {
        didPauseMedia = false
        savedMuteState = nil

        switch behavior {
        case .none:
            return
        case .pause:
            guard let isPlayingFn, let sendCmdFn else { return }
            isPlayingFn(DispatchQueue.main) { [weak self] playing in
                guard let self, playing else { return }
                // kMRPause = 1 (explicit pause, never starts playback if nothing was playing)
                if sendCmdFn(1, nil) {
                    self.didPauseMedia = true
                }
            }
        case .mute:
            setSystemOutputMute(true)
        }
    }

    func endRecording(behavior: PlaybackBehavior) {
        if didPauseMedia, let sendCmdFn {
            didPauseMedia = false
            // kMRPlay = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                _ = sendCmdFn(0, nil)
            }
        }
        if savedMuteState != nil {
            setSystemOutputMute(false)
        }
    }

    private func setSystemOutputMute(_ mute: Bool) {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else { return }

        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &muteAddr) else { return }

        if mute {
            var currentMute: UInt32 = 0
            var mSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &muteAddr, 0, nil, &mSize, &currentMute) == noErr {
                if currentMute == 0 {
                    savedMuteState = currentMute
                    mutedDeviceID = deviceID
                    var target: UInt32 = 1
                    AudioObjectSetPropertyData(deviceID, &muteAddr, 0, nil, mSize, &target)
                }
            }
        } else if let prev = savedMuteState, mutedDeviceID != 0 {
            var target = prev
            let mSize = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectSetPropertyData(mutedDeviceID, &muteAddr, 0, nil, mSize, &target)
            savedMuteState = nil
            mutedDeviceID = 0
        }
    }
}
