import Foundation

/// Stage timings on the console, behind `-SwiftcampTiming YES`.
///
/// A route passes through the engine, a reply decode, a store write, an
/// overlay encode, the bridge, the page's parse and `setData`, and a
/// render, and "routing is slow" names none of them. Each stage logs one
/// line with the same prefix, so the console can be filtered to the
/// breakdown and the biggest number read off. The macOS scheme passes the
/// flag; a shipping copy never logs any of it.
enum Timing {
    static let enabled = UserDefaults.standard.bool(forKey: "SwiftcampTiming")

    static func log(_ stage: String, since start: ContinuousClock.Instant, _ detail: String = "") {
        guard enabled else { return }
        NSLog("[Swiftcamp/timing] %@ %.0f ms %@", stage, milliseconds(since: start), detail)
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = (ContinuousClock.now - start).components
        return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    }
}
