"""Test production WAV decoding/activity gate with synthetic files; no microphone or model access."""
from pathlib import Path
import argparse
import os
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--speech-fixture', type=Path, help='Optional known synthetic speech WAV expected to pass the activity gate')
args = parser.parse_args()
ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'ios/JoeMobile/Services/SpeechService.swift').read_text()
analyzer = source[source.index('enum RecordedAudioActivity {'):]
checks = r'''
import Foundation
import AVFoundation
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("JoeActivity-" + UUID().uuidString)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
func write(_ name: String, signal: (Int) -> Float) throws -> URL {
    let url = folder.appendingPathComponent(name + ".wav")
    let output = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false], commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32000)!
    buffer.frameLength = 32000
    for i in 0..<32000 { buffer.floatChannelData![0][i] = signal(i) }
    try output.write(from: buffer)
    return url
}
let silence = try write("silence") { _ in 0 }
let hum = try write("steady-hum") { Float(sin(Double($0) * 0.1) * 0.04) }
let click = try write("click") { $0 == 3000 ? 0.8 : 0 }
let modulated = try write("modulated") { i in
    guard i > 4000 && i < 24000 else { return 0 }
    return Float(sin(Double(i) * 0.1) * (0.04 + 0.16 * abs(sin(Double(i) * 0.0008))))
}
let a = try RecordedAudioActivity.hasSpeechLikeActivity(file: silence); precondition(!a)
let b = try RecordedAudioActivity.hasSpeechLikeActivity(file: hum); precondition(!b)
let c = try RecordedAudioActivity.hasSpeechLikeActivity(file: click); precondition(!c)
let d = try RecordedAudioActivity.hasSpeechLikeActivity(file: modulated); precondition(d)
if CommandLine.arguments.count > 1 {
    let spoken = try RecordedAudioActivity.hasSpeechLikeActivity(file: URL(fileURLWithPath: CommandLine.arguments[1]))
    precondition(spoken, "Synthetic spoken fixture was incorrectly rejected")
    print("Known synthetic spoken WAV accepted.")
}
print("Production PCM16 WAV gate: silence, stationary hum and click rejected; modulated activity accepted.")
'''
with tempfile.TemporaryDirectory(prefix='JoeActivityCheck-') as directory:
    work = Path(directory)
    (work / 'Analyzer.swift').write_text('import AVFoundation\nimport Foundation\n' + analyzer)
    (work / 'main.swift').write_text(checks)
    env = os.environ.copy()
    env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    subprocess.run(['swiftc', '-swift-version', '5', str(ROOT / 'Sources/JoeCore/VoiceActivityGate.swift'), str(work / 'Analyzer.swift'), str(work / 'main.swift'), '-o', str(work / 'check')], env=env, check=True)
    subprocess.run([str(work / 'check')] + ([str(args.speech_fixture.resolve(strict=True))] if args.speech_fixture else []), env=env, check=True)
