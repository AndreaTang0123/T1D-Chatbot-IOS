import Foundation

public struct ExplanationFallback: Sendable {
    public init() {}
    public func requiredResponse(decision: SafetyDecision, userText: String, snapshot: AssistantSnapshot) -> String? {
        let intent = QuestionIntent(userText)
        if intent.dose { return dose(language: ReplyLanguage(text: userText)) }
        if intent.calendar && !intent.sharingExperience && !intent.glucose && !intent.forecast && !intent.insulin {
            guard let day = snapshot.calendarDay else { return generalResponse(userText: userText, snapshot: snapshot) }
            // A successful day query is independent of CGM availability. Missing/error states use exact app text.
            if day.status != .available || day.events.isEmpty || !day.isValid(at: snapshot.now) {
                return day.response(language: ReplyLanguage(text: userText), at: snapshot.now)
            }
            return nil
        }
        if intent.tools == [.history] { return snapshot.glucoseHistory == nil ? generalResponse(userText: userText, snapshot: snapshot) : nil }
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
        if intent.calendar && !intent.sharingExperience && !intent.glucose && !intent.forecast && !intent.insulin {
            return snapshot.calendarDay?.response(language: language, at: snapshot.now)
                ?? (language == .chinese ? "尚未读取所需范围的日历，请重试。" : "The requested calendar range has not been read. Please retry.")
        }
        if intent.tools == [.history] {
            return snapshot.glucoseHistory?.description(language: language) ?? (language == .chinese ? "所选时间范围内没有可读取的历史血糖记录。请检查 Nightscout 同步或 Apple 健康的共享及读取权限；空结果不能证明没有血糖变化。" : "No glucose history is visible for the requested range. Check Nightscout sync or Apple Health sharing/read access; empty results do not establish what your glucose was.")
        }
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
        guard let value = g.glucoseMgDl, let time = g.sourceLocalTime else {
            return language == .chinese ? "没有可用血糖读数，我不会猜测。" : "No valid glucose reading is available; I won't guess."
        }
        if g.status == .stale {
            return language == .chinese ? "最近可见血糖为\(number(value)) mg/dL，测量时间为\(time)；这条读数已过期，不能代表当前血糖。" : "The latest visible glucose was \(number(value)) mg/dL at \(time); this reading is stale and does not represent current glucose."
        }
        let condition = value < snapshot.policy.lowGlucose ? (language == .chinese ? "，数值偏低" : ", which is low") : value > snapshot.policy.highGlucose ? (language == .chinese ? "，数值偏高" : ", which is high") : ""
        return language == .chinese ? "最近测量血糖为\(number(value)) mg/dL，时间为\(time)\(urgent ? condition : "")。" : "Your latest measurement was \(number(value)) mg/dL at \(time)\(urgent ? condition : "")."
    }
    private func prediction(_ snapshot: AssistantSnapshot, language: ReplyLanguage) -> String {
        let f = snapshot.forecastResult
        guard f.available, let p30 = f.predicted30m, let p60 = f.predicted60m, let u30 = f.uncertainty30m, let u60 = f.uncertainty60m else {
            return language == .chinese ? "\u{5f53}\u{524d}\u{6ca1}\u{6709}\u{53ef}\u{7528}\u{7684}\u{9884}\u{6d4b}，\u{6211}\u{4e0d}\u{4f1a}\u{81ea}\u{884c}\u{4f30}\u{7b97}\u{672a}\u{6765}\u{8840}\u{7cd6}。" : "No forecast is available; I won't estimate future glucose myself."
        }
        let first = f.prediction30mLocalTime ?? "unavailable"
        let second = f.prediction60mLocalTime ?? "unavailable"
        return language == .chinese ? "实验性预测：\(first) 为\(number(p30))、\(second) 为\(number(p60)) mg/dL；验证误差 P90 分别为\(number(u30))和\(number(u60)) mg/dL，不是保证范围。" : "Experimental predictions: \(number(p30)) mg/dL for \(first) and \(number(p60)) mg/dL for \(second). Validation error P90 is \(number(u30)) and \(number(u60)) mg/dL respectively, not guaranteed bounds."
    }
    private func insulin(_ snapshot: AssistantSnapshot, language: ReplyLanguage) -> String {
        let i = snapshot.recentInsulin
        guard let units = i.latestBolusUnits, let time = i.latestBolusLocalTime else {
            return language == .chinese ? "可见记录中没有 bolus；这不代表没有输注胰岛素。" : "No bolus is visible in the records; this does not mean no insulin was delivered."
        }
        let qualifier = i.status == .stale ? (language == .chinese ? "历史可见记录" : "stale historical visible record") : (language == .chinese ? "可见记录" : "visible record")
        return language == .chinese ? "\(qualifier)中，最近 bolus 为\(number(units)) U，发生于\(time)；IOB 不可用，后续 bolus 可能未同步。" : "In the \(qualifier), the latest bolus was \(number(units)) U at \(time); IOB is unavailable and later boluses may be missing."
    }
    private func context(_ snapshot: AssistantSnapshot, language: ReplyLanguage) -> String {
        let c = snapshot.currentContext
        guard c.freshness == .fresh else { return language == .chinese ? "\u{76ee}\u{524d}\u{6ca1}\u{6709}\u{8fd1}\u{671f}\u{53ef}\u{7528}\u{7684}\u{751f}\u{6d3b}\u{6570}\u{636e}，\u{6211}\u{4e0d}\u{4f1a}\u{731c}\u{6d4b}。" : "No recent lifestyle data is available; I won't guess." }
        var parts: [String] = []
        if let place = c.placeCategory { parts.append(language == .chinese ? "地点类别：\(place)" : "place category: \(place)") }
        if let steps = c.stepsLast30m { parts.append(language == .chinese ? "\u{8fd1}30\u{5206}\u{949f}\u{6b65}\u{6570}\u{4e3a}\(number(steps))" : "steps in the last 30 minutes: \(number(steps))") }
        if let sleep = c.sleepHoursLastNight { parts.append(language == .chinese ? "\u{6700}\u{8fd1}\u{7761}\u{7720}\u{4e3a}\(number(sleep))\u{5c0f}\u{65f6}" : "latest sleep: \(number(sleep)) hours") }
        if let category = c.currentEventCategory { parts.append(language == .chinese ? "\u{5f53}\u{524d}\u{65e5}\u{7a0b}\u{7c7b}\u{522b}\u{4e3a}\(category)" : "current event category: \(category)") }
        if let next = c.nextEventLocalTime { parts.append(language == .chinese ? "下项日程时间为\(next)" : "next event at \(next)") }
        guard !parts.isEmpty else { return language == .chinese ? "\u{5f53}\u{524d}\u{751f}\u{6d3b}\u{6570}\u{636e}\u{4e0d}\u{5b8c}\u{6574}，\u{6211}\u{4e0d}\u{4f1a}\u{731c}\u{6d4b}\u{7f3a}\u{5931}\u{5185}\u{5bb9}。" : "No current event or place category is available. Empty results do not mean permission was denied." }
        return parts.prefix(3).joined(separator: language == .chinese ? "；" : "; ") + (language == .chinese ? "；\u{8fd9}\u{4e9b}\u{5173}\u{8054}\u{4e0d}\u{8bf4}\u{660e}\u{56e0}\u{679c}。" : "; these associations do not establish causation.")
    }
}
