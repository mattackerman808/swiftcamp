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

        // The first timestamp is usually the metadata time, which for a
        // Garmin log is when the recording began. Falling back to the first
        // point's time covers files with no metadata block.
        result.start = firstTime(in: headText)
        result.end = lastTime(in: tailText) ?? result.start
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

    private static func firstTime(in text: String) -> Date? {
        times(in: text).first
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
