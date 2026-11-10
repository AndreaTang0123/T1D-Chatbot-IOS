import Foundation
import Observation
import LiteRTLM
import JoeCore

/// Owns native objects away from the main actor. Only Gemma is loaded; there is no Apple/cloud provider.
actor GemmaRuntime {
    private var engine: Engine?
    private var conversation: Conversation?
    private var epoch = 0
    func load(modelURL: URL, cacheURL: URL) async throws {
        guard engine == nil else { return }
        let ticket = epoch
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        let config = try EngineConfig(modelPath: modelURL.path, backend: .cpu(threadCount: 4),
                                      maxNumTokens: 4096, cacheDir: cacheURL.path)
        let candidate = Engine(engineConfig: config)
        try await candidate.initialize()
        try Task.checkCancellation()
        guard ticket == epoch else { throw CancellationError() }
        engine = candidate
    }
    func generate(prompt: String) async throws -> String {
        guard let engine else { throw AssistantFailure.assetsUnavailable }
        let sampler = try SamplerConfig(topK: 40, topP: 0.9, temperature: 0.3)
        let config = ConversationConfig(systemMessage: Message(JoeInstructions.combined + "\n\n" + GemmaPromptBuilder.adapterInstructions, role: .system),
            samplerConfig: sampler, thinkingConfig: ThinkingConfig(enableThinking: false), automaticToolCalling: false)
        let conversation = try await engine.createConversation(with: config)
        self.conversation = conversation
        defer { self.conversation = nil }
        return try await withTaskCancellationHandler {
            let response = try await conversation.sendMessage(Message(prompt), maxOutputTokens: 220,
                                                             thinkingConfig: ThinkingConfig(enableThinking: false))
            try Task.checkCancellation()
            return response.toString.trimmingCharacters(in: .whitespacesAndNewlines)
        } onCancel: { try? conversation.cancel() }
    }
    func unload() { epoch += 1; try? conversation?.cancel(); engine = nil }
}

@MainActor @Observable final class AssistantService: AssistantModelProvider {
    let installation = GemmaModelInstallation()
    private let runtime = GemmaRuntime()
    private(set) var isLoaded = false
    private(set) var isLoading = false
    private(set) var loadError: String?
    private var loadGeneration = UUID()
    private var inferenceTask: Task<String, Error>?
    var runtimeVersion: String {
        GemmaModelSpec.modelID + "; revision=" + GemmaModelSpec.revision + "; sha256=" + GemmaModelSpec.sha256
            + "; " + GemmaPromptBuilder.adapterVersion + "; " + GemmaModelSpec.runtimeVersion + "; CPU/4threads/context4096; " + ProcessInfo.processInfo.operatingSystemVersionString
    }
    func availability(language: ReplyLanguage) -> ModelAvailability {
        if isLoaded { return .available }
        return installation.isInstalled ? .modelNotReady : .modelMissing
    }
    var availability: String {
        if isLoading { return "Loading Gemma 4 E2B on this device…" }
        if isLoaded { return "Gemma 4 E2B ready · Local CPU inference" }
        return loadError ?? (installation.isInstalled ? "Model installed. Tap Load model to start local conversation." : "Download or import Gemma 4 E2B below. Apple Intelligence is not used.")
    }
    // Loading is explicit to avoid multi-GB initialization during app launch.
    func prewarm() {}
    func releasePrewarm() {}
    func loadModel() async {
        guard installation.isInstalled, !isLoading, !isLoaded else { return }
        let token = loadGeneration
        isLoading = true; loadError = nil; defer { isLoading = false }
        do {
            try await runtime.load(modelURL: installation.modelURL, cacheURL: installation.cacheURL)
            try Task.checkCancellation()
            guard token == loadGeneration else { await runtime.unload(); return }; isLoaded = true
        } catch is CancellationError { await runtime.unload(); isLoaded = false }
        catch { await runtime.unload(); isLoaded = false; loadError = "Gemma could not load. Free memory, close other apps, and retry; check the model installation status." }
    }
    func unloadModel() async {
        loadGeneration = UUID(); inferenceTask?.cancel()
        await runtime.unload(); isLoaded = false; loadError = nil
    }
    func respond(to request: AssistantModelRequest) async throws -> ModelReply {
        guard isLoaded else { throw AssistantFailure.assetsUnavailable }
        let current = request.snapshot.rechecked(at: Date())
        let refreshed = AssistantModelRequest(question: request.question, history: request.history, snapshot: current,
            decision: SafetyDecisionEngine(policy: current.policy).evaluate(cgm: current.currentGlucose, forecast: current.forecastResult), allowedTools: request.allowedTools)
        let payload: GemmaToolPayload
        do { payload = try GemmaPromptBuilder.build(request: refreshed) }
        catch { throw AssistantFailure.toolFailure }
        do {
            let runtime = self.runtime
            let task = Task { try await runtime.generate(prompt: payload.prompt) }
            inferenceTask = task; defer { inferenceTask = nil }
            let text = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard !text.isEmpty, !text.contains("<|channel>"), !text.contains("<start_of_turn>"), !text.contains("<end_of_turn>"), !text.contains("<|"), !text.contains("<tool_call>") else { throw AssistantFailure.generationError }
            return ModelReply(text: text, usedTools: payload.usedTools)
        } catch is CancellationError { throw AssistantFailure.cancelled }
        catch let failure as AssistantFailure { throw failure }
        catch { throw AssistantFailure.generationError }
    }
}

/// Model download/import is explicit. All generations after installation are offline.
@MainActor @Observable final class GemmaModelInstallation: NSObject, URLSessionDownloadDelegate {
    private(set) var isInstalled = false
    private(set) var isBusy = false
    private(set) var progress: Double = 0
    private(set) var status = "Checking model installation…"
    let modelURL: URL
    let cacheURL: URL
    private let root: URL
    private var transfer: URLSessionDownloadTask?
    private var verification: Task<Void, Never>?
    private var worker: Task<Void, Error>?
    private var generation = UUID()
    private var session: URLSession!
    override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("Gemma4E2B", isDirectory: true)
        modelURL = root.appendingPathComponent(GemmaModelSpec.filename)
        cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("GemmaRuntime", isDirectory: true)
        super.init()
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 7200; config.allowsCellularAccess = false
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        var backupRoot = root; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? backupRoot.setResourceValues(values)
        if FileManager.default.fileExists(atPath: modelURL.path) { verifyExisting() }
        else { status = "Not installed · 2.59 GB download over Wi-Fi" }
    }
    func download() {
        guard !isBusy else { return }
        guard hasSpace() else { status = GemmaInstallationError.insufficientSpace.localizedDescription; return }
        generation = UUID(); isBusy = true; progress = 0; status = "Downloading over Wi-Fi. Keep Joe open."
        let task = session.downloadTask(with: GemmaModelSpec.downloadURL); transfer = task; task.resume()
    }
    func importFile(_ source: URL) {
        guard !isBusy else { return }
        guard hasSpace() else { status = GemmaInstallationError.insufficientSpace.localizedDescription; return }
        generation = UUID(); let token = generation; isBusy = true; status = "Copying and verifying model…"
        verification = Task {
            let access = source.startAccessingSecurityScopedResource(); defer { if access { source.stopAccessingSecurityScopedResource() } }
            let staged = root.appendingPathComponent("import-\(token).litertlm")
            do {
                let work = Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    try FileManager.default.copyItem(at: source, to: staged)
                    try GemmaModelSpec.verify(file: staged)
                }
                worker = work
                try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard generation == token, !Task.isCancelled else { try? FileManager.default.removeItem(at: staged); return }
                try commit(staged); status = "Verified Gemma 4 E2B installed. Tap Load model."
            } catch { try? FileManager.default.removeItem(at: staged); if generation == token { status = error.localizedDescription } }
            if generation == token { isBusy = false; verification = nil }
        }
    }
    func cancel() {
        generation = UUID(); transfer?.cancel(); transfer = nil; verification?.cancel(); verification = nil; worker?.cancel(); worker = nil
        isBusy = false; progress = 0; status = isInstalled ? "Model installed." : "Installation canceled. You can retry."
    }
    func remove() {
        do { try removeFiles() } catch { status = "Could not remove model: " + error.localizedDescription }
    }
    private func removeFiles() throws {
        cancel(); try? FileManager.default.removeItem(at: cacheURL)
        if FileManager.default.fileExists(atPath: modelURL.path) { try FileManager.default.removeItem(at: modelURL) }
        isInstalled = false; status = "Model removed. Your health and chat data are unchanged."
    }
    private func hasSpace() -> Bool {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return (values?.volumeAvailableCapacityForImportantUsage ?? 0) >= 6_000_000_000
    }
    private func verifyExisting() {
        let token = generation; isBusy = true; status = "Verifying installed model…"
        verification = Task {
            do {
                let file = modelURL
                let work = Task.detached(priority: .utility) { try GemmaModelSpec.verify(file: file) }
                worker = work
                try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard generation == token else { return }; isInstalled = true; status = "Installed model verified. Tap Load model."
            } catch { if generation == token { isInstalled = false; status = error.localizedDescription } }
            if generation == token { isBusy = false; verification = nil }
        }
    }
    private func commit(_ staged: URL) throws {
        if FileManager.default.fileExists(atPath: modelURL.path) { _ = try FileManager.default.replaceItemAt(modelURL, withItemAt: staged) }
        else { try FileManager.default.moveItem(at: staged, to: modelURL) }
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: modelURL.path)
        isInstalled = true; progress = 1
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            guard self.transfer?.taskIdentifier == downloadTask.taskIdentifier else { return }
            self.progress = min(1, Double(totalBytesWritten) / Double(GemmaModelSpec.byteCount))
        }
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // URLSession deletes its temporary file when this callback returns; preserve it synchronously.
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("joe-gemma-\(UUID()).litertlm")
        do { try FileManager.default.moveItem(at: location, to: staged) }
        catch { Task { @MainActor in
            guard self.transfer?.taskIdentifier == downloadTask.taskIdentifier else { return }
            self.transfer = nil; self.status = "Could not preserve downloaded model."; self.isBusy = false
        }; return }
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode
        Task { @MainActor in
            guard self.transfer?.taskIdentifier == downloadTask.taskIdentifier else { try? FileManager.default.removeItem(at: staged); return }
            let token = self.generation; self.transfer = nil; self.status = "Verifying download SHA-256…"
            self.verification = Task {
                do {
                    guard code == 200 else { throw GemmaInstallationError.invalidResponse }
                    let work = Task.detached(priority: .utility) { try GemmaModelSpec.verify(file: staged) }
                    self.worker = work
                    try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                    guard self.generation == token else { try? FileManager.default.removeItem(at: staged); return }
                    try self.commit(staged); self.status = "Verified Gemma 4 E2B installed. Tap Load model."
                } catch { try? FileManager.default.removeItem(at: staged); if self.generation == token { self.status = error.localizedDescription } }
                if self.generation == token { self.isBusy = false; self.verification = nil }
            }
        }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard error != nil else { return }
        Task { @MainActor in
            guard self.transfer?.taskIdentifier == task.taskIdentifier else { return }
            self.transfer = nil; self.isBusy = false; self.status = "Download failed or was canceled. Check Wi-Fi and retry."
        }
    }
}
