import Foundation

/// Road routing, on device, through Valhalla.
///
/// Stage D of `docs/basecamp-parity.md`. Valhalla needs its graph on local
/// disk, which is why this is a library in the process and not a request
/// to a server: BaseCamp-style planning re-routes on every drag, and a
/// network round trip in the middle of a gesture was rejected in
/// `docs/data-architecture.md`.
///
/// One instance per process. Valhalla's actor is not thread-safe and holds
/// a tile cache worth keeping warm, so requests are serialised here rather
/// than by giving every caller its own engine.
final class RoutingEngine: @unchecked Sendable {
    /// The engine, if a graph was configured, else nil and legs stay
    /// straight. `-SwiftcampRouting <valhalla.json>` names the config for
    /// now; the region-pack manifest will, once packs download.
    static let shared: RoutingEngine? = {
        guard let path = UserDefaults.standard.string(forKey: "SwiftcampRouting") else { return nil }
        do {
            // The Xcode scheme passes `~/valhalla-data/...`, and launch
            // arguments arrive verbatim: there is no shell between Xcode and
            // the process to expand a tilde.
            return try RoutingEngine(configURL: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        } catch {
            NSLog("[Swiftcamp] routing engine unavailable: %@", error.localizedDescription)
            return nil
        }
    }()

    private let engine: OpaquePointer
    private let lock = NSLock()

    /// Valhalla's costing model. Motorcycle rather than auto: it is the
    /// product's use case, and it differs in what it avoids and prefers.
    var costing = "motorcycle"

    init(configURL: URL) throws {
        let config = try String(contentsOf: configURL, encoding: .utf8)
        var error: UnsafeMutablePointer<CChar>?
        guard let engine = valhalla_engine_open(config, &error) else {
            throw RoutingError(message: Self.take(error) ?? "could not open the routing engine")
        }
        self.engine = engine
    }

    deinit { valhalla_engine_close(engine) }

    /// The road between two points, as the full polyline including both
    /// snapped ends. Throws when Valhalla finds no path, which is the
    /// caller's cue to fall back to a straight leg and say so.
    func route(from a: Coordinate, to b: Coordinate) throws -> [Coordinate] {
        let request: [String: Any] = [
            "locations": [["lat": a.lat, "lon": a.lon], ["lat": b.lat, "lon": b.lon]],
            "costing": costing,
            // No turn-by-turn narrative: the caller wants the shape only,
            // and generating maneuvers is a measurable share of the time.
            "directions_type": "none",
            "units": "miles",
        ]
        let body = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)

        var error: UnsafeMutablePointer<CChar>?
        let started = ContinuousClock.now
        defer {
            // Left in on purpose: the drag-end cost is what decides whether
            // routing can stay synchronous, and it changes with the graph.
            NSLog("[Swiftcamp] route %.0f ms", Double((ContinuousClock.now - started).components.attoseconds) / 1e15)
        }
        let reply: String? = lock.withLock {
            guard let out = valhalla_engine_route(engine, body, &error) else { return nil }
            defer { valhalla_free(out) }
            return String(cString: out)
        }
        guard let reply else {
            throw RoutingError(message: Self.take(error) ?? "no route")
        }

        guard let json = try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any],
              let trip = json["trip"] as? [String: Any],
              let legs = trip["legs"] as? [[String: Any]],
              let shape = legs.first?["shape"] as? String
        else { throw RoutingError(message: "unexpected reply from the routing engine") }

        return Polyline.decode(shape)
    }

    /// The engine as a `LegShaper`: the road's interior points, or a
    /// straight leg when there is no road, so an edit never fails outright.
    var legShaper: RouteEditing.LegShaper {
        { [self] a, b in
            guard let path = try? route(from: a, to: b), path.count > 2 else { return [] }
            return Array(path.dropFirst().dropLast())
        }
    }

    /// Takes ownership of a C error string.
    private static func take(_ error: UnsafeMutablePointer<CChar>?) -> String? {
        guard let error else { return nil }
        defer { valhalla_free(error) }
        return String(cString: error)
    }
}

struct RoutingError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
