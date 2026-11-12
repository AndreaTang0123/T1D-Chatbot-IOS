import Foundation

public struct SafetyPolicy: Codable, Sendable, Equatable {
    public static let version = "joe.safety-policy.v1"
    public var lowGlucose: Double = 70
    public var highGlucose: Double = 250
    public var cgmStaleSeconds: TimeInterval = 900
    public var pumpStaleSeconds: TimeInterval = 6 * 3600
    public var contextStaleSeconds: TimeInterval = 900
    // Disabled until a calibrated model supplies a risk score and an explicit threshold is configured.
    public var hypoRiskThreshold: Double? = nil
    public init(cgmStaleSeconds: TimeInterval = 900, hypoRiskThreshold: Double? = nil) {
        self.cgmStaleSeconds = min(1800, max(300, cgmStaleSeconds)); self.hypoRiskThreshold = hypoRiskThreshold
    }
}
public enum DataStatus: String, Codable, Sendable { case fresh, stale, unavailable }
public enum SafetyDecision: Codable, Equatable, Sendable {
    case noData
    case staleData(ageMinutes: Int)
    case urgentLow(glucose: Double)
    case urgentHigh(glucose: Double)
    case forecastRisk
    case normal
    public var code: String {
        switch self {
        case .noData: "noData"
        case .staleData: "staleData"
        case .urgentLow: "urgentLow"
        case .urgentHigh: "urgentHigh"
        case .forecastRisk: "forecastRisk"
        case .normal: "normal"
        }
    }
}
public struct SafetyDecisionEngine: Sendable {
    public let policy: SafetyPolicy
    public init(policy: SafetyPolicy = SafetyPolicy()) { self.policy = policy }
    public func evaluate(cgm: CurrentGlucoseResult, forecast: ForecastToolResult) -> SafetyDecision {
        guard let glucose = cgm.glucoseMgDl, glucose.isFinite, (40...400).contains(glucose), cgm.status != .unavailable else { return .noData }
        if cgm.status == .stale { return .staleData(ageMinutes: cgm.ageMinutes ?? 0) }
        if glucose < policy.lowGlucose { return .urgentLow(glucose: glucose) }
        if glucose > policy.highGlucose { return .urgentHigh(glucose: glucose) }
        if forecast.available, let risk = forecast.hypoRisk60m, risk.isFinite, (0...1).contains(risk),
           let threshold = policy.hypoRiskThreshold, threshold > 0, threshold <= 1, risk >= threshold { return .forecastRisk }
        return .normal
    }
}
public enum ToolKind: String, Codable, Sendable, CaseIterable, Hashable { case glucose, forecast, insulin, context, history }
public enum ReplyLanguage: String, Codable, Sendable {
    case english, chinese
    public init(text: String) {
        self = text.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) } ? .chinese : .english
    }
    public var localeIdentifier: String { self == .chinese ? "zh-CN" : "en-US" }
}
public struct QuestionIntent: Sendable {
    public let calendar: Bool
    public let history: Bool
    public let glucose: Bool
    public let forecast: Bool
    public let insulin: Bool
    public let context: Bool
    public let dose: Bool
    public let emotional: Bool
    public let sharingExperience: Bool
    public init(_ text: String) {
        let s = text.lowercased()
        func has(_ words: [String]) -> Bool { words.contains(where: s.contains) }
        calendar = has(["calendar", "schedule", "appointment", "meeting", "next event", "today's events", "日历", "日程", "安排"])
        history = has(["history", "historical", "past week", "last week", "last 7", "last 14", "last 30", "two weeks", "recent glucose", "血糖表现", "历史血糖", "最近一周", "最近两周", "近两周", "过去一周", "近一个月", "最近血糖", "血糖总结"]) || (has(["glucose", "blood sugar", "cgm", "血糖"]) && has(["recent", "lately", "week", "month", "最近", "近期", "过去", "近7天", "近14天", "近30天"]))
        glucose = has(["glucose", "blood sugar", "cgm", "\u{8840}\u{7cd6}", "\u{4f4e}\u{8840}", "\u{9ad8}\u{8840}"])
        forecast = has(["forecast", "predict", "future trend", "\u{9884}\u{6d4b}", "\u{672a}\u{6765}", "\u{4e00}\u{5c0f}\u{65f6}\u{540e}\u{8840}\u{7cd6}"])
        insulin = has(["insulin", "bolus", "basal", "meal", "after eating", "\u{80f0}\u{5c9b}\u{7d20}", "\u{9910}\u{540e}", "\u{996d}\u{540e}", "\u{78b3}\u{6c34}"])
        context = calendar || has(["location", "schedule", "appointment", "meeting", "where i am", "my plans", "位置", "定位", "日程", "安排", "context", "lifestyle", "steps", "heart rate", "sleep", "workout", "exercise", "calendar", "class", "ballet", "where am i", "\u{6b65}\u{6570}", "\u{5fc3}\u{7387}", "\u{7761}\u{7720}", "\u{8fd0}\u{52a8}", "\u{8df3}\u{821e}", "\u{65e5}\u{5386}", "\u{4e0a}\u{8bfe}", "\u{5728}\u{54ea}"])
        dose = has(["how much insulin", "what dose", "dose should", "dosage", "increase insulin", "decrease insulin", "adjust pump", "change basal", "set my pump", "\u{6253}\u{591a}\u{5c11}", "\u{591a}\u{5c11}\u{5355}\u{4f4d}", "\u{5242}\u{91cf}", "\u{8c03}\u{6cf5}", "\u{8c03}\u{6574}\u{57fa}\u{7840}\u{7387}", "\u{52a0}\u{80f0}\u{5c9b}\u{7d20}"]) ||
            s.range(of: "\\b(should i (take|inject|bolus|change|increase|decrease|adjust|set)|do i need (a |an )?(bolus|insulin)|what should i (inject|bolus))\\b", options: .regularExpression) != nil
        emotional = has(["tired", "exhausted", "stress", "upset", "messed up", "burnout", "disappoint", "\u{7d2f}", "\u{96be}\u{8fc7}", "\u{538b}\u{529b}", "\u{63a7}\u{5236}\u{5f97}\u{5f88}\u{5dee}", "\u{5931}\u{8d25}"])
        let asksQuestion = has(["where", "want to know", "can you", "在哪", "哪里", "什么", "有没有", "能否", "可以查看", "可以访问", "?", "？", "what", "why", "how", "show", "tell", "explain", "check", "\u{591a}\u{5c11}", "\u{4e3a}\u{4ec0}\u{4e48}", "\u{770b}\u{770b}", "\u{663e}\u{793a}", "\u{89e3}\u{91ca}", "\u{67e5}\u{4e00}\u{4e0b}"])
        sharingExperience = (context || insulin) && !glucose && !forecast && !asksQuestion &&
            (s.hasPrefix("i ") || s.hasPrefix("i'm ") || s.hasPrefix("\u{6211}"))

    }
    public var asksForData: Bool { !sharingExperience && (glucose || forecast || insulin || context) }
    public var tools: Set<ToolKind> {
        if history && !dose && !forecast && !insulin { return [.history] }
        if sharingExperience { return [] }
        var result: Set<ToolKind> = []
        if glucose { result.insert(.glucose) }
        if forecast { result.formUnion([.glucose, .forecast]) }
        if insulin { result.formUnion([.glucose, .forecast, .insulin]) }
        if context { result.insert(.context) }
        return result
    }
}
