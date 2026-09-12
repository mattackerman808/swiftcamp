import Foundation

/// What can be learned about a GPX file from its two ends.
///
/// A recorded track log is mostly middle: hundreds of thousands of points
/// that all look alike. The two things a rider wants from a file called
/// `18.gpx` — when it starts and when it stops — are in the first and last
/// few kilobytes, so reading those two pieces answers the question for a
/// thousandth of the bytes.
///
/// Deliberately not XML parsing. Both pieces are fragments: the head has no
/// closing tags and the tail begins in the middle of an element, so a parser
/// rejects them both. This scans text instead, which is the right tool for a
/// fragment and the wrong one for a document.
enum GPXPeek {
    /// How much of each end is enough.
    ///
    /// The head has to clear the XML declaration, the `gpx` element with its
    /// namespace declarations, and a `metadata` block, which Garmin writes
    /// generously. The tail only has to reach back past the last `trkpt`.
    static let headBytes: UInt32 = 16 * 1024
    static let tailBytes: UInt32 = 8 * 1024

    struct Result: Equatable, Sendable {
        var start: Date?
        var end: Date?
        /// True when the head showed the file is a track log rather than a
        /// route or a waypoint list. Read from a fragment, so it says what
        /// was seen and never that something is absent.
        var sawTrack = false
        var sawRoute = false
        var sawWaypoint = false

        var isEmpty: Bool { start == nil && end == nil && !sawTrack && !sawRoute && !sawWaypoint }
    }

    /// Reads the timestamps and the shape of the file from its two ends.
    static func scan(head: Data, tail: Data) -> Result {
        let headText = text(head)
        let tailText = text(tail)

        var result = Result()
        result.sawTrack = headText.contains("<trk>") || headText.contains("<trk ")
        result.sawRoute = headText.contains("<rte>") || headText.contains("<rte ")
        result.sawWaypoint = headText.contains("<wpt ")

        result.start = startTime(in: headText)
        result.end = lastTime(in: tailText) ?? result.start

        // Never let a range read backwards. The two ends come from different
        // reads and, on a file whose metadata is stamped later than its
        // contents, the "start" can legitimately be the later of the two —
        // which a reader sees as "Sep 12–7" and reasonably calls a bug.
        if let start = result.start, let end = result.end, start > end {
            result.start = end
            result.end = start
        }
        return result
    }

    // MARK: - Scanning

    /// Bytes to text, tolerating a fragment.
    ///
    /// A tail almost always begins part-way through a UTF-8 sequence, so a
    /// strict decode returns nil for the whole thing. Replacing the broken
    /// bytes costs one mangled character at the very start and keeps the
    /// several thousand that follow.
    private static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    /// When the recording began, which is not the same as the first
    /// timestamp in the file.
    ///
    /// A Garmin stamps `<metadata><time>` with when the file was written,
    /// not when the ride happened — on an active log that is today, while
    /// the riding was last week. Taking the first timestamp blindly reported
    /// a track log as starting after it ended. The first timestamp *inside a
    /// point* is the one that means something.
    private static func startTime(in text: String) -> Date? {
        guard let firstPoint = pointStart(in: text) else { return times(in: text).first }
        let afterPoint = times(in: String(text[firstPoint...])).first
        return afterPoint ?? times(in: text).first
    }

    /// Where the first `trkpt`, `rtept` or `wpt` begins.
    private static func pointStart(in text: String) -> String.Index? {
        ["<trkpt", "<rtept", "<wpt"]
            .compactMap { text.range(of: $0)?.lowerBound }
            .min()
    }

    private static func lastTime(in text: String) -> Date? {
        times(in: text).last
    }

    /// Every `<time>…</time>` in the fragment, in order.
    private static func times(in text: String) -> [Date] {
        var found: [Date] = []
        var cursor = text.startIndex

        while let open = text.range(of: "<time>", range: cursor..<text.endIndex),
              let close = text.range(of: "</time>", range: open.upperBound..<text.endIndex) {
            if let date = GPXDate.parse(String(text[open.upperBound..<close.lowerBound])) {
                found.append(date)
            }
            cursor = close.upperBound
        }
        return found
    }
}
