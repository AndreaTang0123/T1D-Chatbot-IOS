"""Run the production native runtime actor with synthetic persona cases on a Mac.

Requires full Xcode, Git LFS and the exact downloaded .litertlm model. This is
not an iPhone benchmark. No private configuration or health data is read.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--model', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--runtime-package', type=Path, help='Optional local checkout of LiteRT-LM v0.19.1')
args = parser.parse_args()
model = args.model.resolve(strict=True)
output = args.output.resolve()
output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='JoeGemmaSmoke-') as folder:
    work = Path(folder)
    sources = work / 'Sources' / 'Smoke'
    sources.mkdir(parents=True)
    dependency = (f'.package(path: {json.dumps(str(args.runtime_package.resolve()))})'
                  if args.runtime_package else
                  '.package(url: "https://github.com/google-ai-edge/LiteRT-LM", exact: "0.19.1")')
    (work / 'Package.swift').write_text(f'''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Smoke", platforms: [.macOS(.v14)], dependencies: [
    {dependency}, .package(path: {json.dumps(str(ROOT))})
], targets: [.executableTarget(name: "Smoke", dependencies: [
    .product(name: "LiteRTLM", package: "LiteRT-LM"),
    .product(name: "JoeCore", package: "T1D-Chatbot-IOS")
], swiftSettings: [.swiftLanguageMode(.v5)])])
''')
    service = (ROOT / 'ios/JoeMobile/Services/AssistantService.swift').read_text()
    actor = service[service.index('actor GemmaRuntime'):service.index('@MainActor @Observable')]
    (sources / 'Runtime.swift').write_text('import Foundation\nimport LiteRTLM\nimport JoeCore\n' + actor)
    (sources / 'Smoke.swift').write_text((ROOT / 'scripts/fixtures/GemmaRuntimeSmoke.swift').read_text())
    env = os.environ.copy()
    env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    subprocess.run(['swift', 'run', '--package-path', str(work), '-c', 'release', 'Smoke', str(model), str(output)], env=env, check=True)
print(f'Synthetic Mac runtime report: {output}')
