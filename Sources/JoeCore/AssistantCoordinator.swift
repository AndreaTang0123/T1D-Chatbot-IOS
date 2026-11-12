import Foundation

public enum ModelAvailability: String, Codable, Sendable {
    case available, modelMissing, intelligenceDisabled, unsupportedDevice, modelNotReady, unsupportedLanguage, unknown
}
public enum AssistantFailure: String, Error, Codable, Sendable {
    case generationError, contextSizeExceeded, unsupportedLanguage, toolFailure, refusal, guardrailViolation, assetsUnavailable, cancelled
}
public struct AssistantModelRequest: Sendable {
    public let question: String
    public let history: [JoeChatTurn]
    public let snapshot: AssistantSnapshot
    public let decision: SafetyDecision
    public let allowedTools: Set<ToolKind>
    public init(question: String, history: [JoeChatTurn], snapshot: AssistantSnapshot, decision: SafetyDecision, allowedTools: Set<ToolKind>) {
        self.question = question; self.history = history; self.snapshot = snapshot; self.decision = decision; self.allowedTools = allowedTools
    }
}
public struct ModelReply: Sendable {
    public let text: String
    public let usedTools: Set<ToolKind>
    public init(text: String, usedTools: Set<ToolKind>) { self.text = text; self.usedTools = usedTools }
}
@MainActor public protocol AssistantModelProvider: AnyObject {
    var runtimeVersion: String { get }
    func availability(language: ReplyLanguage) -> ModelAvailability
    func respond(to request: AssistantModelRequest) async throws -> ModelReply
    func prewarm()
}
public struct AssistantTurnRecord: Codable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let question: String
    public let response: String
    public let decision: SafetyDecision
    public let availability: ModelAvailability
    public let mode: String
    public let failure: AssistantFailure?
    public let validationReasons: [String]
    public let allowedTools: [ToolKind]
    public let usedTools: [ToolKind]
    public let prompts: PromptVersions
    public let safetyPolicyVersion: String
    public let safetyPolicy: SafetyPolicy
    public let validatorVersion: String
    public let foundationModelVersion: String
    public let sourceCGMTimestamp: Date?
    public let forecastModelVersion: String?
    public let latencyMilliseconds: Double
    public let regressionCaseID: String?
}
public extension AssistantTurnRecord {
    var fallbackDetails: [String] {
        let labels = [
            "calendar_range_omitted": "The model omitted or changed the selected date range or timezone.",
            "calendar_date_omitted": "The model omitted one or more event dates.",
            "calendar_time_omitted": "The model omitted an event time or all-day label.",
            "calendar_event_omitted": "The model omitted or renamed an event title.",
            "calendar_event_date_time_mismatch": "An event was not listed with its matching date and times on the same line.",
            "calendar_range_mismatch": "The model described the week as today.",
            "unsupported_calendar_number": "The model included a number not supported by the calendar result.",
            "calendar_promise_only": "The model promised to check instead of listing results.",
            "calendar_unavailable": "The calendar result is unavailable or expired.",
            "language_mismatch": "The response language did not match your question.",
            "format_mismatch": "The response used unsupported formatting.",
            "unverified_access_claim": "The model made an unverified permission claim."
        ]
        return validationReasons.map { labels[$0] ?? "Response check: " + $0.replacingOccurrences(of: "_", with: " ") }
    }
}
@MainActor public final class AssistantCoordinator {
    public let provider: any AssistantModelProvider
    public let fallback = ExplanationFallback()
    public let validator = ResponseValidator()
    public init(provider: any AssistantModelProvider) { self.provider = provider }
    public func answer(_ question: String, snapshot: AssistantSnapshot, history: [JoeChatTurn], regressionCaseID: String? = nil) async -> AssistantTurnRecord {
        let start = ContinuousClock.now
        var decision = SafetyDecisionEngine(policy: snapshot.policy).evaluate(cgm: snapshot.currentGlucose, forecast: snapshot.forecastResult)
        let intent = QuestionIntent(question)
        let allowed = intent.tools
        let availability = provider.availability(language: ReplyLanguage(text: question))
        var failure: AssistantFailure?; var reasons: [String] = []; var used: Set<ToolKind> = []
        var mode = "Swift deterministic fallback"
        let result: String
        if let required = fallback.requiredResponse(decision: decision, userText: question, snapshot: snapshot) {
            result = required; mode = "Swift safety · " + decision.code
        } else if availability != .available {
            result = fallback.generalResponse(userText: question, snapshot: snapshot); mode = "Local fallback · " + availability.rawValue
        } else {
            do {
                let generated = try await provider.respond(to: AssistantModelRequest(question: question, history: history,
                    snapshot: snapshot, decision: decision, allowedTools: allowed))
                used = generated.usedTools
                let elapsed = start.duration(to: .now).components
                let finalSnapshot = snapshot.rechecked(at: snapshot.now.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds)/1e18))
                decision = SafetyDecisionEngine(policy: finalSnapshot.policy).evaluate(cgm: finalSnapshot.currentGlucose, forecast: finalSnapshot.forecastResult)
                let validation = validator.validate(generated.text, userText: question, decision: decision, snapshot: finalSnapshot, evidence: used.intersection(allowed))
                reasons = validation.reasons
                if !used.isSubset(of: allowed) { reasons.append("unexpected_tool") }
                if let expired = fallback.requiredResponse(decision: decision, userText: question, snapshot: finalSnapshot) {
                    result = expired; mode = "Swift safety · " + decision.code
                } else if reasons.isEmpty { result = generated.text; mode = "Gemma 4 E2B · Validated" }
                else { result = fallback.generalResponse(userText: question, snapshot: finalSnapshot); mode = "Local fallback · Response rejected" }
            } catch {
                failure = error as? AssistantFailure ?? .generationError
                result = fallback.generalResponse(userText: question, snapshot: snapshot); mode = "Local fallback · " + (failure?.rawValue ?? "generationError")
            }
        }
        let duration = start.duration(to: .now).components
        return AssistantTurnRecord(id: UUID(), timestamp: snapshot.now, question: question, response: result, decision: decision,
            availability: availability, mode: mode, failure: failure, validationReasons: reasons,
            allowedTools: allowed.sorted { $0.rawValue < $1.rawValue }, usedTools: used.sorted { $0.rawValue < $1.rawValue },
            prompts: JoeInstructions.versions, safetyPolicyVersion: SafetyPolicy.version, safetyPolicy: snapshot.policy,
            validatorVersion: ResponseValidator.version, foundationModelVersion: provider.runtimeVersion,
            sourceCGMTimestamp: snapshot.currentGlucose.sourceTimestamp, forecastModelVersion: snapshot.forecastResult.modelVersion,
            latencyMilliseconds: Double(duration.seconds)*1000 + Double(duration.attoseconds)/1e15, regressionCaseID: regressionCaseID)
    }
}
