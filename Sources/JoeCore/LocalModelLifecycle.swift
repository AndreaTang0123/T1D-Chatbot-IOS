import Foundation
import Observation

/// Main-actor state machine; heavyweight loading/unloading is provided by an off-main runtime.
@MainActor @Observable public final class LocalModelLifecycle {
    public enum Phase: Equatable { case unloaded, loading, ready, unloading, failed }
    public private(set) var phase: Phase = .unloaded
    public private(set) var lastError: String?
    public private(set) var activeUses = 0
    public private(set) var isBackground = false
    private let load: @MainActor () async throws -> Void
    private let unload: @MainActor () async -> Void
    private let now: @MainActor () -> Date
    private let idleSeconds: TimeInterval
    private let backgroundSeconds: TimeInterval
    private var idleSince: Date?
    private var backgroundSince: Date?
    private var loadTask: Task<Void, Error>?
    private var unloadTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var loadID = UUID()

    public init(idleSeconds: TimeInterval = 300, backgroundSeconds: TimeInterval = 120,
                now: @escaping @MainActor () -> Date = { Date() },
                load: @escaping @MainActor () async throws -> Void,
                unload: @escaping @MainActor () async -> Void) {
        self.idleSeconds = idleSeconds; self.backgroundSeconds = backgroundSeconds
        self.now = now; self.load = load; self.unload = unload
    }
    /// Call endUse exactly once after a successful beginUse, including errors/cancellation.
    public func beginUse() async throws {
        activeUses += 1; idleTask?.cancel()
        do {
            if let task = unloadTask { await task.value }
            try Task.checkCancellation()
            if isBackground { throw CancellationError() }
            if phase != .ready {
                if loadTask == nil {
                    loadID = UUID(); phase = .loading; lastError = nil
                    let load = self.load
                    loadTask = Task { try await load() }
                }
                let id = loadID
                guard let task = loadTask else { throw CancellationError() }
                do {
                    try await task.value
                    guard id == loadID, !task.isCancelled else { throw CancellationError() }
                    phase = .ready; loadTask = nil
                } catch {
                    if id == loadID {
                        loadTask = nil
                        if error is CancellationError { phase = .unloaded }
                        else { phase = .failed; lastError = "Gemma could not load. Free memory and retry; check the model installation status." }
                    }
                    throw error
                }
            }
            try Task.checkCancellation()
            guard !isBackground, phase == .ready else { throw CancellationError() }
        } catch { endUse(); throw error }
    }
    public func endUse() {
        activeUses = max(0, activeUses - 1)
        if activeUses == 0 { idleSince = now(); scheduleIdleRelease() }
    }
    public func release() async {
        if let task = unloadTask { await task.value; return }
        idleTask?.cancel(); loadID = UUID()
        let pendingLoad = loadTask; pendingLoad?.cancel(); loadTask = nil
        phase = .unloading
        let unload = self.unload
        let task = Task { @MainActor in
            if let pendingLoad { _ = await pendingLoad.result }
            await unload()
            // Finalize before waking waiters, so a new load cannot race a stale release continuation.
            self.phase = .unloaded; self.lastError = nil; self.unloadTask = nil
        }
        unloadTask = task
        await task.value
    }
    public func setBackground(_ background: Bool) async {
        let wasBackground = isBackground
        let previousBackgroundStart = backgroundSince
        isBackground = background; idleTask?.cancel()
        if background && !wasBackground { backgroundSince = now() }
        if !background { backgroundSince = nil }
        // Do not complete a multi-GB initialization while being suspended.
        if background && phase == .loading { await release(); return }
        if !background && wasBackground && activeUses == 0, let idleSince, let previousBackgroundStart,
           now().timeIntervalSince(max(idleSince, previousBackgroundStart)) >= backgroundSeconds, phase == .ready {
            await release(); return
        }
        scheduleIdleRelease()
    }
    private func scheduleIdleRelease() {
        idleTask?.cancel()
        guard activeUses == 0, phase == .ready, let idleSince else { return }
        let reference = isBackground ? max(idleSince, backgroundSince ?? idleSince) : idleSince
        let remaining = max(0, (isBackground ? backgroundSeconds : idleSeconds) - now().timeIntervalSince(reference))
        idleTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            guard !Task.isCancelled, let self, self.activeUses == 0, self.phase == .ready else { return }
            await self.release()
        }
    }
}
