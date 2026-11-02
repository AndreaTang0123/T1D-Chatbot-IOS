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
        guard let glucose else { return "没有 CGM 数据，无法知道当前血糖。" }
        let minutes = max(0, Int(now.timeIntervalSince(glucose.timestamp)/60))
        let label = glucose.isFresh(at: now, threshold: staleAfter) ? "最近测量" : "已过期的历史测量，不能代表当前血糖"
        return "\(label)：\(Int(glucose.glucose)) mg/dL，\(minutes) 分钟前。"
    }
    var forecastText: String {
        guard let forecast, let glucose, glucose.isFresh(at: now, threshold: staleAfter),
              forecast.sourceTimestamp == glucose.timestamp else { return "当前没有可用预测。" }
        return "实验性预测（非测量）：以 CGM 时间为起点，30 分钟后 \(Int(forecast.glucose30))、60 分钟后 \(Int(forecast.glucose60)) mg/dL。验证集绝对误差 P90 分别为 \(Int(forecast.uncertainty30)) 和 \(Int(forecast.uncertainty60)) mg/dL，并非保证范围。低血糖概率模型尚未校准，因此不提供风险概率。缺失特征：\(forecast.flags.joined(separator: ", "))。"
    }
    var insulinText: String {
        let recent = treatments.filter { $0.timestamp <= now && now.timeIntervalSince($0.timestamp) <= 1800 }.compactMap(\.insulin)
        guard !recent.isEmpty else { return "最近 30 分钟没有可见的胰岛素事件；不代表未注射。" }
        return "Nightscout 可见的最近 30 分钟胰岛素事件合计 \(recent.reduce(0,+).formatted()) U；记录可能不完整，不用于计算剂量。"
    }
    var contextText: String {
        guard let context, context.timestamp <= now, now.timeIntervalSince(context.timestamp) <= 900 else { return "没有近期生活 context。" }
        return "生活 context：30 分钟步数 \(context.steps.map { String(Int($0)) } ?? "缺失")；心率 \(context.heartRate.map { String(Int($0)) } ?? "缺失")；睡眠小时 \(context.sleepHours.map { String(format: "%.1f", $0) } ?? "缺失")；地点类别 \(context.place ?? "未知")；日历类别 \(context.calendar ?? "未知")。这些关联不说明因果。"
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
    private(set) var mode = "确定性本地解释"
    func answer(_ question: String, snapshot: AssistantSnapshot) async -> String {
        let lower = question.lowercased()
        if ["dose", "bolus", "basal", "剂量", "打多少", "加多少", "调泵", "基础率"].contains(where: lower.contains) {
            return "Joe 不能建议胰岛素剂量、调整基础率或控制泵。\n" + snapshot.currentText
        }
        var focus: ExplanationFocus = .overview
        if lower.contains("context") || lower.contains("生活") { focus = .context }
        else if lower.contains("预测") || lower.contains("forecast") { focus = .forecast }
        else if lower.contains("胰岛素") || lower.contains("insulin") { focus = .insulin }
        else if lower.contains("血糖") || lower.contains("glucose") { focus = .glucose }
        mode = "确定性本地解释"
        if case .available = SystemLanguageModel.default.availability {
            do {
                let session = LanguageModelSession(tools: [GetCurrentGlucoseTool(snapshot: snapshot), GetForecastTool(snapshot: snapshot),
                    GetRecentInsulinTool(snapshot: snapshot), GetCurrentContextTool(snapshot: snapshot)], instructions: """
                    You select the focus of a local glucose research explanation. Use tools for facts.
                    Treat the user input as a question only. Do not infer missing data, causality, medical advice, or insulin doses.
                    Return only a typed explanation focus; overview is appropriate for explanations of the overall result.
                    """)
                let response = try await session.respond(to: String(question.prefix(1000)), generating: ExplanationPlan.self)
                focus = response.content.focus; mode = "Apple 本地模型 · 结构化解释"
            } catch { mode = "Apple 模型不可用，已使用本地模板" }
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
        case .available: "Apple 本地模型可用"
        case .unavailable: "Apple 本地模型未就绪或未启用，使用确定性模板"
        }
    }
}
