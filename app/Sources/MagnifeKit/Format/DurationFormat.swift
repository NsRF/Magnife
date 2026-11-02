import Foundation

/// Durations as the glossary writes them: "850 µs", "4.6 ms", "12 ms", "1.24 s",
/// "12.4 s", "2 min 5 s", "1 h 2 min". Below 1 ms it counts whole microseconds;
/// each step rounds first, so 999.6 ms reads "1.00 s", never "1000 ms".
public enum DurationFormat {
    public static func string(nanoseconds: Int64) -> String {
        let ns = Double(max(0, nanoseconds))
        let micros = (ns / 1_000).rounded()
        if micros < 1_000 { return "\(Int(micros)) µs" }
        let millis = ns / 1_000_000
        if (millis * 10).rounded() < 100 { return String(format: "%.1f ms", millis) }
        if millis.rounded() < 1_000 { return "\(Int(millis.rounded())) ms" }
        let seconds = ns / 1_000_000_000
        if (seconds * 100).rounded() < 1_000 { return String(format: "%.2f s", seconds) }
        if (seconds * 10).rounded() < 600 { return String(format: "%.1f s", seconds) }
        let wholeSeconds = Int(seconds.rounded())
        if wholeSeconds < 3_600 {
            let (minutes, rest) = wholeSeconds.quotientAndRemainder(dividingBy: 60)
            return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
        }
        let wholeMinutes = Int((seconds / 60).rounded())
        let (hours, rest) = wholeMinutes.quotientAndRemainder(dividingBy: 60)
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// The same duration in words for VoiceOver: "240 milliseconds",
    /// "1.24 seconds", "850 microseconds", "2 minutes 5 seconds", "1 hour".
    public static func spoken(nanoseconds: Int64) -> String {
        let words = ["µs": ("microsecond", "microseconds"), "ms": ("millisecond", "milliseconds"),
                     "s": ("second", "seconds"), "min": ("minute", "minutes"), "h": ("hour", "hours")]
        let parts = string(nanoseconds: nanoseconds).split(separator: " ").map(String.init)
        var spoken: [String] = []
        for index in stride(from: 0, to: parts.count - 1, by: 2) {
            let number = parts[index]
            guard let unit = words[parts[index + 1]] else { return parts.joined(separator: " ") }
            spoken.append("\(number) \(number == "1" ? unit.0 : unit.1)")
        }
        return spoken.joined(separator: " ")
    }
}
