"""Check the production PCM writer on macOS without playing sound or accessing a microphone."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
source = (root/'ios/JoeMobile/Services/SpeechService.swift').read_text()
writer = source[source.index('final class SpeechPCMRenderer:'):source.index('/// Audio stays local.')]
# iOS file-protection attributes are unavailable on macOS; keep all audio logic unchanged.
writer = '\n'.join(line for line in writer.splitlines() if 'FileProtectionType.' not in line)
checks = r'''
let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
func buffer(_ count: AVAudioFrameCount, silent: Bool = false) -> AVAudioPCMBuffer {
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(1, count))!
    pcm.frameLength = count
    for i in 0..<Int(count) { pcm.floatChannelData![0][i] = silent ? 0 : Float(sin(Double(i)*0.2) * 0.2) }
    return pcm
}
let writer = SpeechPCMRenderer()
precondition(writer.append(buffer(4800)) == nil)
guard case .success(let url)? = writer.append(buffer(0)) else { fatalError("No rendered audio") }
let file = try AVAudioFile(forReading: url)
precondition(file.length == 4800)
precondition(FileManager.default.fileExists(atPath: url.path))
writer.cancel()
precondition(!FileManager.default.fileExists(atPath: url.path))
let silent = SpeechPCMRenderer()
_ = silent.append(buffer(480, silent: true))
guard case .failure? = silent.append(buffer(0)) else { fatalError("Silent synthesis must be rejected") }
let empty = SpeechPCMRenderer()
guard case .failure? = empty.append(buffer(0)) else { fatalError("Empty synthesis must be rejected") }
let canceled = SpeechPCMRenderer()
canceled.cancel()
precondition(canceled.append(buffer(480)) == nil)
precondition(canceled.append(buffer(0)) == nil)
print("Passed 4 speech renderer checks: playable PCM, silence, empty output, cancellation")
'''
with tempfile.TemporaryDirectory(prefix='joe-speech-check-') as tmp:
    path = Path(tmp)/'main.swift'
    path.write_text('import Foundation\nimport AVFoundation\n'+writer+'\n'+checks)
    binary = Path(tmp)/'checks'
    subprocess.run(['swiftc',str(path),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
