import AVFoundation

@MainActor final class SpeechService {
    private let synthesizer = AVSpeechSynthesizer()
    func speak(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        // Do not initiate network voice downloads. Use only an already installed system voice.
        let voices = AVSpeechSynthesisVoice.speechVoices()
        guard let voice = voices.first(where: { $0.language.hasPrefix("en") }) ?? voices.first else { return }
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? audio.setActive(true)
        let utterance = AVSpeechUtterance(string: text); utterance.voice = voice
        synthesizer.speak(utterance)
    }
    func stop() { synthesizer.stopSpeaking(at: .immediate) }
}

import Speech
import Observation

/// Captures audio only while held. Recognition is strictly on-device; audio is never uploaded.
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
    @ObservationIgnored private var hasTap = false
    @ObservationIgnored private var held = false
    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var finishTask: Task<Void, Never>?
    @ObservationIgnored private var limitTask: Task<Void, Never>?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?

    init() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording || self.isFinishing else { return }
                self.message = "Recording interrupted. Review your text before sending."
                self.cancel()
            }
        }
    }
    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }
    func press() async {
        held = true
        guard !isPreparing, !isRecording, !isFinishing else { return }
        isPreparing = true; message = nil
        defer { isPreparing = false }
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard authorization == .authorized else {
            message = "Enable Speech Recognition for Joe in iPhone Settings to use voice input."; held = false; return
        }
        let microphone = await AVAudioApplication.requestRecordPermission()
        guard microphone else {
            message = "Enable Microphone access for Joe in iPhone Settings to use voice input."; held = false; return
        }
        guard held, !Task.isCancelled else {
            message = "Voice input is ready. Hold the microphone again to talk."; return
        }
        guard let local = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), local.isAvailable,
              local.supportsOnDeviceRecognition else {
            message = "On-device English speech recognition is unavailable. You can still type a message."
            held = false; return
        }
        let token = UUID(); sessionID = token; transcript = ""; recognizer = local
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .duckOthers])
            try audio.setActive(true)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                message = "No microphone input is available."; cancel(); return
            }
            let buffer = SFSpeechAudioBufferRecognitionRequest()
            buffer.requiresOnDeviceRecognition = true
            buffer.shouldReportPartialResults = true
            buffer.contextualStrings = ["Nightscout", "glucose", "insulin", "bolus", "Joe"]
            request = buffer
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { pcm, _ in buffer.append(pcm) }
            hasTap = true
            recognition = local.recognitionTask(with: buffer) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal ?? false
                let failed = error != nil
                Task { @MainActor in
                    guard let self, self.sessionID == token else { return }
                    if let text { self.transcript = text }
                    if failed || final {
                        if failed && self.transcript.isEmpty { self.message = "Speech could not be transcribed. Try again or type a message." }
                        self.cleanup()
                    }
                }
            }
            engine.prepare(); try engine.start(); isRecording = true
            limitTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(55))
                guard !Task.isCancelled, let self, self.sessionID == token else { return }
                self.message = "Recording limit reached. Review your text before sending."
                self.release()
            }
        } catch {
            message = "Unable to start the microphone. You can still type a message."
            cleanup()
        }
    }
    func release() {
        held = false
        guard isRecording else { return }
        stopCapture(); request?.endAudio(); isRecording = false; isFinishing = true
        let token = sessionID
        finishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self, self.sessionID == token else { return }
            if self.transcript.isEmpty { self.message = "No speech detected. Hold the microphone and try again." }
            self.cleanup()
        }
    }
    func cancel() { held = false; cleanup() }
    private func stopCapture() {
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
    }
    private func cleanup() {
        sessionID = UUID(); held = false; stopCapture()
        request?.endAudio(); recognition?.cancel(); recognition = nil; request = nil; recognizer = nil
        finishTask?.cancel(); finishTask = nil; limitTask?.cancel(); limitTask = nil
        isRecording = false; isFinishing = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
