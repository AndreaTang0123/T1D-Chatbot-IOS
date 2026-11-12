import Foundation

/// This gate may replace a reply for freshness/safety, but never reinterprets its original fact numbers.
public struct ReplyFreshnessReview: Sendable {
    public let decision: SafetyDecision
    public let requiredResponse: String?
    public let reasons: [String]
    public static func evaluate(question: String, facts: AssistantSnapshot, at time: Date, evidence: Set<ToolKind>) -> Self {
        let current = facts.rechecked(at: time)
        let decision = SafetyDecisionEngine(policy: current.policy).evaluate(cgm: current.currentGlucose, forecast: current.forecastResult)
        let fallback = ExplanationFallback()
        if let required = fallback.requiredResponse(decision: decision, userText: question, snapshot: current) {
            let reason = facts.calendarDay.map { $0.isValid(at: facts.now) && !$0.isValid(at: time) } == true
                ? "calendar_expired_during_generation" : "freshness_or_safety_" + decision.code
            return Self(decision: decision, requiredResponse: required, reasons: [reason])
        }
        if evidence.contains(.forecast), facts.forecastResult.available, !current.forecastResult.available {
            return Self(decision: decision, requiredResponse: fallback.generalResponse(userText: question, snapshot: current), reasons: ["forecast_expired_during_generation"])
        }
        if evidence.contains(.context), facts.calendarDay == nil, facts.currentContext.freshness == .fresh, current.currentContext.freshness != .fresh {
            return Self(decision: decision, requiredResponse: fallback.generalResponse(userText: question, snapshot: current), reasons: ["context_expired_during_generation"])
        }
        return Self(decision: decision, requiredResponse: nil, reasons: [])
    }
}
