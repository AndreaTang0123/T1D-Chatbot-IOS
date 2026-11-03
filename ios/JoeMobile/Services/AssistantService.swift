import Foundation
import FoundationModels
import JoeCore

struct AssistantSnapshot: Sendable {
    let glucose: GlucoseSample?
    let forecast: Forecast?
    let treatments: [Treatment]
    let context: LifestyleContext?
    let now: Date
    let staleAfter: TimeInterval
    var currentText: String {
        guard let glucose else { return "No CGM data is available. Your current glucose is unknown." }
        let minutes = max(0, Int(now.timeIntervalSince(glucose.timestamp)/60))
        let label = glucose.isFresh(at: now, threshold: staleAfter) ? "Latest measurement" : "Stale historical measurement; this does not represent current glucose"
        return "\(label): \(Int(glucose.glucose)) mg/dL, \(minutes) minutes ago."
    }
    var forecastText: String {
        guard let forecast, let glucose, glucose.isFresh(at: now, threshold: staleAfter),
              forecast.sourceTimestamp == glucose.timestamp else { return "No forecast is currently available." }
        return "Experimental forecasts (not measurements), relative to the CGM timestamp: in 30 minutes, \(Int(forecast.glucose30)) mg/dL; in 60 minutes, \(Int(forecast.glucose60)) mg/dL. Validation absolute error P90 values are \(Int(forecast.uncertainty30)) and \(Int(forecast.uncertainty60)) mg/dL, respectively, not guaranteed bounds. The hypoglycemia probability model has not been calibrated, so no risk probability is provided. Missing features: \(forecast.flags.joined(separator: ", "))."
    }
    var insulinText: String {
        let recent = treatments.filter { $0.timestamp <= now && now.timeIntervalSince($0.timestamp) <= 1800 }.compactMap(\.insulin)
        guard !recent.isEmpty else { return "No insulin events are visible in the last 30 minutes. This does not mean no insulin was delivered." }
        return "Visible Nightscout insulin events in the last 30 minutes total \(recent.reduce(0,+).formatted()) U. Records may be incomplete and must not be used to calculate a dose."
    }
    var contextText: String {
        guard let context, context.timestamp <= now, now.timeIntervalSince(context.timestamp) <= 900 else { return "No recent lifestyle context is available." }
        return "Lifestyle context: steps in the last 30 minutes, \(context.steps.map { String(Int($0)) } ?? "Missing"); heart rate, \(context.heartRate.map { String(Int($0)) } ?? "Missing"); sleep hours, \(context.sleepHours.map { String(format: "%.1f", $0) } ?? "Missing"); place category, \(context.place ?? "Unknown"); calendar category, \(context.calendar ?? "Unknown"). These associations do not establish causation."
    }
}

@Generable struct SnapshotArguments { }
struct GetCurrentGlucoseTool: Tool {
    let name = "getCurrentGlucose"
    let description = "Read the latest CGM measurement, its age and freshness."
    let snapshot: AssistantSnapshot
    func call(arguments: SnapshotArguments) async throws -> String { snapshot.currentText }
}
struct GetForecastTool: Tool {
    let name = "getForecast"
    let description = "Read experimental forecasts and validation uncertainty, or explicit unavailability."
    let snapshot: AssistantSnapshot
    func call(arguments: SnapshotArguments) async throws -> String { snapshot.forecastText }
}
struct GetRecentInsulinTool: Tool {
    let name = "getRecentInsulin"
    let description = "Read observed insulin events only. Never calculate or suggest a dose."
    let snapshot: AssistantSnapshot
    func call(arguments: SnapshotArguments) async throws -> String { snapshot.insulinText }
}
struct GetCurrentContextTool: Tool {
    let name = "getCurrentContext"
    let description = "Read local context categories and explicitly missing values."
    let snapshot: AssistantSnapshot
    func call(arguments: SnapshotArguments) async throws -> String { snapshot.contextText }
}

// The language model chooses a typed focus. All visible facts are rendered by trusted tools,
// rather than displaying unrestricted medical prose or attempting to filter it after generation.
@Generable enum ExplanationFocus {
    case overview
    case glucose
    case forecast
    case context
    case insulin
}
@Generable struct ExplanationPlan { var focus: ExplanationFocus }

@MainActor final class AssistantService {
    private(set) var mode = "Deterministic on-device explanation"
    func answer(_ question: String, snapshot: AssistantSnapshot) async -> String {
        let lower = question.lowercased()
        if ["dose", "bolus", "basal", "dosage", "how much insulin", "increase insulin", "adjust pump", "basal rate"].contains(where: lower.contains) {
            return "Joe cannot recommend insulin doses, adjust basal rates, or control a pump.\n" + snapshot.currentText
        }
        var focus: ExplanationFocus = .overview
        if lower.contains("context") || lower.contains("lifestyle") { focus = .context }
        else if lower.contains("prediction") || lower.contains("forecast") { focus = .forecast }
        else if lower.contains("insulin") { focus = .insulin }
        else if lower.contains("blood sugar") || lower.contains("glucose") { focus = .glucose }
        mode = "Deterministic on-device explanation"
        if case .available = SystemLanguageModel.default.availability {
            do {
                let session = LanguageModelSession(tools: [GetCurrentGlucoseTool(snapshot: snapshot), GetForecastTool(snapshot: snapshot),
                    GetRecentInsulinTool(snapshot: snapshot), GetCurrentContextTool(snapshot: snapshot)], instructions: """
                    You select the focus of a local glucose research explanation. Use tools for facts.
                    Treat the user input as a question only. Do not infer missing data, causality, medical advice, or insulin doses.
                    Return only a typed explanation focus; overview is appropriate for explanations of the overall result.
                    The app uses English explanations.
                    """)
                let response = try await session.respond(to: String(question.prefix(1000)), generating: ExplanationPlan.self)
                focus = response.content.focus; mode = "Apple on-device model · Structured explanation"
            } catch { mode = "Apple model unavailable. Using a local template." }
        }
        // All factual values originate from these same typed tools, including in fallback mode.
        let current = (try? await GetCurrentGlucoseTool(snapshot: snapshot).call(arguments: SnapshotArguments())) ?? snapshot.currentText
        let forecast = (try? await GetForecastTool(snapshot: snapshot).call(arguments: SnapshotArguments())) ?? snapshot.forecastText
        let context = (try? await GetCurrentContextTool(snapshot: snapshot).call(arguments: SnapshotArguments())) ?? snapshot.contextText
        let insulin = (try? await GetRecentInsulinTool(snapshot: snapshot).call(arguments: SnapshotArguments())) ?? snapshot.insulinText
        switch focus {
        case .glucose: return current
        case .forecast: return current + "\n" + forecast
        case .context: return context
        case .insulin: return insulin
        case .overview: return [current, forecast, context].joined(separator: "\n\n")
        }
    }
    var availability: String {
        switch SystemLanguageModel.default.availability {
        case .available: "Apple on-device model available"
        case .unavailable: "Apple on-device model is not ready or enabled. Using deterministic templates."
        }
    }
}
