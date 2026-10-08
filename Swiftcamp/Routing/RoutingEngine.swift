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

    /// Valhalla's costing options for a mode and a route's preferences.
    /// Motorcycle either way, since that is the product; the modes differ
    /// in which ways they will take.
    ///
    /// `exclude_unpaved` refuses to turn onto unpaved from paved, so a road
    /// route that starts on gravel can still get out, and tracks and trails
    /// are off entirely. Adventure opens all three: any way the map knows
    /// is a way a dual-sport can ride.
    ///
    /// An avoidance is the option at zero, which Valhalla treats as a heavy
    /// penalty rather than a ban: a route that can only reach its end by
    /// the toll road still gets there. `use_curvature` is ours, from
    /// `scripts/valhalla-curvature.patch`; an unpatched engine warns and
    /// ignores it.
    ///
    /// Driving is the car costing with the road mode's surfaces. Walking is
    /// the pedestrian costing up to `max_hiking_difficulty` 3, demanding
    /// mountain hiking on the SAC scale; its default of 1 refuses most
    /// trails above treeline, which is where a walk in Colorado goes.
    static func costingOptions(for mode: RoutingMode, preferences: RoutePreferences) -> [String: Any] {
        var options: [String: Any]
        switch mode {
        case .road, .driving: options = ["exclude_unpaved": true, "use_tracks": 0]
        case .adventure: options = ["exclude_unpaved": false, "use_tracks": 1, "use_trails": 1]
        case .walking: options = ["max_hiking_difficulty": 3]
        case .direct: return [:]   // never routed; here so the switch is total
        }
        if mode == .road { options["use_trails"] = 0 }
        let avoidable = Set(mode.avoidances.map(\.path))
        if preferences.avoidHighways, avoidable.contains(\.avoidHighways) { options["use_highways"] = 0 }
        if preferences.avoidTolls, avoidable.contains(\.avoidTolls) { options["use_tolls"] = 0 }
        if preferences.avoidFerries, avoidable.contains(\.avoidFerries) { options["use_ferry"] = 0 }
        switch preferences.prefer {
        case .fasterTime: break
        case .shorterDistance: options["shortest"] = true
        case .someCurves, .manyCurves:
            if mode.preferences.contains(preferences.prefer) { options["use_curvature"] = preferences.prefer.curvature }
        }
        return options
    }

    /// Valhalla's costing model for a mode.
    static func costing(for mode: RoutingMode) -> String {
        switch mode {
        case .road, .adventure, .direct: "motorcycle"
        case .driving: "auto"
        case .walking: "pedestrian"
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

    /// Where the streamed graph's tiles are cached, keyed by the graph's
    /// name so a new graph gets a fresh folder. Under Caches, so macOS may
    /// reclaim it; the prefetcher fills it again.
    static func cacheDirectory(for archive: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Swiftcamp/routing/\(archive)", isDirectory: true)
    }

    /// How a route's legs get their shape and where its points land, from
    /// its mode: nil when no engine could be opened, so legs stay straight.
    /// Direct is straight by choice. Touches `shared`, so call it off the
    /// main actor: the first call opens the engine.
    static func shaping(for route: Route) -> (snap: RouteEditing.Snap, shape: RouteEditing.LegShaper)? {
        guard route.mode != .direct, let engine = shared else { return nil }
        let shaper = engine.legShaper(for: route.mode, preferences: route.preferences)
        switch route.mode {
        case .road, .driving: return (.always, shaper)
        case .adventure, .walking: return (.within(adventureSnap), shaper)
        case .direct: return nil
        }
    }

    /// How close a drop must be to a way, in metres, to land on it in
    /// Adventure. A near miss lands on the track; a deliberate point in the
    /// scrub stays put, with a straight leg to the nearest way.
    static let adventureSnap = 50.0

    /// The shaping for a drag preview: as `shaping(for:)`, but a leg longer
    /// than `previewLimit` previews straight and is routed on release. See
    /// `RouteEditing.straightBeyond`.
    static func previewShaping(for route: Route) -> (snap: RouteEditing.Snap, shape: RouteEditing.LegShaper)? {
        guard let shaping = shaping(for: route) else { return nil }
        return (shaping.snap, RouteEditing.straightBeyond(previewLimit, shaping.shape))
    }

    /// Measured: a warm 1,900 km search is half a second, a 150 km one
    /// tens of milliseconds, and a drag needs the second.
    static let previewLimit = 150_000.0

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

    /// The graph published under `url`, one gzipped object per tile that
    /// Valhalla fetches as a route first needs it and caches on disk
    /// gzipped. The same shape as the map's PMTiles, and with the same
    /// consequence: no download, no region picker, and the first route
    /// into a fresh area pays for its tiles, unless `RoutingPrefetch` got
    /// there first.
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

        let cache = Self.cacheDirectory(for: (url as NSString).lastPathComponent)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        // `{tilePath}` becomes the tile's path with its `.gph` suffix, and
        // the pattern's own `.gz` follows it. With `tile_url_gz` the getter
        // keeps the bytes as served and writes them gzipped beside any the
        // prefetcher wrote, which names them the same way.
        mjolnir["tile_url"] = url + "/{tilePath}.gz"
        mjolnir["tile_url_gz"] = true
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
    func route(from a: Coordinate, to b: Coordinate, mode: RoutingMode = .road,
               preferences: RoutePreferences = RoutePreferences()) throws -> [Coordinate] {
        // No turn-by-turn narrative: the caller wants the shape only, and
        // generating maneuvers is a measurable share of the time.
        let json = try ask(Self.request(locations: [["lat": a.lat, "lon": a.lon], ["lat": b.lat, "lon": b.lon]],
                                        mode: mode, preferences: preferences, directions: false),
                           what: "route")

        let decoding = ContinuousClock.now
        guard let trip = json["trip"] as? [String: Any],
              let legs = trip["legs"] as? [[String: Any]],
              let shape = legs.first?["shape"] as? String
        else { throw RoutingError(message: "unexpected reply from the routing engine") }

        let path = Polyline.decode(shape)
        Timing.log("route.decode", since: decoding, "\(path.count) points")
        return path
    }

    /// The turns along a whole route, narrated: one request with every
    /// point as a location, via points as stops and shaping points passed
    /// through, under the route's own mode and preferences.
    ///
    /// A fresh search rather than a narration of the stored legs. Valhalla
    /// can narrate a given shape only by map-matching it back onto the
    /// graph, which is a guess with thousands of points and a certainty
    /// with none; a search under the same settings finds the same road,
    /// and the whole route warm is under a second. Shaping points are
    /// `via`, which allows a reversal there as the leg-by-leg routing did,
    /// so the narrative follows the line on the map rather than refusing
    /// a turn the line takes. Throws for a Direct route, which has no
    /// road to narrate, or for fewer than two points.
    func directions(for detail: RouteDetail) throws -> RouteDirections {
        let points = detail.points.sorted { $0.seq < $1.seq }
        guard detail.route.mode != .direct else { throw RoutingError(message: "a direct route has no turns") }
        guard points.count >= 2 else { throw RoutingError(message: "a route needs two points") }
        let locations = points.enumerated().map { index, point -> [String: Any] in
            let stop = point.isVia || index == 0 || index == points.count - 1
            var location: [String: Any] = ["lat": point.lat, "lon": point.lon, "type": stop ? "break" : "via"]
            // Named, so the arrival reads "You have arrived at Camp".
            if stop, let name = point.name { location["name"] = name }
            return location
        }
        let json = try ask(Self.request(locations: locations, mode: detail.route.mode,
                                        preferences: detail.route.preferences, directions: true),
                           what: "directions")
        return try RouteDirections.parse(json)
    }

    /// Valhalla's route request for a set of locations under a mode and
    /// preferences, with or without the narrative.
    private static func request(locations: [[String: Any]], mode: RoutingMode, preferences: RoutePreferences,
                                directions: Bool) -> [String: Any] {
        [
            "locations": locations,
            "costing": costing(for: mode),
            "costing_options": [costing(for: mode): costingOptions(for: mode, preferences: preferences)],
            "directions_type": directions ? "instructions" : "none",
            "language": "en-US",
            // Kilometres, so a length is metres with one multiplication;
            // the UI says miles.
            "units": "kilometers",
            // No intersecting edges. Listing them makes the leg builder
            // follow every path node's transitions to the local level,
            // which for a cross-country leg on the highway levels loads
            // every local tile along the corridor: twenty-four fetches and
            // seven seconds, measured, for a leg that needed none of them.
            // The filter is honoured by the patch in
            // scripts/valhalla-intersecting-edges.patch; unpatched, it
            // costs nothing and changes nothing.
            "filters": [
                "attributes": intersectingEdgeAttributes,
                "action": "exclude",
            ],
        ]
    }

    /// Runs one request through the actor and returns the reply as JSON.
    private func ask(_ request: [String: Any], what: String) throws -> [String: Any] {
        let body = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)

        var error: UnsafeMutablePointer<CChar>?
        let started = ContinuousClock.now
        let reply: String? = lock.withLock {
            guard let out = valhalla_engine_route(engine, body, &error) else { return nil }
            defer { valhalla_free(out) }
            return String(cString: out)
        }
        // Left in on purpose: this number decides how routing feels, and it
        // changes with the graph. Whole seconds and the fraction both: the
        // first version read only the fraction and logged a sixteen-second
        // cold route as 241 ms.
        NSLog("[Swiftcamp] %@ %.0f ms, %d KB reply", what, Timing.milliseconds(since: started),
              (reply?.utf8.count ?? 0) / 1000)
        guard let reply else {
            throw RoutingError(message: Self.take(error) ?? "no route")
        }
        guard let json = try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any]
        else { throw RoutingError(message: "unexpected reply from the routing engine") }
        return json
    }

    /// The engine as a `LegShaper` for a mode: the routed path with both
    /// landings, or a straight leg when there is no road, so an edit never
    /// fails outright.
    func legShaper(for mode: RoutingMode, preferences: RoutePreferences) -> RouteEditing.LegShaper {
        { [self] a, b in
            do {
                let path = try route(from: a, to: b, mode: mode, preferences: preferences)
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

    /// Every attribute of a node's intersecting edges, as Valhalla names
    /// them; the shape needs none.
    private static let intersectingEdgeAttributes = [
        "begin_heading", "from_edge_name_consistency", "to_edge_name_consistency", "driveability",
        "cyclability", "walkability", "use", "road_class", "lane_count", "sign_info",
    ].map { "node.intersecting_edge.\($0)" }

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
