"""Run the same core tests on Command Line Tools machines without XCTest (full Xcode: swift test)."""
from pathlib import Path
import re,subprocess,tempfile
root=Path(__file__).resolve().parents[1]
source=(root/'Tests/JoeCoreTests/JoeCoreTests.swift').read_text()
source=source.replace('import XCTest','import Foundation').replace('@testable import JoeCore','').replace(': XCTestCase','')
source=source.replace('Bundle.module.url(forResource: "feature_parity", withExtension: "json", subdirectory: "Fixtures")!',
                      'URL(fileURLWithPath: '+__import__('json').dumps(str(root/'Tests/JoeCoreTests/Fixtures/feature_parity.json'))+')')
shim='''
func XCTAssertTrue(_ value: @autoclosure () -> Bool) { precondition(value()) }
func XCTAssertFalse(_ value: @autoclosure () -> Bool) { precondition(!value()) }
func XCTAssertNil<T>(_ value: @autoclosure () -> T?) { precondition(value() == nil) }
func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T) { precondition(actual == expected, "Mismatch: \\(actual) != \\(expected)") }
func XCTAssertEqual(_ actual: Double, _ expected: Double, accuracy: Double) { precondition(abs(actual-expected) <= accuracy) }
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ handler: (Error) -> Void = { _ in }) {
    do { _ = try expression(); fatalError("Expected error") } catch { handler(error) }
}
'''
methods=re.findall(r'func (test\w+)\(\)( throws)?',source)
with tempfile.TemporaryDirectory(prefix='joe-core-') as tmp:
    main=Path(tmp)/'main.swift'
    main.write_text(shim+source+'\nlet suite = JoeCoreTests()\n'+''.join(f'{"try " if throwing else ""}suite.{name}()\n' for name,throwing in methods)+f'print("Passed {len(methods)} core checks")\n')
    binary=Path(tmp)/'checks'
    subprocess.run(['swiftc',*map(str,sorted((root/'Sources/JoeCore').glob('*.swift'))),str(main),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
