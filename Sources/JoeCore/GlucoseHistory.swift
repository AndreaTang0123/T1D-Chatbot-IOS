import Foundation

/// Historical observations only. Equal-weight five-minute bins prevent overlapping sources
/// from inflating coverage; percentages are sample-based, never clinical time-in-range.
public struct GlucoseHistoryDay: Codable, Sendable {
    public let localDate: String
    public let observedBins: Int
    public let meanMgDl: Double
    public let minimumMgDl: Double
    public let maximumMgDl: Double
}
public struct GlucoseHistorySummary: Codable, Sendable {
    public let windowStartLocal: String
    public let windowEndLocal: String
    public let latestLocalTime: String
    public let timeZoneIdentifier: String
    public let minimumMgDl: Double
    public let maximumMgDl: Double
    public let minimumLocalTime: String
    public let maximumLocalTime: String
    public let latestGlucoseMgDl: Double
    public let daily: [GlucoseHistoryDay]
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
    public init?(samples: [GlucoseSample], days: Int, now: Date, timeZone: TimeZone = .current) {
        guard [3, 7, 14, 30].contains(days) else { return nil }
        let start = now.addingTimeInterval(-Double(days)*86400)
        let valid = samples.filter { $0.timestamp >= start && $0.timestamp <= now && $0.glucose.isFinite && (20...600).contains($0.glucose) }
        // Deterministic selection: latest timestamp, then stable identifier in overlapping bins.
        let sorted = valid.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
        var bins: [Int: GlucoseSample] = [:]
        for sample in sorted {
            let key = Int(floor(sample.timestamp.timeIntervalSince1970/300))
            // Direct Nightscout observations take priority over delayed duplicate Health records.
            if let old = bins[key], old.sourceName?.lowercased().contains("nightscout") == true,
               sample.sourceName?.lowercased().contains("nightscout") != true { continue }
            bins[key] = sample
        }
        guard !bins.isEmpty, let latestSample = bins.values.max(by: { $0.timestamp < $1.timestamp }) else { return nil }
        let selected = bins.values.sorted { a, b in a.glucose == b.glucose ? a.timestamp < b.timestamp : a.glucose < b.glucose }
        minimumMgDl = selected.first!.glucose; maximumMgDl = selected.last!.glucose
        minimumLocalTime = LocalEventTime.string(selected.first!.timestamp, in: timeZone)
        maximumLocalTime = LocalEventTime.string(selected.last!.timestamp, in: timeZone)
        let values = bins.values.map(\.glucose)
        let count = Double(values.count)
        let mean = values.reduce(0,+)/count
        func rounded(_ value: Double) -> Double { (value*10).rounded()/10 }
        windowStartLocal = LocalEventTime.string(start, in: timeZone)
        windowEndLocal = LocalEventTime.string(now, in: timeZone)
        latestLocalTime = LocalEventTime.string(latestSample.timestamp, in: timeZone)
        timeZoneIdentifier = timeZone.identifier; latestGlucoseMgDl = latestSample.glucose
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone; f.dateFormat = "yyyy-MM-dd"
        let grouped = Dictionary(grouping: Array(bins.values), by: { f.string(from: $0.timestamp) })
        let dailySummaries = grouped.keys.sorted().map { date in
            let values = grouped[date]!.map(\.glucose)
            return GlucoseHistoryDay(localDate: date, observedBins: values.count,
                meanMgDl: rounded(values.reduce(0,+) / Double(values.count)), minimumMgDl: values.min()!, maximumMgDl: values.max()!)
        }
        daily = days == 3 ? dailySummaries : []
        self.days = days; self.start = start; end = now; self.latest = latestSample.timestamp
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
        if s.range(of: #"(?:last|past|recent)\s+(?:3|three)\s+days|(?:最近|近|过去)(?:3|三)天|(?:last|past)\s+72\s+hours|(?:最近|过去)72小时"#, options: .regularExpression) != nil { return 3 }
        if ["30", "month", "一个月"].contains(where: s.contains) { return 30 }
        if ["14", "two weeks", "两周", "两个星期"].contains(where: s.contains) { return 14 }
        if ["7", "week", "一周", "一个星期"].contains(where: s.contains) { return 7 }
        return defaultDays
    }
    public var supportedNumbers: [Double] {
        [Double(days), Double(days * 24), Double(observedBins), coveragePercent, meanMgDl, coefficientOfVariationPercent,
         below70Percent, within70To180Percent, above180Percent, latestGlucoseMgDl, minimumMgDl, maximumMgDl, 5, 70, 180] + daily.flatMap { [Double($0.observedBins), $0.meanMgDl, $0.minimumMgDl, $0.maximumMgDl] }
    }
    public func description(language: ReplyLanguage) -> String {
        let rows = daily.map { day in
            language == .chinese ? "\(day.localDate)：观测均值\(day.meanMgDl)、最低\(day.minimumMgDl)、最高\(day.maximumMgDl) mg/dL（\(day.observedBins) 个五分钟观测桶）" : "\(day.localDate): observed mean \(day.meanMgDl), min \(day.minimumMgDl), max \(day.maximumMgDl) mg/dL (\(day.observedBins) observed 5-minute bins)"
        }
        let detail = rows.isEmpty ? "" : "\n" + rows.joined(separator: "\n")
        if language == .chinese {
            return "来源：\(sources.joined(separator: ", "))；历史窗口 \(windowStartLocal) 至 \(windowEndLocal)。近\(days)天历史血糖：观测覆盖率\(coveragePercent)%，平均\(meanMgDl) mg/dL，变异系数\(coefficientOfVariationPercent)%；观测样本中低于70、70–180、高于180 mg/dL分别为\(below70Percent)%、\(within70To180Percent)%、\(above180Percent)%。数据可能延迟且不完整，不代表当前血糖；这些是样本占比，不是达标时间，也不能确定波动原因。" + detail
        }
        return "Historical glucose (\(sources.joined(separator: ", "))) from \(windowStartLocal) through \(windowEndLocal). Over \(days) days: observed coverage \(coveragePercent)%, mean \(meanMgDl) mg/dL, CV \(coefficientOfVariationPercent)%; observed samples below 70, within 70–180, and above 180 mg/dL: \(below70Percent)%, \(within70To180Percent)%, \(above180Percent)%. Delayed/incomplete history is not current glucose; sample percentages are not time-in-range and cannot establish causes." + detail
    }
}
