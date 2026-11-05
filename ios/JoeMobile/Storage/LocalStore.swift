import Foundation
import SwiftData
import JoeCore

@MainActor final class LocalStore {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    init() throws {
        let schema = Schema([StoredGlucose.self, StoredTreatment.self, StoredContext.self, StoredForecast.self,
                             StoredProfile.self, StoredFeature.self])
        let config = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [config])
        // Health records stay local and are protected while the device is locked before first unlock.
        let url = config.url
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    }
    func glucose() throws -> [GlucoseSample] {
        try context.fetch(FetchDescriptor<StoredGlucose>(sortBy: [SortDescriptor(\.timestamp)]))
            .map { try JSONDecoder().decode(GlucoseSample.self, from: $0.payload) }
    }
    func treatments() throws -> [Treatment] {
        try context.fetch(FetchDescriptor<StoredTreatment>(sortBy: [SortDescriptor(\.timestamp)]))
            .map { try JSONDecoder().decode(Treatment.self, from: $0.payload) }
    }
    func ingest(glucose: [GlucoseSample], treatments: [Treatment], profile: Data?, at: Date) throws {
        do {
            // Upsert corrections without creating duplicate local records.
            let g = try context.fetch(FetchDescriptor<StoredGlucose>())
            var existingG = Dictionary(g.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for sample in glucose {
                if let record = existingG[sample.id] { record.payload = try JSONEncoder().encode(sample); record.timestamp = sample.timestamp }
                else { let record = try StoredGlucose(sample); context.insert(record); existingG[sample.id] = record }
            }
            let p = try context.fetch(FetchDescriptor<StoredTreatment>())
            var existingP = Dictionary(p.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for sample in treatments {
                if let record = existingP[sample.id] { record.payload = try JSONEncoder().encode(sample); record.timestamp = sample.timestamp }
                else { let record = try StoredTreatment(sample); context.insert(record); existingP[sample.id] = record }
            }
            if let profile {
                let existing = try context.fetch(FetchDescriptor<StoredProfile>()).first
                if let existing { existing.payload = profile; existing.receivedAt = at }
                else { context.insert(StoredProfile(data: profile, at: at)) }
            }
            try context.save()
        } catch { context.rollback(); throw error }
    }
    func save(context sample: LifestyleContext) throws {
        let bucket = Int(sample.timestamp.timeIntervalSince1970/300)
        if let existing = try context.fetch(FetchDescriptor<StoredContext>(predicate: #Predicate { $0.bucket == bucket })).first {
            existing.payload = try JSONEncoder().encode(sample); existing.timestamp = sample.timestamp
        } else { context.insert(try StoredContext(sample)) }
        try context.save()
    }
    func contexts() throws -> [LifestyleContext] {
        try context.fetch(FetchDescriptor<StoredContext>(sortBy: [SortDescriptor(\.timestamp)]))
            .map { try JSONDecoder().decode(LifestyleContext.self, from: $0.payload) }
    }
    func save(feature: FeatureRow) throws {
        let source = feature.sourceTimestamp
        guard try context.fetch(FetchDescriptor<StoredFeature>(predicate: #Predicate { $0.sourceTimestamp == source })).isEmpty else { return }
        context.insert(try StoredFeature(feature)); try context.save()
    }
    func forecasts() throws -> [StoredForecast] {
        try context.fetch(FetchDescriptor<StoredForecast>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)]))
    }
    func save(forecast: Forecast) throws {
        let source = forecast.sourceTimestamp
        guard try context.fetch(FetchDescriptor<StoredForecast>(predicate: #Predicate { $0.sourceTimestamp == source })).isEmpty else { return }
        context.insert(try StoredForecast(forecast)); try context.save()
    }
    func matchActuals(samples: [GlucoseSample], now: Date) throws {
        for record in try forecasts() {
            let f = try JSONDecoder().decode(Forecast.self, from: record.payload)
            if let actual = f.actual(horizon: 1800, samples: samples, asOf: now) {
                record.actual30 = actual.glucose; record.actualTimestamp30 = actual.timestamp; record.error30 = f.glucose30-actual.glucose
            }
            if let actual = f.actual(horizon: 3600, samples: samples, asOf: now) {
                record.actual60 = actual.glucose; record.actualTimestamp60 = actual.timestamp; record.error60 = f.glucose60-actual.glucose
            }
        }
        try context.save()
    }
    func erase() throws {
        try context.delete(model: StoredForecast.self); try context.delete(model: StoredFeature.self)
        try context.delete(model: StoredContext.self); try context.delete(model: StoredGlucose.self)
        try context.delete(model: StoredTreatment.self); try context.delete(model: StoredProfile.self)
        try context.save()
    }
    func exportResearch() throws -> Data {
        struct Export: Encodable {
            var schema: String
            var glucose: [GlucoseSample]
            var treatments: [Treatment]
            var contexts: [LifestyleContext]
            var forecasts: [Evaluation]
        }
        struct Evaluation: Encodable {
            var forecast: Forecast
            var actual30: Double?; var actual60: Double?; var error30: Double?; var error60: Double?
        }
        let rows = try forecasts().map { record in
            Evaluation(forecast: try JSONDecoder().decode(Forecast.self, from: record.payload),
                       actual30: record.actual30, actual60: record.actual60, error30: record.error30, error60: record.error60)
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Export(schema: FeatureRow.schema, glucose: glucose(), treatments: treatments(), contexts: contexts(), forecasts: rows))
    }
}
