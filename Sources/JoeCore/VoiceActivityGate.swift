import Foundation

/// Conservative energy/activity gate, not speech recognition or proof of the speaker's identity.
/// Keeps only frame statistics; silence must never be turned into a model-generated question.
public struct VoiceActivityGate: Sendable {
    private var energies: [Double] = []
    private var activeSeconds: Double = 0
    private var runSeconds: Double = 0
    private var longestRun: Double = 0
    public init() {}
    public mutating func observe(rms: Double, peak: Double, seconds: Double) {
        guard rms.isFinite, peak.isFinite, seconds.isFinite, rms >= 0, peak >= 0, seconds > 0 else { return }
        energies.append(rms)
        // About -45 dBFS RMS / -34 dBFS peak, sustained beyond an isolated click.
        if rms >= 0.0056 && peak >= 0.02 {
            activeSeconds += seconds; runSeconds += seconds; longestRun = max(longestRun, runSeconds)
        } else { runSeconds = 0 }
    }
    public var hasSpeechLikeActivity: Bool {
        guard energies.count >= 5, activeSeconds >= 0.18, longestRun >= 0.06 else { return false }
        let sorted = energies.sorted()
        let quiet = sorted[Int(Double(sorted.count - 1) * 0.2)]
        let loud = sorted[Int(Double(sorted.count - 1) * 0.9)]
        // Reject nearly stationary fan/hum noise even when its level exceeds the absolute floor.
        return loud > max(quiet * 1.6, 0.0056)
    }
}
