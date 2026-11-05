import AVFoundation
import Speech
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
@MainActor @Observable final class SpeechInputService {
    private(set) var transcript = ""
    private(set) var isPreparing = false
    private(set) var isRecording = false
    private(set) var isFinishing = false
    private(set) var message: String?
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognition: SFSpeechRecognitionTask?
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var gate = VoiceCaptureGate()
    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var hasTap = false
    @ObservationIgnored private var ownsAudioSession = false
    @ObservationIgnored private var permissionTask: Task<Void, Never>?
    @ObservationIgnored private var finishTask: Task<Void, Never>?
    @ObservationIgnored private var limitTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    init() {
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
                    self.message = "Audio was interrupted. Review your text before sending."; self.cancel()
                }
            })
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    func press(locale: String) {
        guard !isPreparing, !isRecording, !isFinishing else { return }
        let attempt = gate.begin(); isPreparing = true; message = nil
        permissionTask = Task { [weak self] in
            guard let self else { return }
            let authorization = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard self.gate.accepts(attempt), !Task.isCancelled else { return }
            guard authorization == .authorized else {
                self.message = "Enable Speech Recognition for Joe in iPhone Settings."; self.isPreparing = false; self.gate.cancel(); return
            }
            let microphone = await AVAudioApplication.requestRecordPermission()
            guard self.gate.accepts(attempt), !Task.isCancelled else { return }
            self.isPreparing = false
            guard microphone else { self.message = "Enable Microphone access for Joe in iPhone Settings."; self.gate.cancel(); return }
            guard self.gate.mayStart(attempt) else { self.message = "Permissions are ready. Hold the microphone again to talk."; return }
            self.start(locale: locale)
        }
    }
    private func start(locale: String) {
        guard let local = SFSpeechRecognizer(locale: Locale(identifier: locale)), local.isAvailable, local.supportsOnDeviceRecognition else {
            message = "On-device recognition is unavailable for the selected language. Change Voice language in Settings or type your message."
            gate.cancel(); return
        }
        let token = UUID(); sessionID = token; transcript = ""; recognizer = local
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try audio.setActive(true); ownsAudioSession = true
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { message = "No microphone input is available."; cleanup(); return }
            let buffer = SFSpeechAudioBufferRecognitionRequest()
            buffer.requiresOnDeviceRecognition = true; buffer.shouldReportPartialResults = true
            buffer.contextualStrings = ["Nightscout", "glucose", "insulin", "bolus", "Joe"]
            request = buffer
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { pcm, _ in buffer.append(pcm) }; hasTap = true
            recognition = local.recognitionTask(with: buffer) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal ?? false
                let failed = error != nil
                Task { @MainActor in
                    guard let self, self.sessionID == token else { return }
                    if let text { self.transcript = text }
                    if final || failed {
                        if failed && self.transcript.isEmpty { self.message = "No transcription was returned. Check your selected voice language and try again." }
                        self.cleanup()
                    }
                }
            }
            engine.prepare(); try engine.start(); isRecording = true
            limitTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(55))
                guard !Task.isCancelled, let self, self.sessionID == token else { return }
                self.message = "Recording limit reached. Review your message before sending."; self.release()
            }
        } catch { message = "The microphone could not start. Check your audio route and try again."; cleanup() }
    }
    func release() {
        gate.release()
        guard isRecording else { return }
        stopCapture(); request?.endAudio(); isRecording = false; isFinishing = true
        let token = sessionID
        // Do not cancel recognition immediately after ending the audio; await the final result.
        finishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.sessionID == token else { return }
            if self.transcript.isEmpty { self.message = "No speech detected. Try again or type your message." }
            self.cleanup()
        }
    }
    func cancel() {
        gate.cancel(); permissionTask?.cancel(); permissionTask = nil; isPreparing = false; cleanup()
    }
    private func stopCapture() {
        if engine.isRunning { engine.stop() }
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
    }
    private func cleanup() {
        sessionID = UUID(); gate.cancel(); stopCapture()
        request?.endAudio(); recognition?.cancel(); recognition = nil; request = nil; recognizer = nil
        finishTask?.cancel(); finishTask = nil; limitTask?.cancel(); limitTask = nil
        isRecording = false; isFinishing = false
        if ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudioSession = false
        }
    }
}
