import XCTest
@testable import JoeCore

@MainActor private final class ModelRuntimeProbe {
    enum Failure: Error { case load }
    var loads = 0
    var unloads = 0
    var failNext = false
    var delay: Duration = .milliseconds(15)
    var unloadDelay: Duration = .zero
    func load() async throws {
        loads += 1
        try await Task.sleep(for: delay)
        if failNext { failNext = false; throw Failure.load }
    }
    func unload() async { unloads += 1; try? await Task.sleep(for: unloadDelay) }
}
@MainActor final class LocalModelLifecycleTests: XCTestCase {
    private func manager(_ runtime: ModelRuntimeProbe, idle: TimeInterval = 300, background: TimeInterval = 120,
                         now: @escaping @MainActor () -> Date = { Date() }) -> LocalModelLifecycle {
        LocalModelLifecycle(idleSeconds: idle, backgroundSeconds: background, now: now,
                            load: { try await runtime.load() }, unload: { await runtime.unload() })
    }
    func testConcurrentRequestsShareOneLoadAndRetainUntilAllUsesFinish() async throws {
        let runtime = ModelRuntimeProbe(); let model = manager(runtime)
        XCTAssertEqual(runtime.loads, 0) // Constructing the app must not initialize weights.
        let first = Task { try await model.beginUse() }
        let second = Task { try await model.beginUse() }
        try await first.value; try await second.value
        XCTAssertEqual(runtime.loads, 1); XCTAssertEqual(model.activeUses, 2); XCTAssertEqual(model.phase, .ready)
        model.endUse(); XCTAssertEqual(model.activeUses, 1)
        model.endUse(); await model.release()
        XCTAssertEqual(runtime.unloads, 1); XCTAssertEqual(model.phase, .unloaded)
    }
    func testIdleReleaseAndAutomaticReloadOnNextRequest() async throws {
        let runtime = ModelRuntimeProbe(); let model = manager(runtime, idle: 0.02)
        try await model.beginUse(); model.endUse()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(model.phase, .unloaded); XCTAssertEqual(runtime.unloads, 1)
        try await model.beginUse()
        XCTAssertEqual(runtime.loads, 2); XCTAssertEqual(model.phase, .ready)
        model.endUse(); await model.release()
    }
    func testIdleTimerNeverUnloadsAnActiveGeneration() async throws {
        let runtime = ModelRuntimeProbe(); let model = manager(runtime, idle: 0.01)
        try await model.beginUse()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(model.phase, .ready); XCTAssertEqual(runtime.unloads, 0)
        model.endUse(); await model.release()
    }
    func testBriefBackgroundRetainsModelAndSuspendedTimerIsRecheckedOnReturn() async throws {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let runtime = ModelRuntimeProbe(); let model = manager(runtime, now: { clock })
        try await model.beginUse(); model.endUse()
        await model.setBackground(true)
        clock = clock.addingTimeInterval(30)
        await model.setBackground(false)
        XCTAssertEqual(model.phase, .ready); XCTAssertEqual(runtime.unloads, 0)
        await model.setBackground(true)
        clock = clock.addingTimeInterval(121)
        await model.setBackground(false)
        XCTAssertEqual(model.phase, .unloaded); XCTAssertEqual(runtime.unloads, 1)
    }
    func testFailureDoesNotPoisonFutureLoads() async throws {
        let runtime = ModelRuntimeProbe(); runtime.failNext = true
        let model = manager(runtime)
        do { try await model.beginUse(); XCTFail("Load should fail") } catch {}
        XCTAssertEqual(model.phase, .failed); XCTAssertEqual(model.activeUses, 0); XCTAssertNotNil(model.lastError)
        try await model.beginUse()
        XCTAssertEqual(model.phase, .ready); XCTAssertNil(model.lastError); XCTAssertEqual(runtime.loads, 2)
        model.endUse(); await model.release()
    }
    func testBackgroundCancelsLoadingAndDoesNotReloadUntilForeground() async throws {
        let runtime = ModelRuntimeProbe(); runtime.delay = .milliseconds(100)
        let model = manager(runtime)
        let pending = Task { try await model.beginUse() }
        for _ in 0..<100 { if model.phase == .loading { break }; await Task.yield() }
        await model.setBackground(true)
        do { try await pending.value; XCTFail("Background load should cancel") } catch {}
        XCTAssertEqual(model.phase, .unloaded); XCTAssertEqual(model.activeUses, 0)
        let before = runtime.loads
        do { try await model.beginUse(); XCTFail("No loading in background") } catch {}
        XCTAssertEqual(runtime.loads, before)
        await model.setBackground(false)
        try await model.beginUse(); model.endUse(); await model.release()
        XCTAssertEqual(runtime.loads, before + 1)
    }
    func testMemoryOrManualReleaseAllowsFreshNextUse() async throws {
        let runtime = ModelRuntimeProbe(); let model = manager(runtime)
        try await model.beginUse()
        await model.release() // Service cancels native generation before memory-pressure release.
        XCTAssertEqual(model.phase, .unloaded)
        model.endUse()
        try await model.beginUse(); XCTAssertEqual(runtime.loads, 2)
        model.endUse(); await model.release()
    }
    func testNewRequestWaitsForInProgressUnloadBeforeReloading() async throws {
        let runtime = ModelRuntimeProbe(); runtime.unloadDelay = .milliseconds(30)
        let model = manager(runtime)
        try await model.beginUse(); model.endUse()
        let release = Task { await model.release() }
        for _ in 0..<100 { if model.phase == .unloading { break }; await Task.yield() }
        let request = Task { try await model.beginUse() }
        await release.value; try await request.value
        XCTAssertEqual(model.phase, .ready); XCTAssertEqual(runtime.loads, 2); XCTAssertEqual(runtime.unloads, 1)
        model.endUse(); await model.release()
    }
    func testCanceledWaiterDoesNotCancelAnotherRequestSharedLoad() async throws {
        let runtime = ModelRuntimeProbe(); runtime.delay = .milliseconds(40)
        let model = manager(runtime)
        let canceled = Task { try await model.beginUse() }
        let other = Task { try await model.beginUse() }
        for _ in 0..<100 { if model.activeUses == 2 { break }; await Task.yield() }
        canceled.cancel()
        do { try await canceled.value; XCTFail("Canceled caller should stop") } catch {}
        try await other.value
        XCTAssertEqual(runtime.loads, 1); XCTAssertEqual(model.phase, .ready); XCTAssertEqual(model.activeUses, 1)
        model.endUse(); await model.release()
    }

    func testEnteringBackgroundDoesNotCountEarlierForegroundIdleAsBackgroundTime() async throws {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let runtime = ModelRuntimeProbe(); let model = manager(runtime, now: { clock })
        try await model.beginUse(); model.endUse()
        clock = clock.addingTimeInterval(200)
        await model.setBackground(true)
        clock = clock.addingTimeInterval(5)
        await model.setBackground(false)
        XCTAssertEqual(model.phase, .ready); XCTAssertEqual(runtime.unloads, 0)
        await model.release()
    }

}
