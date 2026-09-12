#if os(macOS)
import Foundation

/// Turning what a file holds into the line under its name.
///
/// Separate from any view because both panes need it and because the rule it
/// encodes is a judgement, not formatting: say only what is actually known.
enum DeviceSummaryText {
    /// Reading the two ends shows *that* a file holds tracks, never how many.
    /// Saying "1 track" on that evidence would be a guess dressed as a fact,
    /// so the shallow answer names the kind and leaves counting to the read
    /// that can count.
    static func contents(_ identification: DeviceService.Identification) -> [String] {
        let summary = identification.summary
        var parts: [String] = []

        switch identification.depth {
        case .ends:
            if summary.tracks > 0 { parts.append("track log") }
            if summary.routes > 0 { parts.append("routes") }
            if summary.waypoints > 0 { parts.append("waypoints") }
        case .whole:
            if summary.tracks > 0 { parts.append(count(summary.tracks, "track")) }
            if summary.routes > 0 { parts.append(count(summary.routes, "route")) }
            if summary.waypoints > 0 { parts.append(count(summary.waypoints, "waypoint")) }
        }

        if parts.isEmpty { parts.append("empty") }
        return parts
    }

    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    /// A span, or one date when it is all one day.
    static func dateSpan(_ summary: GPXSummary) -> String? {
        guard let start = summary.start else { return nil }
        guard let end = summary.end,
              !Calendar.current.isDate(start, inSameDayAs: end) else {
            return day(start)
        }
        return rangeFormatter.string(from: start, to: end)
    }

    static func distance(_ metres: Double) -> String {
        String(format: "%.0f mi", metres / 1609.344)
    }

    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    private static let rangeFormatter: DateIntervalFormatter = {
        let f = DateIntervalFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}
#endif
