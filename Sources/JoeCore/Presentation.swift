import Foundation

/// Nightscout trend labels mapped without estimating a trend from missing data.
public enum GlucoseTrend: String, Sendable {
    case doubleUp, singleUp, fortyFiveUp, flat, fortyFiveDown, singleDown, doubleDown, unknown
    public init(direction: String?) {
        switch direction?.lowercased() {
        case "doubleup": self = .doubleUp
        case "singleup": self = .singleUp
        case "fortyfiveup": self = .fortyFiveUp
        case "flat": self = .flat
        case "fortyfivedown": self = .fortyFiveDown
        case "singledown": self = .singleDown
        case "doubledown": self = .doubleDown
        default: self = .unknown
        }
    }
    public var arrow: String {
        switch self {
        case .doubleUp: "↑↑"
        case .singleUp: "↑"
        case .fortyFiveUp: "↗"
        case .flat: "→"
        case .fortyFiveDown: "↘"
        case .singleDown: "↓"
        case .doubleDown: "↓↓"
        case .unknown: "—"
        }
    }
    public var label: String {
        switch self {
        case .doubleUp: "Rising rapidly"
        case .singleUp: "Rising"
        case .fortyFiveUp: "Rising slowly"
        case .flat: "Steady"
        case .fortyFiveDown: "Falling slowly"
        case .singleDown: "Falling"
        case .doubleDown: "Falling rapidly"
        case .unknown: "Trend unavailable"
        }
    }
}

public extension Treatment {
    var isBolus: Bool {
        let type = kind.lowercased()
        return type.contains("bolus") && !type.contains("basal") && (insulin ?? 0) > 0
    }
    static func latestBolus(in events: [Treatment], at now: Date) -> Treatment? {
        events.filter { $0.isBolus && $0.timestamp <= now }.max { $0.timestamp < $1.timestamp }
    }
}
