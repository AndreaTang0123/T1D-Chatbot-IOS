import Foundation
import SwiftData
import JoeCore

@Model final class StoredGlucose {
    @Attribute(.unique) var id: String
    var timestamp: Date
    var payload: Data
    init(_ sample: GlucoseSample) throws {
        id = sample.id; timestamp = sample.timestamp; payload = try JSONEncoder().encode(sample)
    }
}
@Model final class StoredTreatment {
    @Attribute(.unique) var id: String
    var timestamp: Date
    var payload: Data
    init(_ sample: Treatment) throws {
        id = sample.id; timestamp = sample.timestamp; payload = try JSONEncoder().encode(sample)
    }
}
@Model final class StoredContext {
    @Attribute(.unique) var bucket: Int
    var timestamp: Date
    var payload: Data
    init(_ sample: LifestyleContext) throws {
        bucket = Int(sample.timestamp.timeIntervalSince1970/300); timestamp = sample.timestamp
        payload = try JSONEncoder().encode(sample)
    }
}
@Model final class StoredForecast {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var sourceTimestamp: Date
    var payload: Data
    var actual30: Double?
    var actual60: Double?
    var actualTimestamp30: Date?
    var actualTimestamp60: Date?
    var error30: Double?
    var error60: Double?
    init(_ forecast: Forecast) throws {
        id = forecast.id; timestamp = forecast.generatedAt; sourceTimestamp = forecast.sourceTimestamp
        payload = try JSONEncoder().encode(forecast)
    }
}
@Model final class StoredProfile {
    @Attribute(.unique) var key: String
    var receivedAt: Date
    var payload: Data
    init(data: Data, at: Date) { key = "active"; receivedAt = at; payload = data }
}
@Model final class StoredFeature {
    @Attribute(.unique) var sourceTimestamp: Date
    var timestamp: Date
    var schema: String
    var payload: Data
    init(_ row: FeatureRow) throws {
        sourceTimestamp = row.sourceTimestamp; timestamp = row.timestamp; schema = FeatureRow.schema
        payload = try JSONEncoder().encode(row)
    }
}

@Model final class StoredAssistantTurn {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var isRegression: Bool
    var payload: Data
    init(_ turn: AssistantTurnRecord) throws {
        id = turn.id; timestamp = turn.timestamp; isRegression = turn.regressionCaseID != nil
        payload = try JSONEncoder().encode(turn)
    }
}
