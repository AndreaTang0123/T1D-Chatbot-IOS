import Foundation

public struct ExplanationFallback: Sendable {
    public init() {}
    public func requiredResponse(decision: SafetyDecision, userText: String, snapshot: AssistantSnapshot) -> String? {
        let intent = QuestionIntent(userText)
        if intent.dose { return dose(language: ReplyLanguage(text: userText)) }
        switch decision {
        case .noData: return generalResponse(userText: userText, snapshot: snapshot)
        case .staleData where intent.glucose || intent.forecast: return glucose(snapshot, language: ReplyLanguage(text: userText))
        case .urgentLow, .urgentHigh: return glucose(snapshot, language: ReplyLanguage(text: userText), urgent: true)
        case .forecastRisk: return prediction(snapshot, language: ReplyLanguage(text: userText))
        default: return nil
        }
    }
    public func generalResponse(userText: String, snapshot: AssistantSnapshot) -> String {
        let intent = QuestionIntent(userText); let language = ReplyLanguage(text: userText)
        if intent.dose { return dose(language: language) }
        if intent.emotional { return language == .chinese ? "\u{542c}\u{8d77}\u{6765}\u{4eca}\u{5929}\u{771f}\u{7684}\u{5f88}\u{7d2f}，\u{6211}\u{5728}\u{8fd9}\u{91cc}\u{966a}\u{4f60}。\u{4e00}\u{5929}\u{4e0d}\u{987a}\u{5229}\u{5e76}\u{4e0d}\u{80fd}\u{5b9a}\u{4e49}\u{4f60}。" : "That sounds like a lot to carry; I'm here with you. A difficult day doesn't define you." }
        if intent.sharingExperience { return language == .chinese ? "\u{6211}\u{542c}\u{5230}\u{4e86}，\u{6211}\u{5728}\u{8fd9}\u{91cc}\u{966a}\u{4f60}。" : "Got it; I'm here with you." }
        if intent.forecast { return prediction(snapshot, language: language) }
        if intent.insulin { return insulin(snapshot, language: language) }
        if intent.glucose { return glucose(snapshot, language: language) }
        if intent.context { return context(snapshot, language: language) }
        let lower = userText.lowercased()
        if lower.contains("ballet") || lower.contains("\u{821e}") {
            return language == .chinese ? "\u{8df3}\u{5b8c}\u{821e}\u{5566}，\u{6211}\u{5728}\u{542c}。" : "You finished ballet; I'm listening."
        }
        return language == .chinese ? "\u{6211}\u{5728}\u{8fd9}\u{91cc}\u{966a}\u{4f60}，\u{4e5f}\u{5728}\u{8ba4}\u{771f}\u{542c}\u{4f60}\u{8bf4}。" : "I'm here with you, and I'm listening."
    }
    private func dose(language: ReplyLanguage) -> String {
        language == .chinese ? "\u{6211}\u{4e0d}\u{80fd}\u{5efa}\u{8bae}\u{80f0}\u{5c9b}\u{7d20}\u{5242}\u{91cf}、\u{8c03}\u{6574}\u{57fa}\u{7840}\u{7387}\u{6216}\u{63a7}\u{5236}\u{6cf5}。" : "I can't recommend insulin doses, change basal rates, or control a pump."
    }
    private func number(_ value: Double) -> String { value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value) }
    private func glucose(_ snapshot: AssistantSnapshot, language: ReplyLanguage, urgent: Bool = false) -> String {
        let g = snapshot.currentGlucose
        guard let value = g.glucoseMgDl, let age = g.ageMinutes else {
            return language == .chinese ? "\u{76ee}\u{524d}\u{6ca1}\u{6709}\u{53ef}\u{7528}\u{7684}\u{8840}\u{7cd6}\u{8bfb}\u{6570}，\u{6211}\u{4e0d}\u{80fd}\u{731c}\u{6d4b}\u{5f53}\u{524d}\u{8840}\u{7cd6}。" : "There is no available glucose reading, so I can't know your current glucose."
        }
        if g.status == .stale {
            return language == .chinese ? "\u{6700}\u{8fd1}\u{4e00}\u{6b21}\u{8840}\u{7cd6}\u{8bfb}\u{6570}\u{662f}\(number(value)) mg/dL，\u{6765}\u{81ea}\(age)\u{5206}\u{949f}\u{524d}；\u{5b83}\u{5df2}\u{8fc7}\u{671f}，\u{4e0d}\u{80fd}\u{4ee3}\u{8868}\u{5f53}\u{524d}\u{8840}\u{7cd6}。" : "The last reading was \(number(value)) mg/dL, \(age) minutes ago; it is stale and does not represent current glucose."
        }
        let condition = value < snapshot.policy.lowGlucose ? (language == .chinese ? "，\u{6570}\u{503c}\u{504f}\u{4f4e}" : ", which is low") : value > snapshot.policy.highGlucose ? (language == .chinese ? "，\u{6570}\u{503c}\u{504f}\u{9ad8}" : ", which is high") : ""
        return language == .chinese ? "\u{6700}\u{8fd1}\u{6d4b}\u{91cf}\u{662f}\(number(value)) mg/dL，\u{6765}\u{81ea}\(age)\u{5206}\u{949f}\u{524d}\(urgent ? condition : "")。" : "Your latest measurement is \(number(value)) mg/dL from \(age) minutes ago\(urgent ? condition : "")."
    }
    private func prediction(_ snapshot: AssistantSnapshot, language: ReplyLanguage) -> String {
        let f = snapshot.forecastResult
        guard f.available, let p30 = f.predicted30m, let p60 = f.predicted60m, let u30 = f.uncertainty30m, let u60 = f.uncertainty60m else {
            return language == .chinese ? "\u{5f53}\u{524d}\u{6ca1}\u{6709}\u{53ef}\u{7528}\u{7684}\u{9884}\u{6d4b}，\u{6211}\u{4e0d}\u{4f1a}\u{81ea}\u{884c}\u{4f30}\u{7b97}\u{672a}\u{6765}\u{8840}\u{7cd6}。" : "No forecast is available; I won't estimate future glucose myself."
        }
        return language == .chinese ? "\u{4ee5}\u{8840}\u{7cd6}\u{6d4b}\u{91cf}\u{65f6}\u{95f4}\u{4e3a}\u{8d77}\u{70b9}，\u{5b9e}\u{9a8c}\u{6027}\u{9884}\u{6d4b}\u{4e3a}30\u{5206}\u{949f}\u{540e}\(number(p30))、60\u{5206}\u{949f}\u{540e}\(number(p60)) mg/dL。\u{9a8c}\u{8bc1}\u{96c6}\u{8bef}\u{5dee}P90\u{5206}\u{522b}\u{4e3a}\(number(u30))\u{548c}\(number(u60)) mg/dL，\u{4e0d}\u{662f}\u{4fdd}\u{8bc1}\u{8303}\u{56f4}。" : "Relative to the CGM timestamp, experimental predictions are \(number(p30)) mg/dL at 30 minutes and \(number(p60)) mg/dL at 60 minutes. Validation error P90 is \(number(u30)) and \(number(u60)) mg/dL respectively, not guaranteed bounds."
    }
    private func insulin(_ snapshot: AssistantSnapshot, language: ReplyLanguage) -> String {
        let i = snapshot.recentInsulin
        guard let units = i.latestBolusUnits, let age = i.dataAgeMinutes else {
            return language == .chinese ? "\u{53ef}\u{89c1}\u{8bb0}\u{5f55}\u{91cc}\u{6ca1}\u{6709}\u{6700}\u{8fd1}\u{7684}bolus，\u{8fd9}\u{4e0d}\u{4ee3}\u{8868}\u{6ca1}\u{6709}\u{8f93}\u{6ce8}\u{80f0}\u{5c9b}\u{7d20}。" : "No recent bolus is visible in the records; this does not mean no insulin was delivered."
        }
        let qualifier = i.status == .stale ? (language == .chinese ? "\u{8fc7}\u{671f}\u{7684}\u{5386}\u{53f2}\u{8bb0}\u{5f55}" : "stale historical record") : (language == .chinese ? "\u{53ef}\u{89c1}\u{8bb0}\u{5f55}" : "visible record")
        return language == .chinese ? "\(qualifier)\u{4e2d}，\u{6700}\u{8fd1}bolus\u{4e3a}\(number(units)) U，\u{6765}\u{81ea}\(age)\u{5206}\u{949f}\u{524d}；IOB\u{4e0d}\u{53ef}\u{7528}。" : "In the \(qualifier), the latest bolus was \(number(units)) U, \(age) minutes ago; IOB is unavailable."
    }
    private func context(_ snapshot: AssistantSnapshot, language: ReplyLanguage) -> String {
        let c = snapshot.currentContext
        guard c.freshness == .fresh else { return language == .chinese ? "\u{76ee}\u{524d}\u{6ca1}\u{6709}\u{8fd1}\u{671f}\u{53ef}\u{7528}\u{7684}\u{751f}\u{6d3b}\u{6570}\u{636e}，\u{6211}\u{4e0d}\u{4f1a}\u{731c}\u{6d4b}。" : "No recent lifestyle data is available; I won't guess." }
        var parts: [String] = []
        if let steps = c.stepsLast30m { parts.append(language == .chinese ? "\u{8fd1}30\u{5206}\u{949f}\u{6b65}\u{6570}\u{4e3a}\(number(steps))" : "steps in the last 30 minutes: \(number(steps))") }
        if let sleep = c.sleepHoursLastNight { parts.append(language == .chinese ? "\u{6700}\u{8fd1}\u{7761}\u{7720}\u{4e3a}\(number(sleep))\u{5c0f}\u{65f6}" : "latest sleep: \(number(sleep)) hours") }
        if let category = c.currentEventCategory { parts.append(language == .chinese ? "\u{5f53}\u{524d}\u{65e5}\u{7a0b}\u{7c7b}\u{522b}\u{4e3a}\(category)" : "current event category: \(category)") }
        if let next = c.minutesUntilNextEvent { parts.append(language == .chinese ? "\u{4e0b}\u{9879}\u{65e5}\u{7a0b}\u{8fd8}\u{6709}\(next)\u{5206}\u{949f}" : "next event in \(next) minutes") }
        guard !parts.isEmpty else { return language == .chinese ? "\u{5f53}\u{524d}\u{751f}\u{6d3b}\u{6570}\u{636e}\u{4e0d}\u{5b8c}\u{6574}，\u{6211}\u{4e0d}\u{4f1a}\u{731c}\u{6d4b}\u{7f3a}\u{5931}\u{5185}\u{5bb9}。" : "Current lifestyle data is incomplete; I won't guess missing details." }
        return parts.prefix(3).joined(separator: language == .chinese ? "；" : "; ") + (language == .chinese ? "；\u{8fd9}\u{4e9b}\u{5173}\u{8054}\u{4e0d}\u{8bf4}\u{660e}\u{56e0}\u{679c}。" : "; these associations do not establish causation.")
    }
}
