import Foundation

public struct HealthActivityQuery: Sendable {
    public let latestWorkout: Bool
    public let weekly: Bool
    public let steps: Bool
    public let heartRate: Bool
    public let unsupportedWindow: Bool
    public init(_ text: String) {
        let s = text.lowercased()
        let general = ["apple health", "health data", "健康数据"].contains(where: s.contains)
        let activity = ["activity", "activities", "workout", "exercise", "exercis", "运动", "锻炼", "健身", "活动记录", "活动日志"].contains(where: s.contains) || s.range(of: #"\bwork(?:ed|ing|s)?[\s-]+out\b"#, options: .regularExpression) != nil
        latestWorkout = activity && ["last time", "last workout", "last work out", "last worked out", "last exercise", "most recent", "latest", "上次", "上一次", "最近一次", "最后一次"].contains(where: s.contains)
        let weekWindow = ["week", "last 7", "past 7", "一周", "七天", "7天", "本周", "这周", "上周"].contains(where: s.contains)
        let otherWindow = ["yesterday", "month", "last 30", "past 30", "昨天", "前天", "上月", "本月", "最近三天", "过去三天", "30分钟", "半小时", "30 minutes", "today", "今天"].contains(where: s.contains)
        // Unqualified activity-log questions default to the supported seven-day record query.
        weekly = ((general || activity || ["steps", "步数"].contains(where: s.contains)) && weekWindow) || (activity && !otherWindow)
        unsupportedWindow = !weekly && (["yesterday", "week", "month", "last 30", "past 30", "last 7", "昨天", "前天", "上周", "本周", "这周", "一周", "上月", "本月", "最近三天", "过去三天", "30分钟", "半小时", "30 minutes"].contains(where: s.contains) || activity)
        steps = weekly || general || ["steps", "step count", "stepcount", "步数", "走了多少步"].contains(where: s.contains)
        activityRequested = activity
        heartRate = general || ["heart rate", "heartrate", "pulse", "心率", "心跳"].contains(where: s.contains)
            || s.range(of: #"\b(hr|bpm)\b"#, options: .regularExpression) != nil
    }
    public var requested: Bool { weekly || steps || heartRate || activityRequested }
    private let activityRequested: Bool
}
public enum HealthReadStatus: String, Codable, Sendable { case available, noVisibleRecords, readFailed, collectionDisabled, deviceUnavailable }
/// Query evidence, separate from the 30-minute causal features used for forecasting.
public struct HealthActivityResult: Codable, Sendable {
    public var weeklyHistory: WeeklyActivityResult? = nil
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
        if q.latestWorkout, let history = weeklyHistory { return history.latestWorkoutResponse(language: language) }
        if q.weekly { return weeklyHistory?.response(language: language) ?? (zh ? "尚未读取最近一周运动记录。" : "Weekly activity records have not been read.") }
        func missing(_ status: HealthReadStatus, _ name: String) -> String {
            switch status {
            case .collectionDisabled: return zh ? "Apple 健康采集已关闭。" : "Apple Health collection is off."
            case .deviceUnavailable: return zh ? "此设备无法读取 Apple 健康数据。" : "Apple Health is unavailable on this device."
            case .readFailed: return zh ? "\(name)读取失败，请解锁手机后重试。" : "Reading \(name) failed. Unlock your iPhone and retry."
            default: return zh ? "未读到\(name)记录；不能据此判断没有权限或数值为零。" : "No visible \(name) records; this does not establish denied permission or a zero value."
            }
        }
        if q.unsupportedWindow { return zh ? "可查询最近七天的运动记录、今天的步数或最近一天的最后一条心率。请明确选择这些范围之一。" : "I can read activity logs for the past 7 local days, today’s steps, or the latest heart-rate sample within a day. The requested other range is not supported; please choose one of these ranges." }
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

/// Seven local calendar days including today; missing records remain missing.
public struct WeeklyActivityDay: Codable, Sendable {
    public let date: String
    public let steps: Double?
    public let stepsStatus: HealthReadStatus
    public let workouts: [String]
    public let workoutMinutes: Double?
    public let workoutStatus: HealthReadStatus
    public init(date: String, steps: Double?, stepsStatus: HealthReadStatus, workouts: [String], workoutMinutes: Double?, workoutStatus: HealthReadStatus) {
        self.date = date; self.steps = steps; self.stepsStatus = stepsStatus
        self.workouts = workouts; self.workoutMinutes = workoutMinutes; self.workoutStatus = workoutStatus
    }
}
public struct RecordedWorkout: Codable, Sendable {
    public let category: String
    public let start: Date
    public let end: Date
    public let startLocal: String
    public let endLocal: String
    public let durationMinutes: Double
    public init(category: String, start: Date, end: Date, durationMinutes: Double, timeZone: TimeZone = .current) {
        self.category = category; self.start = start; self.end = end
        self.startLocal = LocalEventTime.string(start, in: timeZone)
        self.endLocal = LocalEventTime.string(end, in: timeZone)
        self.durationMinutes = durationMinutes
    }
}
public struct WeeklyActivityResult: Codable, Sendable {
    public let latestWorkout: RecordedWorkout?
    public let startLocal: String
    public let endLocal: String
    public let days: [WeeklyActivityDay]
    public init(startLocal: String, endLocal: String, days: [WeeklyActivityDay], latestWorkout: RecordedWorkout? = nil) {
        self.latestWorkout = latestWorkout
        self.startLocal = startLocal; self.endLocal = endLocal; self.days = days
    }
    public func latestWorkoutResponse(language: ReplyLanguage) -> String {
        let zh = language == .chinese
        guard let workout = latestWorkout else {
            let recordedDays = days.filter { $0.workoutMinutes != nil }.sorted { $0.date > $1.date }
            if let day = recordedDays.first, let minutes = day.workoutMinutes {
                return zh ? "最近七天内可见的最近一次训练日期为\(day.date)，当天记录了\(Int(minutes))分钟训练；现有摘要没有单次训练的具体时间。" : "The latest visible workout date within the queried 7 days is \(day.date), with \(Int(minutes)) recorded workout minutes that day; this summary does not contain the individual workout time."
            }
            return response(language: language) + (zh ? "\n在所查询的七天内未读到训练记录，不能判断你上一次实际运动的时间。" : "\nNo workout record is visible in the queried 7 days; I cannot establish when you last actually exercised.")
        }
        return zh ? "在所查询的最近七天内，可见的最近一条训练记录是\(workout.category)，开始时间\(workout.startLocal)，结束时间\(workout.endLocal)，记录时长\(Int(workout.durationMinutes))分钟。这是可读取的训练记录，不代表你实际所有的运动。" : "The latest visible workout within the queried 7 days is \(workout.category): started \(workout.startLocal), ended \(workout.endLocal), with \(Int(workout.durationMinutes)) recorded minutes. This describes visible records, not every activity you actually did."
    }
    public var hasVisibleRecords: Bool { days.contains { $0.steps != nil || $0.workoutMinutes != nil } }
    public func response(language: ReplyLanguage) -> String {
        let zh = language == .chinese
        guard !days.isEmpty else { return zh ? "Apple 健康采集已关闭；无法读取最近一周运动记录。" : "Apple Health collection is off; weekly activity records are unavailable." }
        let header = zh ? "Apple 健康最近一周运动记录（含今天，今天尚未结束）：" : "Apple Health activity over 7 local days including today (today is incomplete):"
        func statusText(_ status: HealthReadStatus) -> String {
            switch status {
            case .available: return zh ? "已读取" : "Available"
            case .noVisibleRecords: return zh ? "未读到记录（不代表没有运动或权限被拒绝）" : "No visible records (not proof of inactivity or denied access)"
            case .readFailed: return zh ? "读取失败，请解锁手机重试" : "Read failed; unlock iPhone and retry"
            case .collectionDisabled: return zh ? "健康采集已关闭" : "Health collection is off"
            case .deviceUnavailable: return zh ? "设备不支持健康数据" : "Health data unavailable on this device"
            }
        }
        let rows = days.map { day in
            day.date + " | " + (day.steps.map { String(Int($0)) + (zh ? "步" : " steps") } ?? (zh ? "步数：" : "Steps: ") + statusText(day.stepsStatus))
                + " | " + (day.workoutMinutes.map { String(Int($0)) + (zh ? "分钟训练" : " workout minutes") } ?? (zh ? "训练：" : "Workouts: ") + statusText(day.workoutStatus))
                + (day.workouts.isEmpty ? "" : " | " + day.workouts.joined(separator: "; "))
        }
        return ([header, startLocal + " through " + endLocal] + rows + [zh ? "缺失记录不代表没有运动；仅总结实际记录，不推断血糖影响或训练强度。" : "Missing records do not establish inactivity. Analyze recorded patterns only; do not infer glucose effects or exercise intensity."]).joined(separator: "\n")
    }
}
