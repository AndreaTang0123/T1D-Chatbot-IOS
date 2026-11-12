import Foundation

/// Render on the device, not in the LLM. UTC offset disambiguates repeated local times at DST rollover.
public enum LocalEventTime {
    public static func string(_ date: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone; formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let offset = zone.secondsFromGMT(for: date)
        let sign = offset < 0 ? "-" : "+"
        let value = abs(offset)
        let suffix = String(format: "%@%02d:%02d", sign, value / 3600, value % 3600 / 60)
        return "\(formatter.string(from: date)) (\(zone.identifier), UTC\(suffix))"
    }
}
