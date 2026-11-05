import Foundation
import FoundationModels
import JoeCore

@Generable struct SnapshotArguments { }
struct StructuredToolOutput<Value: Encodable & Sendable>: PromptRepresentable {
    let value: Value
    let json: String
    init(_ value: Value) throws { self.value = value; json = try ToolJSON.encode(value) }
    var promptRepresentation: Prompt { Prompt(json) }
}
actor ToolAccessLedger {
    private var tools: Set<ToolKind> = []
    private var failed = false
    func record(_ kind: ToolKind) { tools.insert(kind) }
    func markFailed() { failed = true }
    func result() -> (Set<ToolKind>, Bool) { (tools, failed) }
}
struct GetCurrentGlucoseTool: Tool {
    let name = "getCurrentGlucose"
    let description = "Read structured CGM status, measurement, direction, source time and age. Stale values are historical, not current."
    let snapshot: AssistantSnapshot
    let ledger: ToolAccessLedger
    func call(arguments: SnapshotArguments) async throws -> StructuredToolOutput<CurrentGlucoseResult> {
        do { let output = try StructuredToolOutput(snapshot.rechecked(at: Date()).currentGlucose); await ledger.record(.glucose); return output }
        catch { await ledger.markFailed(); throw AssistantFailure.toolFailure }
    }
}
struct GetForecastTool: Tool {
    let name = "getForecast"
    let description = "Read available experimental 30/60 minute forecasts, validation uncertainty, source/generation times, model/schema versions and missingness. Never infer a missing risk score."
    let snapshot: AssistantSnapshot
    let ledger: ToolAccessLedger
    func call(arguments: SnapshotArguments) async throws -> StructuredToolOutput<ForecastToolResult> {
        do { let output = try StructuredToolOutput(snapshot.rechecked(at: Date()).forecastResult); await ledger.record(.forecast); return output }
        catch { await ledger.markFailed(); throw AssistantFailure.toolFailure }
    }
}
struct GetRecentInsulinTool: Tool {
    let name = "getRecentInsulin"
    let description = "Read latest recorded bolus, active visible temp basal, age, freshness and coverage. IOB is unavailable; do not calculate it or suggest a dose."
    let snapshot: AssistantSnapshot
    let ledger: ToolAccessLedger
    func call(arguments: SnapshotArguments) async throws -> StructuredToolOutput<RecentInsulinResult> {
        do { let output = try StructuredToolOutput(snapshot.rechecked(at: Date()).recentInsulin); await ledger.record(.insulin); return output }
        catch { await ledger.markFailed(); throw AssistantFailure.toolFailure }
    }
}
struct GetCurrentContextTool: Tool {
    let name = "getCurrentContext"
    let description = "Read available steps, heart rate, workout/sleep, place/event categories and minutes to the next event. No GPS coordinates, titles, notes or attendees."
    let snapshot: AssistantSnapshot
    let ledger: ToolAccessLedger
    func call(arguments: SnapshotArguments) async throws -> StructuredToolOutput<CurrentContextResult> {
        do { let output = try StructuredToolOutput(snapshot.rechecked(at: Date()).currentContext); await ledger.record(.context); return output }
        catch { await ledger.markFailed(); throw AssistantFailure.toolFailure }
    }
}

@MainActor final class AssistantService: AssistantModelProvider {
    private var warmSession: LanguageModelSession?
    var runtimeVersion: String {
        // Apple does not expose a stable weight version through this iOS 26 API.
        "SystemLanguageModel.default; weights version not exposed; " + ProcessInfo.processInfo.operatingSystemVersionString
    }
    func availability(language: ReplyLanguage) -> ModelAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return SystemLanguageModel.default.supportsLocale(Locale(identifier: language.localeIdentifier)) ? .available : .unsupportedLanguage
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return .intelligenceDisabled
            case .deviceNotEligible: return .unsupportedDevice
            case .modelNotReady: return .modelNotReady
            @unknown default: return .unknown
            }
        }
    }
    var availability: String {
        switch availability(language: .english) {
        case .available: "Apple on-device conversation ready"
        case .intelligenceDisabled: "Enable Apple Intelligence in iPhone Settings."
        case .unsupportedDevice: "This device does not support the on-device model."
        case .modelNotReady: "Apple's model is still preparing or downloading."
        case .unsupportedLanguage: "The selected language is not supported by this model."
        case .unknown: "The on-device model is unavailable; local replies still work."
        }
    }
    func prewarm() {
        guard availability(language: .english) == .available else { return }
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: JoeInstructions.combined)
        session.prewarm(); warmSession = session
    }
    func releasePrewarm() { warmSession = nil }
    func respond(to request: AssistantModelRequest) async throws -> ModelReply {
        let ledger = ToolAccessLedger()
        var tools: [any Tool] = []
        if request.allowedTools.contains(.glucose) { tools.append(GetCurrentGlucoseTool(snapshot: request.snapshot, ledger: ledger)) }
        if request.allowedTools.contains(.forecast) { tools.append(GetForecastTool(snapshot: request.snapshot, ledger: ledger)) }
        if request.allowedTools.contains(.insulin) { tools.append(GetRecentInsulinTool(snapshot: request.snapshot, ledger: ledger)) }
        if request.allowedTools.contains(.context) { tools.append(GetCurrentContextTool(snapshot: request.snapshot, ledger: ledger)) }
        // A short fresh session uses static instructions only. Current facts exist exclusively in tools.
        let session = LanguageModelSession(model: SystemLanguageModel.default, tools: tools, instructions: JoeInstructions.combined)
        do {
            let response = try await session.respond(to: ConversationMemory.prompt(question: request.question,
                history: request.history, decision: request.decision), options: GenerationOptions(temperature: 0.3, maximumResponseTokens: 220))
            let (used, failed) = await ledger.result()
            if failed { throw AssistantFailure.toolFailure }
            return ModelReply(text: response.content.trimmingCharacters(in: .whitespacesAndNewlines), usedTools: used)
        } catch let failure as AssistantFailure { throw failure }
        catch is CancellationError { throw AssistantFailure.cancelled }
        catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: throw AssistantFailure.contextSizeExceeded
            case .unsupportedLanguageOrLocale: throw AssistantFailure.unsupportedLanguage
            case .assetsUnavailable: throw AssistantFailure.assetsUnavailable
            case .guardrailViolation: throw AssistantFailure.guardrailViolation
            case .refusal: throw AssistantFailure.refusal
            default: throw AssistantFailure.generationError
            }
        } catch {
            let (_, toolFailed) = await ledger.result()
            if toolFailed { throw AssistantFailure.toolFailure }
            if #available(iOS 27.0, *), let modelError = error as? LanguageModelError {
                switch modelError {
                case .contextSizeExceeded: throw AssistantFailure.contextSizeExceeded
                case .unsupportedLanguageOrLocale: throw AssistantFailure.unsupportedLanguage
                case .guardrailViolation: throw AssistantFailure.guardrailViolation
                default: throw AssistantFailure.generationError
                }
            }
            throw AssistantFailure.generationError
        }
    }
}
