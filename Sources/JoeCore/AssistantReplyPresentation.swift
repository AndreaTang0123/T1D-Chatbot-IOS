import Foundation

/// Present verified facts after validation; local day labels never participate in fact checking.
public enum AssistantReplyPresentation {
    /// Resolve day labels in the phone's timezone at reply time, including DST and year boundaries.
    public static func localTimes(_ text: String, relativeTo now: Date, in zone: TimeZone, language: ReplyLanguage) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: now)
        let yesterday = formatter.string(from: calendar.date(byAdding: .day, value: -1, to: now)!)
        // Strip only the timestamp annotation emitted by LocalEventTime, not event-title parentheses.
        let pattern = #"\b(\d{4}-\d{2}-\d{2})(?: (\d{2}:\d{2}))?(?: \([^()\n]+, UTC[+-]\d{2}:\d{2}\))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result), let dayRange = Range(match.range(at: 1), in: text) else { continue }
            let day = String(text[dayRange])
            let label = day == today ? (language == .chinese ? "今天" : "today") : day == yesterday ? (language == .chinese ? "昨天" : "yesterday") : day
            let time = Range(match.range(at: 2), in: text).map { " " + text[$0] } ?? ""
            result.replaceSubrange(range, with: label + time)
        }
        return result
    }
    public static func format(_ text: String, language: ReplyLanguage, evidence: Set<ToolKind>) -> String {
        guard evidence.contains(.history) else { return text }
        let labels: [String: String] = language == .chinese ? [
            "meanMgDl": "平均血糖（mg/dL）", "minimumMgDl": "最低血糖（mg/dL）", "maximumMgDl": "最高血糖（mg/dL）",
            "observedBins": "已观测数据桶", "coveragePercent": "观测覆盖率（%）", "coefficientOfVariationPercent": "变异系数（%）"
        ] : [
            "meanMgDl": "mean glucose (mg/dL)", "minimumMgDl": "minimum glucose (mg/dL)", "maximumMgDl": "maximum glucose (mg/dL)",
            "observedBins": "observed bins", "coveragePercent": "observed coverage (%)", "coefficientOfVariationPercent": "CV (%)"
        ]
        return labels.reduce(text) { result, pair in
            result.replacingOccurrences(of: "\\b" + NSRegularExpression.escapedPattern(for: pair.key) + "\\b", with: pair.value, options: .regularExpression)
        }
    }
}
