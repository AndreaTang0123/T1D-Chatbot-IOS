import Foundation

public struct CurrentGlucoseResult: Codable, Sendable {
    public let sourceLocalTime: String?
    public let status: DataStatus
    public let glucoseMgDl: Double?
    public let direction: String?
    public let ageMinutes: Int?
    public let sourceTimestamp: Date?
}
public struct ForecastToolResult: Codable, Sendable {
    public let sourceLocalTime: String?
    public let generatedLocalTime: String?
    public let prediction30mLocalTime: String?
    public let prediction60mLocalTime: String?
    public let available: Bool
    public let generatedAt: Date?
    public let sourceCGMTimestamp: Date?
    public let predicted30m: Double?
    public let predicted60m: Double?
    public let uncertainty30m: Double?
    public let uncertainty60m: Double?
    public let hypoRisk60m: Double?
    public let dataQuality: [String]
    public let modelVersion: String?
    public let featureSchemaVersion: String?
}
public struct RecentInsulinResult: Codable, Sendable {
    public let latestBolusLocalTime: String?
    public let status: DataStatus
    public let latestBolusTime: Date?
    public let latestBolusUnits: Double?
    public let basalRate: Double?
    public let estimatedIOB: Double?
    public let dataAgeMinutes: Int?
    public let coverage: String
}
public struct CurrentContextResult: Codable, Sendable {
    public let observedLocalTime: String?
    public let nextEventLocalTime: String?
    public let calendarDay: CalendarDayResult?
    public let calendarDisplay: String?
    public let access: [String: String]
    public let freshness: DataStatus
    public let timestamp: Date?
    public let stepsLast30m: Double?
    public let heartRate: Double?
    public let workoutCategory: String?
    public let sleepHoursLastNight: Double?
    public let placeCategory: String?
    public let currentEventCategory: String?
    public let nextEventCategory: String?
    public let minutesUntilNextEvent: Int?
}
public struct AssistantSnapshot: Sendable {
    public let timeZone: TimeZone
    public let calendarDay: CalendarDayResult?
    public let contextAccess: [String: String]
    public let glucoseHistory: GlucoseHistorySummary?
    public let glucose: GlucoseSample?
    public let forecast: Forecast?
    public let treatments: [Treatment]
    public let context: LifestyleContext?
    public let now: Date
    public let policy: SafetyPolicy
    public let nextEventCategory: String?
    public let nextEventStart: Date?
    public let currentEventEnd: Date?
    public init(glucose: GlucoseSample?, forecast: Forecast?, treatments: [Treatment], context: LifestyleContext?,
                now: Date, policy: SafetyPolicy = SafetyPolicy(), nextEventCategory: String? = nil,
                nextEventStart: Date? = nil, currentEventEnd: Date? = nil, glucoseHistory: GlucoseHistorySummary? = nil, contextAccess: [String: String] = [:], calendarDay: CalendarDayResult? = nil, timeZone: TimeZone = .current) {
        self.timeZone = timeZone
        self.calendarDay = calendarDay
        self.contextAccess = contextAccess
        self.glucoseHistory = glucoseHistory
        self.glucose = glucose; self.forecast = forecast; self.treatments = treatments; self.context = context
        self.now = now; self.policy = policy; self.nextEventCategory = nextEventCategory
        self.nextEventStart = nextEventStart; self.currentEventEnd = currentEventEnd
    }
    public func rechecked(at time: Date) -> AssistantSnapshot {
        AssistantSnapshot(glucose: glucose, forecast: forecast, treatments: treatments, context: context, now: time,
            policy: policy, nextEventCategory: nextEventCategory, nextEventStart: nextEventStart, currentEventEnd: currentEventEnd, glucoseHistory: glucoseHistory, contextAccess: contextAccess, calendarDay: calendarDay, timeZone: timeZone)
    }
    public var currentGlucose: CurrentGlucoseResult {
        guard let g = glucose, g.glucose.isFinite, (40...400).contains(g.glucose), g.timestamp <= now else {
            return CurrentGlucoseResult(sourceLocalTime: nil, status: .unavailable, glucoseMgDl: nil, direction: nil, ageMinutes: nil, sourceTimestamp: nil)
        }
        return CurrentGlucoseResult(sourceLocalTime: LocalEventTime.string(g.timestamp, in: timeZone), status: g.isFresh(at: now, threshold: policy.cgmStaleSeconds) ? .fresh : .stale,
            glucoseMgDl: g.glucose, direction: GlucoseTrend(direction: g.direction).label,
            ageMinutes: Int(now.timeIntervalSince(g.timestamp) / 60), sourceTimestamp: g.timestamp)
    }
    public var forecastResult: ForecastToolResult {
        let cgm = currentGlucose
        let f = forecast
        let available = cgm.status == .fresh && f?.sourceTimestamp == cgm.sourceTimestamp &&
            f.map { $0.generatedAt <= now && now.timeIntervalSince($0.generatedAt) <= policy.cgmStaleSeconds &&
                $0.schema == FeatureRow.schema && [$0.glucose30, $0.glucose60].allSatisfy { $0.isFinite && (20...600).contains($0) } &&
                [$0.uncertainty30, $0.uncertainty60].allSatisfy { $0.isFinite && $0 >= 0 } } == true
        return ForecastToolResult(sourceLocalTime: available ? f.map { LocalEventTime.string($0.sourceTimestamp, in: timeZone) } : nil,
            generatedLocalTime: available ? f.map { LocalEventTime.string($0.generatedAt, in: timeZone) } : nil,
            prediction30mLocalTime: available ? f.map { LocalEventTime.string($0.sourceTimestamp.addingTimeInterval(1800), in: timeZone) } : nil,
            prediction60mLocalTime: available ? f.map { LocalEventTime.string($0.sourceTimestamp.addingTimeInterval(3600), in: timeZone) } : nil,
            available: available, generatedAt: available ? f?.generatedAt : nil,
            sourceCGMTimestamp: available ? f?.sourceTimestamp : nil, predicted30m: available ? f?.glucose30 : nil,
            predicted60m: available ? f?.glucose60 : nil, uncertainty30m: available ? f?.uncertainty30 : nil,
            uncertainty60m: available ? f?.uncertainty60 : nil,
            hypoRisk60m: available && policy.hypoRiskThreshold != nil ? f?.lowRisk.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil } : nil,
            dataQuality: available ? f?.flags ?? [] : ["forecast_unavailable"],
            modelVersion: available ? f?.modelVersion : nil, featureSchemaVersion: available ? f?.schema : nil)
    }
    public var recentInsulin: RecentInsulinResult {
        let events = treatments.filter { $0.timestamp <= now }.sorted { $0.timestamp < $1.timestamp }
        let bolus = Treatment.latestBolus(in: events, at: now)
        let age = bolus.map { Int(now.timeIntervalSince($0.timestamp) / 60) }
        let basal = events.last { $0.kind.lowercased() == "temp basal" && $0.rate != nil &&
            ($0.duration ?? 0) > now.timeIntervalSince($0.timestamp)/60 }
        return RecentInsulinResult(latestBolusLocalTime: bolus.map { LocalEventTime.string($0.timestamp, in: timeZone) }, status: bolus == nil ? .unavailable : now.timeIntervalSince(bolus!.timestamp) > policy.pumpStaleSeconds ? .stale : .fresh,
            latestBolusTime: bolus?.timestamp, latestBolusUnits: bolus?.insulin, basalRate: basal?.rate,
            estimatedIOB: nil, dataAgeMinutes: age, coverage: "Visible records only; absence is not zero delivery. IOB is unavailable.")
    }
    public var currentContext: CurrentContextResult {
        let c = context.flatMap { $0.timestamp <= now && now.timeIntervalSince($0.timestamp) <= policy.contextStaleSeconds ? $0 : nil }
        func valid(_ value: Double?, maximum: Double) -> Double? {
            value.flatMap { $0.isFinite && $0 >= 0 && $0 <= maximum ? $0 : nil }
        }
        let hasCalendar = c?.calendar != nil && currentEventEnd.map { $0 > now } != false
        let next = c != nil && nextEventStart.map { $0 > now } == true
        return CurrentContextResult(observedLocalTime: c.map { LocalEventTime.string($0.timestamp, in: timeZone) },
            nextEventLocalTime: next ? nextEventStart.map { LocalEventTime.string($0, in: timeZone) } : nil, calendarDay: calendarDay, calendarDisplay: calendarDay?.response(language: .english, at: now), access: contextAccess, freshness: c == nil ? .unavailable : .fresh, timestamp: c?.timestamp,
            stepsLast30m: valid(c?.steps, maximum: 100000), heartRate: valid(c?.heartRate, maximum: 250),
            workoutCategory: c?.workoutActive.map { $0 ? "recent_or_active" : "no_recent_visible_workout" },
            sleepHoursLastNight: valid(c?.sleepHours, maximum: 36), placeCategory: c?.place,
            currentEventCategory: hasCalendar ? c?.calendar : nil, nextEventCategory: next ? nextEventCategory : nil,
            minutesUntilNextEvent: next ? nextEventStart.map { Int($0.timeIntervalSince(now)/60) } : nil)
    }
}
public enum ToolJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
