import Foundation

public struct GlucoseSample: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let timestamp: Date
    public let glucose: Double
    public let direction: String?
    public let receivedAt: Date
    public init(id: String, timestamp: Date, glucose: Double, direction: String? = nil, receivedAt: Date) {
        self.id = id; self.timestamp = timestamp; self.glucose = glucose
        self.direction = direction; self.receivedAt = receivedAt
    }
    public func isFresh(at now: Date, threshold: TimeInterval = SafetyPolicy().cgmStaleSeconds) -> Bool {
        (40...400).contains(glucose) && timestamp <= now && now.timeIntervalSince(timestamp) <= threshold
    }
}

public struct Treatment: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let timestamp: Date
    public let kind: String
    public let insulin: Double?
    public let carbs: Double?
    public let rate: Double?
    public let duration: Double?
    public init(id: String, timestamp: Date, kind: String, insulin: Double? = nil, carbs: Double? = nil,
                rate: Double? = nil, duration: Double? = nil) {
        self.id = id; self.timestamp = timestamp; self.kind = kind; self.insulin = insulin
        self.carbs = carbs; self.rate = rate; self.duration = duration
    }
}

public struct LifestyleContext: Codable, Sendable, Equatable {
    public var timestamp: Date
    public var steps: Double?
    public var heartRate: Double?
    public var workoutActive: Bool?
    public var sleepHours: Double?
    public var place: String?
    public var calendar: String?
    public init(timestamp: Date, steps: Double? = nil, heartRate: Double? = nil, workoutActive: Bool? = nil,
                sleepHours: Double? = nil, place: String? = nil, calendar: String? = nil) {
        self.timestamp = timestamp; self.steps = steps; self.heartRate = heartRate
        self.workoutActive = workoutActive; self.sleepHours = sleepHours; self.place = place; self.calendar = calendar
    }
}

public struct FeatureRow: Codable, Sendable {
    public let timestamp: Date
    public let sourceTimestamp: Date
    public let values: [Double]
    public let missing: [String]
    public static let schema = "joe.features.v1"
    public static let names = ["glucose", "delta_5m", "slope_15m", "mean_30m", "std_30m",
        "basal_rate", "bolus_30m", "estimated_iob", "carbs_2h", "estimated_cob",
        "steps_30m", "heart_rate", "workout_active", "sleep_hours", "place", "calendar",
        "hour_sin", "hour_cos", "weekday"]
    // Model receives values followed by one missingness indicator per value.
    public var modelInput: [Double] { values + Self.names.map { missing.contains($0) ? 1 : 0 } }
}

public enum DataIssue: String, Error, LocalizedError {
    case noGlucose, staleGlucose, insufficientHistory, invalidData, modelMissing, schemaMismatch, invalidPrediction
    public var errorDescription: String? {
        switch self {
        case .noGlucose: "No CGM data available"
        case .staleGlucose: "CGM data is stale. Forecasting is paused."
        case .insufficientHistory: "At least 30 minutes of continuous CGM history is required"
        case .invalidData: "Invalid data"
        case .modelMissing: "No trained Core ML model is installed"
        case .schemaMismatch: "Model and feature schema versions do not match"
        case .invalidPrediction: "Invalid model output. Forecasts are hidden."
        }
    }
}

public struct Forecast: Codable, Sendable, Identifiable {
    public let id: UUID
    public let generatedAt: Date
    public let sourceTimestamp: Date
    public let current: Double
    public let glucose30: Double
    public let glucose60: Double
    public let lowRisk: Double?
    public let uncertainty30: Double
    public let uncertainty60: Double
    public let modelVersion: String
    public let schema: String
    public let flags: [String]
    public init(at: Date, row: FeatureRow, outputs: [Double], uncertainty: [Double], modelVersion: String) throws {
        guard outputs.count == 2, uncertainty.count == 2,
              outputs.allSatisfy({ $0.isFinite && (20...600).contains($0) }),
              uncertainty.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw DataIssue.invalidPrediction }
        id = UUID(); generatedAt = at; sourceTimestamp = row.sourceTimestamp; current = row.values[0]
        glucose30 = outputs[0]; glucose60 = outputs[1]; lowRisk = nil
        uncertainty30 = uncertainty[0]; uncertainty60 = uncertainty[1]
        self.modelVersion = modelVersion; schema = FeatureRow.schema; flags = row.missing
    }
    public func actual(horizon: TimeInterval, samples: [GlucoseSample], asOf: Date) -> GlucoseSample? {
        let target = sourceTimestamp.addingTimeInterval(horizon)
        // Wait until the entire matching window has elapsed; prevent an early match winning permanently.
        guard asOf >= target.addingTimeInterval(150) else { return nil }
        return samples.filter { $0.timestamp <= asOf && abs($0.timestamp.timeIntervalSince(target)) <= 150 }
            .min { abs($0.timestamp.timeIntervalSince(target)) < abs($1.timestamp.timeIntervalSince(target)) }
    }
}
