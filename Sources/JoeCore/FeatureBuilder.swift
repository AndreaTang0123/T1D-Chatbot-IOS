import Foundation

public enum FeatureBuilder {
    public static func build(samples: [GlucoseSample], treatments: [Treatment], context: LifestyleContext?,
                             at now: Date, staleAfter: TimeInterval = SafetyPolicy().cgmStaleSeconds) throws -> FeatureRow {
        let valid = samples.filter { $0.timestamp <= now && $0.glucose.isFinite && (40...400).contains($0.glucose) }
            .sorted { $0.timestamp < $1.timestamp }
        guard let latest = valid.last else { throw DataIssue.noGlucose }
        guard latest.isFresh(at: now, threshold: staleAfter) else { throw DataIssue.staleGlucose }
        let t = latest.timestamp
        // Strictly causal grid, with at most 2.5 minutes of carry-forward.
        let grid: [Double] = try (0...6).map { offset in
            let target = t.addingTimeInterval(Double(offset - 6) * 300)
            guard let value = valid.last(where: { $0.timestamp <= target && target.timeIntervalSince($0.timestamp) <= 150 })
            else { throw DataIssue.insufficientHistory }
            return value.glucose
        }
        let mean = grid.reduce(0,+) / 7
        let std = sqrt(grid.map { pow($0 - mean, 2) }.reduce(0,+) / 7)
        var values: [Double] = [grid[6], grid[6]-grid[5], (grid[6]-grid[3])/15, mean, std]
        // No treatment feed coverage guarantee: absence of events is unknown, not zero delivery.
        // IOB/COB intentionally missing until a validated action/absorption model is available.
        let events = treatments.filter { $0.timestamp <= t }.sorted { $0.timestamp < $1.timestamp }
        let basal = events.last(where: { $0.kind.lowercased() == "temp basal" && $0.rate != nil &&
            ($0.duration ?? 0) > t.timeIntervalSince($0.timestamp)/60 })?.rate
        let boluses = events.filter { t.timeIntervalSince($0.timestamp) <= 1800 }.compactMap(\.insulin)
        let carbs = events.filter { t.timeIntervalSince($0.timestamp) <= 7200 }.compactMap(\.carbs)
        var optional: [Double?] = [basal, boluses.isEmpty ? nil : boluses.reduce(0,+), nil,
                                  carbs.isEmpty ? nil : carbs.reduce(0,+), nil]
        let c = context.flatMap { $0.timestamp <= t && t.timeIntervalSince($0.timestamp) <= 900 ? $0 : nil }
        let places = ["unknown", "home", "school", "work", "gym", "restaurant", "other"]
        let categories = ["other", "class", "meeting", "meal", "travel", "medical", "exercise"]
        optional += [c?.steps, c?.heartRate, c?.workoutActive.map { $0 ? 1 : 0 }, c?.sleepHours,
                     c?.place.flatMap { places.firstIndex(of: $0).map(Double.init) },
                     c?.calendar.flatMap { categories.firstIndex(of: $0).map(Double.init) }]
        var missing: [String] = []
        for (i, value) in optional.enumerated() {
            if let value, value.isFinite { values.append(value) }
            else { values.append(0); missing.append(FeatureRow.names[i+5]) }
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let seconds = Double(calendar.component(.hour, from: t)*3600 + calendar.component(.minute, from: t)*60 + calendar.component(.second, from: t))
        let phase = seconds / 86400 * 2 * Double.pi
        values += [sin(phase), cos(phase), Double((calendar.component(.weekday, from: t)+5)%7)]
        return FeatureRow(timestamp: Date(timeIntervalSince1970: floor(t.timeIntervalSince1970/300)*300),
                          sourceTimestamp: t, values: values, missing: missing)
    }
}

public enum ContextClassifier {
    public static func calendarCategory(_ title: String) -> String {
        let text = title.lowercased()
        let rules = [("medical", ["doctor", "clinic", "physician", "hospital"]), ("exercise", ["gym", "run", "workout", "exercise", "fitness"]),
                     ("meal", ["lunch", "dinner", "breakfast", "meal", "supper"]), ("travel", ["flight", "train", "travel", "trip"]),
                     ("class", ["class", "lecture", "seminar"]), ("meeting", ["meeting", "sync", "conference"])]
        return rules.first { $0.1.contains(where: text.contains) }?.0 ?? "other"
    }
}
