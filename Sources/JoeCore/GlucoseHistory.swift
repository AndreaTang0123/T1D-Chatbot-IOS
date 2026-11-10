import Foundation

/// Historical observations only. Equal-weight five-minute bins prevent overlapping sources
/// from inflating coverage; percentages are sample-based, never clinical time-in-range.
public struct GlucoseHistorySummary: Codable, Sendable {
    public let days: Int
    public let start: Date
    public let end: Date
    public let latest: Date
    public let sources: [String]
    public let observedBins: Int
    public let coveragePercent: Double
    public let meanMgDl: Double
    public let coefficientOfVariationPercent: Double
    public let below70Percent: Double
    public let within70To180Percent: Double
    public let above180Percent: Double
    public init?(samples: [GlucoseSample], days: Int, now: Date) {
        guard [7, 14, 30].contains(days) else { return nil }
        let start = now.addingTimeInterval(-Double(days)*86400)
        let valid = samples.filter { $0.timestamp >= start && $0.timestamp <= now && $0.glucose.isFinite && (20...600).contains($0.glucose) }
        // Deterministic selection: latest timestamp, then stable identifier in overlapping bins.
        let sorted = valid.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
        var bins: [Int: GlucoseSample] = [:]
        for sample in sorted { bins[Int(floor(sample.timestamp.timeIntervalSince1970/300))] = sample }
        guard !bins.isEmpty, let latest = valid.map(\.timestamp).max() else { return nil }
        let values = bins.values.map(\.glucose)
        let count = Double(values.count)
        let mean = values.reduce(0,+)/count
        func rounded(_ value: Double) -> Double { (value*10).rounded()/10 }
        self.days = days; self.start = start; end = now; self.latest = latest
        sources = Array(Set(bins.values.compactMap(\.sourceName))).sorted()
        observedBins = values.count
        coveragePercent = rounded(min(100, count / Double(days*288)*100))
        meanMgDl = rounded(mean)
        coefficientOfVariationPercent = rounded(sqrt(values.map { pow($0-mean, 2) }.reduce(0,+)/count)/mean*100)
        below70Percent = rounded(Double(values.filter { $0 < 70 }.count)/count*100)
        within70To180Percent = rounded(Double(values.filter { (70...180).contains($0) }.count)/count*100)
        above180Percent = rounded(Double(values.filter { $0 > 180 }.count)/count*100)
    }
    public static func requestedDays(_ text: String, defaultDays: Int) -> Int {
        let s = text.lowercased()
        if ["30", "month", "一个月"].contains(where: s.contains) { return 30 }
        if ["14", "two weeks", "两周", "两个星期"].contains(where: s.contains) { return 14 }
        if ["7", "week", "一周", "一个星期"].contains(where: s.contains) { return 7 }
        return defaultDays
    }
    public var supportedNumbers: [Double] {
        [Double(days), Double(observedBins), coveragePercent, meanMgDl, coefficientOfVariationPercent,
         below70Percent, within70To180Percent, above180Percent, 70, 180]
    }
    public func description(language: ReplyLanguage) -> String {
        if language == .chinese {
            return "Apple 健康近\(days)天历史血糖：观测覆盖率\(coveragePercent)%，平均\(meanMgDl) mg/dL，变异系数\(coefficientOfVariationPercent)%；观测样本中低于70、70–180、高于180 mg/dL分别为\(below70Percent)%、\(within70To180Percent)%、\(above180Percent)%。数据可能延迟且不完整，不代表当前血糖；这些是样本占比，不是达标时间，也不能确定波动原因。"
        }
        return "Apple Health historical glucose over \(days) days: observed coverage \(coveragePercent)%, mean \(meanMgDl) mg/dL, CV \(coefficientOfVariationPercent)%; observed samples below 70, within 70–180, and above 180 mg/dL: \(below70Percent)%, \(within70To180Percent)%, \(above180Percent)%. Delayed/incomplete history is not current glucose; sample percentages are not time-in-range and cannot establish causes."
    }
}
