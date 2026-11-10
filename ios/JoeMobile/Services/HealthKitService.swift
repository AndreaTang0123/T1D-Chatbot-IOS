import Foundation
import HealthKit
import JoeCore

@MainActor final class HealthKitService {
    private let store = HKHealthStore()
    private var observers: [HKObserverQuery] = []
    var onChange: (() -> Void)?
    var enabled: Bool { UserDefaults.standard.bool(forKey: "healthEnabled") }
    private var types: Set<HKObjectType> {
        [HKQuantityType.quantityType(forIdentifier: .stepCount)!, HKQuantityType.quantityType(forIdentifier: .heartRate)!,
         HKQuantityType.quantityType(forIdentifier: .bloodGlucose)!, HKObjectType.workoutType(), HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!]
    }
    func authorize() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try await store.requestAuthorization(toShare: [], read: types)
        // Request success does not establish read authorization; empty queries remain missing.
        UserDefaults.standard.set(true, forKey: "healthEnabled")
        observe()
    }
    func disable() {
        UserDefaults.standard.set(false, forKey: "healthEnabled")
        observers.forEach(store.stop); observers.removeAll()
        store.disableAllBackgroundDelivery { _, _ in }
    }
    func observe() {
        guard enabled, HKHealthStore.isHealthDataAvailable(), observers.isEmpty else { return }
        for type in types.compactMap({ $0 as? HKSampleType }) {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, _ in
                Task { @MainActor in self?.onChange?(); completion() }
            }
            observers.append(query); store.execute(query)
            store.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
        }
    }
    func snapshot(at time: Date) async -> LifestyleContext {
        var result = LifestyleContext(timestamp: time)
        guard enabled, HKHealthStore.isHealthDataAvailable() else { return result }
        let stepsType = HKQuantityType.quantityType(forIdentifier: .stepCount)!
        let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!
        let steps = await samples(type: stepsType, from: time.addingTimeInterval(-1800), to: time)
        // Statistics query combines overlapping sources (iPhone + Watch) using HealthKit's source merging.
        if !steps.isEmpty { result.steps = await stepTotal(type: stepsType, from: time.addingTimeInterval(-1800), to: time) }
        if let hr = await samples(type: hrType, from: time.addingTimeInterval(-900), to: time).last as? HKQuantitySample {
            result.heartRate = hr.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        }
        let workouts = await samples(type: HKQuantityType.quantityType(forIdentifier: .bloodGlucose)!, HKObjectType.workoutType(), from: time.addingTimeInterval(-7200), to: time)
        // Historical completed workouts cannot establish that no workout was active.
        if !workouts.isEmpty { result.workoutActive = workouts.contains { $0.startDate <= time && $0.endDate >= time.addingTimeInterval(-300) } }
        let sleep = await samples(type: sleepType, from: time.addingTimeInterval(-36*3600), to: time)
        let intervals = sleep.compactMap { $0 as? HKCategorySample }.filter {
            [HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue, HKCategoryValueSleepAnalysis.asleepCore.rawValue,
             HKCategoryValueSleepAnalysis.asleepDeep.rawValue, HKCategoryValueSleepAnalysis.asleepREM.rawValue].contains($0.value)
        }.sorted { $0.startDate < $1.startDate }
        // Merge overlapping Watch/phone sleep samples, then retain the latest sleep episode (gap <= 3h).
        var merged: [(Date, Date)] = []
        for sample in intervals {
            if let last = merged.last, sample.startDate <= last.1 {
                merged[merged.count-1].1 = max(last.1, sample.endDate)
            } else { merged.append((sample.startDate, sample.endDate)) }
        }
        if let last = merged.last {
            var start = last.0; var seconds = last.1.timeIntervalSince(last.0)
            for interval in merged.dropLast().reversed() {
                guard start.timeIntervalSince(interval.1) <= 3*3600 else { break }
                seconds += interval.1.timeIntervalSince(interval.0); start = interval.0
            }
            result.sleepHours = seconds/3600
        }
        return result
    }
    func glucoseHistory(at now: Date) async throws -> [GlucoseSample] {
        guard enabled, HKHealthStore.isHealthDataAvailable() else { return [] }
        let type = HKQuantityType.quantityType(forIdentifier: .bloodGlucose)!
        return try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: now.addingTimeInterval(-30*86400), end: now, options: [.strictStartDate, .strictEndDate])
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, rows, error in
                if let error { continuation.resume(throwing: error); return }
                let samples = (rows ?? []).compactMap { $0 as? HKQuantitySample }.map {
                    GlucoseSample(id: "healthkit:" + $0.uuid.uuidString, timestamp: $0.startDate,
                                  glucose: $0.quantity.doubleValue(for: HKUnit(from: "mg/dL")),
                                  receivedAt: now, sourceName: $0.sourceRevision.source.name)
                }
                continuation.resume(returning: samples)
            }
            store.execute(query)
        }
    }
    private func stepTotal(type: HKQuantityType, from: Date, to: Date) async -> Double? {
        await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type,
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: from, end: to, options: [.strictStartDate, .strictEndDate]),
                options: .cumulativeSum) { _, stats, _ in
                    continuation.resume(returning: stats?.sumQuantity()?.doubleValue(for: .count()))
                }
            store.execute(query)
        }
    }
    private func samples(type: HKSampleType, from: Date, to: Date) async -> [HKSample] {
        await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: [.strictStartDate, .strictEndDate])
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)]) { _, rows, _ in
                continuation.resume(returning: rows ?? [])
            }
            store.execute(query)
        }
    }
}
