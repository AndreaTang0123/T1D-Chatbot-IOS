import AVFoundation

@MainActor final class SpeechService {
    private let synthesizer = AVSpeechSynthesizer()
    func speak(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        // Do not initiate network voice downloads. Use only an already installed system voice.
        let voices = AVSpeechSynthesisVoice.speechVoices()
        guard let voice = voices.first(where: { $0.language.hasPrefix("en") }) ?? voices.first else { return }
        let utterance = AVSpeechUtterance(string: text); utterance.voice = voice
        synthesizer.speak(utterance)
    }
    func stop() { synthesizer.stopSpeaking(at: .immediate) }
}
