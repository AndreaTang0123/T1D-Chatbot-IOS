import Foundation

public struct HealthActivityQuery: Sendable {
    public let steps: Bool
    public let heartRate: Bool
    public let unsupportedWindow: Bool
    public init(_ text: String) {
        let s = text.lowercased()
        let general = ["apple health", "health data", "健康数据"].contains(where: s.contains)
        unsupportedWindow = ["yesterday", "week", "month", "last 30", "past 30", "last 7", "昨天", "前天", "上周", "本周", "这周", "一周", "上月", "本月", "最近三天", "过去三天", "30分钟", "半小时", "30 minutes"].contains(where: s.contains)
        steps = general || ["steps", "step count", "stepcount", "步数", "走了多少步"].contains(where: s.contains)
        heartRate = general || ["heart rate", "heartrate", "pulse", "心率", "心跳"].contains(where: s.contains)
            || s.range(of: #"\b(hr|bpm)\b"#, options: .regularExpression) != nil
    }
    public var requested: Bool { steps || heartRate }
}
public enum HealthReadStatus: String, Codable, Sendable { case available, noVisibleRecords, readFailed, collectionDisabled, deviceUnavailable }
/// Query evidence, separate from the 30-minute causal features used for forecasting.
public struct HealthActivityResult: Codable, Sendable {
    public let windowStartLocal: String
    public let windowEndLocal: String
    public let heartRateMeasuredLocal: String?
    public let queriedAt: Date
    public let dayStart: Date
    public let timeZoneIdentifier: String
    public let stepsStatus: HealthReadStatus
    public let stepsToday: Double?
    public let heartRateStatus: HealthReadStatus
    public let heartRateBpm: Double?
    public let heartRateMeasuredAt: Date?
    public init(queriedAt: Date, dayStart: Date, timeZone: TimeZone = .current, stepsStatus: HealthReadStatus, stepsToday: Double? = nil,
                heartRateStatus: HealthReadStatus, heartRateBpm: Double? = nil, heartRateMeasuredAt: Date? = nil) {
        self.queriedAt = queriedAt; self.dayStart = dayStart; self.timeZoneIdentifier = timeZone.identifier
        self.stepsStatus = stepsStatus; self.stepsToday = stepsStatus == .available ? stepsToday.flatMap { $0.isFinite && (0...1000000).contains($0) ? $0 : nil } : nil
        self.heartRateStatus = heartRateStatus
        let valid = heartRateBpm.flatMap { $0.isFinite && (1...300).contains($0) ? $0 : nil }
        let date = heartRateMeasuredAt.flatMap { $0 <= queriedAt && $0 >= queriedAt.addingTimeInterval(-86400) ? $0 : nil }
        self.heartRateBpm = heartRateStatus == .available && date != nil ? valid : nil
        self.heartRateMeasuredAt = self.heartRateBpm == nil ? nil : date
        self.windowStartLocal = LocalEventTime.string(dayStart, in: timeZone)
        self.windowEndLocal = LocalEventTime.string(queriedAt, in: timeZone)
        self.heartRateMeasuredLocal = self.heartRateMeasuredAt.map { LocalEventTime.string($0, in: timeZone) }
    }
    public func isValid(at now: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .gmt
        return now >= queriedAt && now.timeIntervalSince(queriedAt) <= 900 && calendar.isDate(now, inSameDayAs: queriedAt)
    }
    public func response(question: String, language: ReplyLanguage) -> String {
        let q = HealthActivityQuery(question); let zh = language == .chinese
        func missing(_ status: HealthReadStatus, _ name: String) -> String {
            switch status {
            case .collectionDisabled: return zh ? "Apple 健康采集已关闭。" : "Apple Health collection is off."
            case .deviceUnavailable: return zh ? "此设备无法读取 Apple 健康数据。" : "Apple Health is unavailable on this device."
            case .readFailed: return zh ? "\(name)读取失败，请解锁手机后重试。" : "Reading \(name) failed. Unlock your iPhone and retry."
            default: return zh ? "未读到\(name)记录；不能据此判断没有权限或数值为零。" : "No visible \(name) records; this does not establish denied permission or a zero value."
            }
        }
        if q.unsupportedWindow { return zh ? "目前可查询今天截至读取时的步数，以及最近一天的最后一条心率；尚不支持所问的其他时间范围。" : "I can report today’s recorded steps and the latest heart-rate sample within a day; the requested other time window is not supported yet." }
        var parts: [String] = []
        if q.steps {
            if let stepsToday { parts.append(zh ? "今天截至\(windowEndLocal)，Apple 健康记录了\(Int(stepsToday))步。" : "Apple Health records \(Int(stepsToday)) steps today through \(windowEndLocal).") }
            else { parts.append(missing(stepsStatus, zh ? "步数" : "steps")) }
        }
        if q.heartRate {
            if let heartRateBpm, let time = heartRateMeasuredLocal { parts.append(zh ? "最近一次心率为\(heartRateBpm.formatted(.number.precision(.fractionLength(0...1)))) bpm，测量时间为\(time)，不是实时监测。" : "Latest recorded heart rate: \(heartRateBpm.formatted(.number.precision(.fractionLength(0...1)))) bpm at \(time); not a live measurement.") }
            else { parts.append(missing(heartRateStatus, zh ? "最近一天的心率" : "heart rate within the last day")) }
        }
        return parts.joined(separator: zh ? "" : " ")
    }
}
