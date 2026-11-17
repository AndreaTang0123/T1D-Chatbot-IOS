import AVFoundation
import Observation
import JoeCore

@MainActor @Observable final class SpeechService: NSObject, AVAudioPlayerDelegate {
    private(set) var isSpeaking = false
    private(set) var message: String?
    private(set) var status = "Ready"
    private(set) var outputDescription = "Tap Test sound to check the current output."
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var renderer: SpeechPCMRenderer?
    @ObservationIgnored private var temporaryURL: URL?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    override init() {
        super.init()
        // Speech is rendered to PCM; actual playback uses AVAudioPlayer and our playback session.
        synthesizer.usesApplicationAudioSession = false
    }
    func speak(_ text: String) {
        stop()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let language = value.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) } ? "zh-CN" : "en-US"
        guard let voice = AVSpeechSynthesisVoice(language: language) else {
            message = "A voice for this language is unavailable. Download a system voice in iPhone Accessibility settings."; return
        }
        let token = UUID(); generation = token; message = nil; status = "Preparing voice…"; isSpeaking = true
        let sink = SpeechPCMRenderer(); renderer = sink
        let utterance = AVSpeechUtterance(string: value)
        utterance.voice = voice; utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.write(utterance) { [weak self] buffer in
            guard let outcome = sink.append(buffer) else { return }
            Task { @MainActor in
                guard let self, self.generation == token else { sink.cancel(); return }
                self.timeout?.cancel(); self.timeout = nil
                switch outcome {
                case .success(let url): self.play(url: url, label: "Playing voice")
                case .failure:
                    self.isSpeaking = false; self.status = "Voice unavailable"
                    self.message = "The system voice produced no usable audio. Download or select a system voice in iPhone Accessibility settings, then try Test voice again."
                }
            }
        }
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, self.generation == token else { return }
            self.stop(); self.status = "Voice timed out"
            self.message = "Voice synthesis did not finish. Try a short message or download a system voice for this language."
        }
    }
    func testSound() {
        stop(); message = nil
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
            let count: AVAudioFrameCount = 9600
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
            buffer.frameLength = count
            let data = buffer.floatChannelData![0]
            for index in 0..<Int(count) {
                let envelope = min(1, min(Double(index), Double(Int(count) - index)) / 500)
                data[index] = Float(sin(Double(index) * 2 * .pi * 660 / 24000) * 0.2 * envelope)
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("joe-speech-\(UUID().uuidString).caf")
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                try file.write(from: buffer)
            }
            play(url: url, label: "Playing test sound")
        } catch { status = "Sound test failed"; message = "Unable to create the local test sound." }
    }
    private func play(url: URL, label: String) {
        temporaryURL = url
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .spokenAudio, options: [])
            try audio.setActive(true)
            outputDescription = audio.currentRoute.outputs.map(\.portName).joined(separator: ", ")
                + " · Media volume " + String(Int(audio.outputVolume * 100)) + "%"
            let playback = try AVAudioPlayer(contentsOf: url)
            playback.delegate = self; playback.volume = 1
            player = playback
            guard playback.prepareToPlay(), playback.play() else { throw PlaybackFailure() }
            isSpeaking = true; status = label
            if audio.outputVolume == 0 { message = "Media volume is zero. Press the iPhone volume-up button while the sound is playing." }
        } catch {
            stop(); status = "Playback failed"
            message = "Audio could not start. Try Test sound and check the iPhone output route."
        }
    }
    func stop() {
        generation = UUID(); timeout?.cancel(); timeout = nil
        synthesizer.stopSpeaking(at: .immediate)
        player?.stop(); player = nil; renderer?.cancel(); renderer = nil
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }; temporaryURL = nil
        isSpeaking = false; status = "Ready"
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let active = self.player, ObjectIdentifier(active) == identity else { return }
            self.stop(); self.status = flag ? "Playback finished" : "Playback failed"
            if !flag { self.message = "Audio playback did not complete. Try Test sound again." }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let active = self.player, ObjectIdentifier(active) == identity else { return }
            self.stop(); self.status = "Audio decoding failed"; self.message = "The generated voice could not be played. Try Test voice again."
        }
    }
    private struct PlaybackFailure: Error {}
}

/// Serializes synthesis callbacks, validates non-silent PCM, and removes temporary speech on cancel.
final class SpeechPCMRenderer: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var finished = false
    private var frames: AVAudioFramePosition = 0
    private var peak: Float = 0
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("joe-speech-\(UUID().uuidString).caf")
    func append(_ audio: AVAudioBuffer) -> Result<URL, any Error>? {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return nil }
        guard let pcm = audio as? AVAudioPCMBuffer else { return nil }
        do {
            if pcm.frameLength == 0 {
                finished = true; file = nil
                guard frames > 0, peak > 0.00001 else { throw EmptyAudio() }
                return .success(url)
            }
            if file == nil {
                file = try AVAudioFile(forWriting: url, settings: pcm.format.settings,
                                       commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
                try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            }
            if let channels = pcm.floatChannelData {
                for index in 0..<Int(pcm.frameLength) { peak = max(peak, abs(channels[0][index])) }
            } else if let channels = pcm.int16ChannelData {
                for index in 0..<Int(pcm.frameLength) { peak = max(peak, Float(abs(Int(channels[0][index]))) / 32768) }
            }
            try file?.write(from: pcm); frames += AVAudioFramePosition(pcm.frameLength)
            return nil
        } catch {
            finished = true; file = nil; try? FileManager.default.removeItem(at: url)
            return .failure(error)
        }
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        finished = true; file = nil; try? FileManager.default.removeItem(at: url)
    }
    private struct EmptyAudio: Error {}
}

/// Audio stays local. Authorization, capture, and finalization have separate cancellation guards.
/// Captures WAV audio only. Speech understanding belongs to Gemma, not Apple Speech.
@MainActor @Observable final class SpeechInputService {
    var onSubmitted: ((UUID) -> Void)?
    var onRecognized: ((UUID, String) -> Void)?
    var onFailed: ((UUID, String) -> Void)?
    var onCancelled: ((UUID) -> Void)?
    private(set) var transcript = ""
    private(set) var isPreparing = false
    private(set) var isRecording = false
    private(set) var isFinishing = false
    private(set) var message: String?
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var file: URL?
    @ObservationIgnored private var gate = VoiceCaptureGate()
    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var permissionTask: Task<Void, Never>?
    @ObservationIgnored private var finishTask: Task<Void, Never>?
    @ObservationIgnored private var limitTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var understand: (@MainActor (URL, String) async throws -> String)?
    @ObservationIgnored private var locale = "en-US"
    @ObservationIgnored private var ownsAudioSession = false
    init() {
        // This service is created once before capture; remove leftovers from a terminated process.
        if let files = try? FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil) {
            for url in files where url.lastPathComponent.hasPrefix("JoeVoice-") && url.pathExtension == "wav" {
                try? FileManager.default.removeItem(at: url)
            }
        }
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
                let interruption = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
                let stop = name == AVAudioSession.interruptionNotification
                    ? interruption == AVAudioSession.InterruptionType.began.rawValue
                    : reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                guard stop else { return }
                Task { @MainActor in
                    guard let self, self.isRecording || self.isFinishing else { return }
                    self.cancel(); self.message = "Audio was interrupted. Record again or type your message."
                }
            })
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    func press(locale: String, understand: @escaping @MainActor (URL, String) async throws -> String) {
        guard !isPreparing, !isRecording, !isFinishing else { return }
        let attempt = gate.begin(); isPreparing = true; message = nil
        self.locale = locale; self.understand = understand
        permissionTask = Task { [weak self] in
            guard let self else { return }
            let microphone = await AVAudioApplication.requestRecordPermission()
            guard self.gate.accepts(attempt), !Task.isCancelled else { return }
            self.isPreparing = false
            guard microphone else { self.message = "Enable Microphone access for Joe in iPhone Settings."; self.gate.cancel(); return }
            guard self.gate.mayStart(attempt) else { self.message = "Microphone is ready. Hold again to talk."; return }
            self.start()
        }
    }
    private func start() {
        let token = UUID(); sessionID = token; transcript = ""
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try audio.setActive(true); ownsAudioSession = true
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("JoeVoice-\(UUID().uuidString).wav")
            file = url
            let recording = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000.0,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
            ])
            recorder = recording
            guard recording.prepareToRecord(), recording.record() else { throw GemmaAudioError.unavailable }
            isRecording = true
            limitTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(GemmaAudioQuestion.maximumSeconds))
                guard !Task.isCancelled, let self, self.sessionID == token else { return }
                self.message = "20-second limit reached. Gemma will process this recording."; self.release()
            }
        } catch { cancel(); message = "The microphone could not start. Check your audio route or type your message." }
    }
    func release() {
        gate.release()
        guard isRecording, let url = file, let understand else { return }
        let duration = recorder?.currentTime ?? 0
        recorder?.stop(); recorder = nil; file = nil
        limitTask?.cancel(); limitTask = nil
        deactivateAudio()
        isRecording = false
        guard duration >= 0.3 else { try? FileManager.default.removeItem(at: url); message = "Recording was too short. Hold to talk again."; return }
        isFinishing = true
        let token = sessionID; let language = locale
        onSubmitted?(token)
        finishTask = Task { [weak self] in
            // Keep the file alive until native inference/cancellation has finished consuming it.
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let active = try await Task.detached(priority: .userInitiated) {
                    try RecordedAudioActivity.hasSpeechLikeActivity(file: url)
                }.value
                try Task.checkCancellation()
                guard active else { throw GemmaAudioError.noSpeech }
                let text = try GemmaAudioQuestion.checkedText(await understand(url, language))
                try Task.checkCancellation()
                guard let self, self.sessionID == token else { return }
                self.transcript = text; self.message = nil
                self.isFinishing = false; self.finishTask = nil; self.understand = nil
                self.onRecognized?(token, text)
            } catch {
                guard let self, self.sessionID == token, !Task.isCancelled else { return }
                let detail = (error as? GemmaAudioError)?.errorDescription ?? "Gemma could not process this recording. Try again or type your message."
                self.message = detail
                self.isFinishing = false; self.finishTask = nil; self.understand = nil
                self.onFailed?(token, detail)
            }
            guard let self, self.sessionID == token else { return }
            self.isFinishing = false; self.finishTask = nil; self.understand = nil
        }
    }
    func cancel() {
        let cancelledID = sessionID
        sessionID = UUID(); gate.cancel()
        permissionTask?.cancel(); permissionTask = nil
        finishTask?.cancel(); finishTask = nil; limitTask?.cancel(); limitTask = nil
        recorder?.stop(); recorder = nil
        if let file { try? FileManager.default.removeItem(at: file) }; file = nil
        isPreparing = false; isRecording = false; isFinishing = false; understand = nil
        deactivateAudio()
        onCancelled?(cancelledID)
    }
    private func deactivateAudio() {
        if ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudioSession = false
        }
    }
}

/// Decode the completed WAV off the main actor before any model loading/inference.
enum RecordedAudioActivity {
    static func hasSpeechLikeActivity(file url: URL) throws -> Bool {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard format.sampleRate > 0, format.channelCount == 1 else { return false }
        let frameCount = AVAudioFrameCount(max(1, Int(format.sampleRate * 0.02)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return false }
        var activity = VoiceActivityGate()
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: frameCount)
            let count = Int(buffer.frameLength)
            guard count > 0, let samples = buffer.floatChannelData?[0] else { break }
            var squares: Double = 0; var peak: Double = 0
            for i in 0..<count {
                let value = Double(samples[i])
                squares += value * value; peak = max(peak, abs(value))
            }
            activity.observe(rms: sqrt(squares / Double(count)), peak: peak, seconds: Double(count) / format.sampleRate)
        }
        return activity.hasSpeechLikeActivity
    }
}
