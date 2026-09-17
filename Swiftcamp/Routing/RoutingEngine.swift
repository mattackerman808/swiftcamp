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

    /// Valhalla's costing options for a mode. Motorcycle either way, since
    /// that is the product; the modes differ in which ways they will take.
    ///
    /// `exclude_unpaved` refuses to turn onto unpaved from paved, so a road
    /// route that starts on gravel can still get out, and tracks and trails
    /// are off entirely. Adventure opens all three: any way the map knows
    /// is a way a dual-sport can ride.
    private static func costingOptions(for mode: RoutingMode) -> [String: Any] {
        switch mode {
        case .road: ["exclude_unpaved": true, "use_tracks": 0, "use_trails": 0]
        case .adventure: ["exclude_unpaved": false, "use_tracks": 1, "use_trails": 1]
        case .direct: [:]   // never routed; here so the switch is total
        }
    }

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
    func route(from a: Coordinate, to b: Coordinate, mode: RoutingMode = .road) throws -> [Coordinate] {
        let request: [String: Any] = [
            "locations": [["lat": a.lat, "lon": a.lon], ["lat": b.lat, "lon": b.lon]],
            "costing": "motorcycle",
            "costing_options": ["motorcycle": Self.costingOptions(for: mode)],
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

    /// The engine as a `LegShaper` for a mode: the routed path with both
    /// landings, or a straight leg when there is no road, so an edit never
    /// fails outright.
    func legShaper(for mode: RoutingMode) -> RouteEditing.LegShaper {
        { [self] a, b in
            do {
                let path = try route(from: a, to: b, mode: mode)
                return path.count >= 2 ? path : []
            } catch {
                // Said, not swallowed. A straight leg that should have been
                // a road is the failure a user sees, and the reason is
                // only ever here: no path, a tile that would not download,
                // a graph that would not open.
                NSLog("[Swiftcamp] leg fell back to a straight line: %@", error.localizedDescription)
                return []
            }
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
