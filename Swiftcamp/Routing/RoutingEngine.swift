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
    /// The engine on the graph the CDN publishes, or on a developer's own
    /// graph when `-SwiftcampRouting <valhalla.json>` names one. Nil, and
    /// legs stay straight, only if neither can be opened.
    ///
    /// Opening the streamed graph fetches the tar's index, one network
    /// round trip, so `warm()` touches this off the main actor at launch
    /// rather than letting the first drag pay for it.
    static let shared: RoutingEngine? = {
        do {
            if let path = UserDefaults.standard.string(forKey: "SwiftcampRouting") {
                // The Xcode scheme passes `~/valhalla-data/...`, and launch
                // arguments arrive verbatim: there is no shell between Xcode
                // and the process to expand a tilde.
                return try RoutingEngine(configURL: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            }
            return try RoutingEngine(streaming: BasemapSource.routingURL)
        } catch {
            NSLog("[Swiftcamp] routing engine unavailable: %@", error.localizedDescription)
            return nil
        }
    }()

    /// Starts opening the engine away from the main actor. A `static let`
    /// initialises once whoever touches it first, and blocks anyone else
    /// until it is done, so this costs a launch nothing and saves the first
    /// edit a stall.
    static func warm() {
        Task.detached(priority: .utility) { _ = RoutingEngine.shared }
    }

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

    /// Opens Valhalla on a configuration document.
    init(configJSON: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard let engine = valhalla_engine_open(configJSON, &error) else {
            throw RoutingError(message: Self.take(error) ?? "could not open the routing engine")
        }
        self.engine = engine
    }

    /// A developer's own graph on local disk, from its config file.
    convenience init(configURL: URL) throws {
        guard var config = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        else { throw RoutingError(message: "the routing config is not a JSON object") }
        Self.raiseLimits(&config)
        try self.init(configJSON: String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self))
    }

    /// Lifts a limit the config generator sets for a public server.
    ///
    /// It caps a motorcycle route at 500 km, a tenth of what it allows a
    /// car, and a leg from California to Colorado is three times that. The
    /// engine refuses the leg with "exceeds the max distance limit" and the
    /// planner draws it straight, which looks exactly like routing being
    /// off. A planner is not a public server: one user, one route at a
    /// time, and a leg the length of the country is a ride someone means
    /// to take. Matched to the car limit, 5,000 km.
    private static func raiseLimits(_ config: inout [String: Any]) {
        var limits = config["service_limits"] as? [String: Any] ?? [:]
        var motorcycle = limits["motorcycle"] as? [String: Any] ?? [:]
        motorcycle["max_distance"] = 5_000_000.0
        limits["motorcycle"] = motorcycle
        config["service_limits"] = limits
    }

    /// The graph published at `url`, a tar Valhalla reads by byte range:
    /// the index once, then each tile as a route first needs it, cached
    /// on disk after that. The same shape as the map's PMTiles, and with
    /// the same consequence: no download, no region picker, and the first
    /// route into a fresh area pays for its tiles.
    ///
    /// The config is the bundled template with the tar and the cache
    /// filled in. Valhalla wants the whole document, sections it will
    /// never use included, and `valhalla_build_config` is the only thing
    /// that knows the current shape of it, so the template is its output
    /// rather than a hand-written subset that rots.
    ///
    /// The cache lives under Caches, keyed by the archive's name: macOS
    /// may reclaim it, and a new graph gets a fresh folder rather than a
    /// refusal from Valhalla, which records the tar's build id beside the
    /// tiles it cached and will not mix two builds.
    convenience init(streaming url: String) throws {
        guard let templateURL = Bundle.main.url(forResource: "valhalla", withExtension: "json", subdirectory: "routing"),
              var config = try JSONSerialization.jsonObject(with: Data(contentsOf: templateURL)) as? [String: Any],
              var mjolnir = config["mjolnir"] as? [String: Any]
        else { throw RoutingError(message: "the routing config template is missing from the bundle") }

        let archive = (url as NSString).lastPathComponent
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Swiftcamp/routing/\(archive)", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        mjolnir["tile_url"] = url
        mjolnir["tile_dir"] = cache.path
        config["mjolnir"] = mjolnir

        // Loki's connectivity map colours the graph by the tiles it can
        // enumerate, which is the cache on disk and not the tar's index,
        // so with a fresh cache every pair of locations is "in unconnected
        // regions" and no route is ever attempted. The check exists to
        // refuse impossible requests cheaply; a streamed graph cannot know
        // what is impossible until it has fetched the tiles, so the search
        // itself has to be the judge.
        var loki = config["loki"] as? [String: Any] ?? [:]
        loki["use_connectivity"] = false
        config["loki"] = loki
        Self.raiseLimits(&config)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        try self.init(configJSON: json)
        NSLog("[Swiftcamp] routing graph %@, cache %@", url, cache.path)
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
