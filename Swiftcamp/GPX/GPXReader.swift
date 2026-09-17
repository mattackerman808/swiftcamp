import Foundation

/// Reads GPX 1.1 and 1.0, including the Garmin extensions that carry a
/// route's shape.
///
/// Event-driven rather than tree-based. `XMLDocument` would be less code,
/// but a recorded track runs to hundreds of thousands of points and building
/// a whole node tree to walk it once is the wrong shape. It is also the only
/// XML API iOS has, which keeps that door open.
///
/// ## Namespaces, not prefixes
///
/// Element identity comes from the namespace URI, never from the prefix in
/// the file. `gpxx:` is a convention, not a rule — a file is free to bind
/// Garmin's extensions to `g:` or to a default namespace, and matching on the
/// literal string `gpxx:rpt` would silently drop the route's shape from a
/// file that is perfectly valid.
final class GPXReader: NSObject {
    static func read(data: Data) throws -> GPXDocument {
        let reader = GPXReader()
        return try reader.parse(data)
    }

    static func read(contentsOf url: URL) throws -> GPXDocument {
        try read(data: try Data(contentsOf: url))
    }

    // MARK: - State

    private var document = GPXDocument()
    private var failure: GPXError?
    private var sawGPXRoot = false

    /// Character data for the element currently open. GPX puts every scalar
    /// in element text rather than attributes, apart from lat/lon.
    private var text = ""

    /// Where we are. A stack rather than a set of booleans because `<name>`
    /// means five different things depending on its parent.
    private var path: [String] = []

    private var waypoint: Waypoint?
    private var route: Route?
    private var routePoints: [RoutePoint] = []
    private var routePoint: RoutePoint?
    /// `gpxx:rpt` points accumulating inside the current `<rtept>`.
    private var shapingPoints: [Coordinate] = []

    private var track: Track?
    private var trackPoints: [TrackPoint] = []
    private var trackPoint: TrackPoint?
    private var segment = -1

    /// Depth inside an `<extensions>` element we do not understand, so its
    /// contents can be ignored wholesale without confusing the path.
    private var unknownExtensionDepth = 0

    private func parse(_ data: Data) throws -> GPXDocument {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = self

        guard parser.parse() else {
            if let failure { throw failure }
            let reason = parser.parserError?.localizedDescription ?? "unknown error"
            // A file that is not XML at all fails here, before the root
            // element is ever seen, and "not GPX" is the more useful thing
            // to tell someone who picked the wrong file.
            throw sawGPXRoot ? GPXError.malformed(reason) : GPXError.notGPX
        }
        if let failure { throw failure }
        guard sawGPXRoot else { throw GPXError.notGPX }
        return document
    }
}

// MARK: - XMLParserDelegate

extension GPXReader: XMLParserDelegate {
    func parser(_ parser: XMLParser,
                didStartElement element: String,
                namespaceURI: String?,
                qualifiedName: String?,
                attributes: [String: String]) {
        text = ""

        if unknownExtensionDepth > 0 {
            unknownExtensionDepth += 1
            return
        }

        if namespaceURI == GPX.garminExtensions {
            startGarminElement(element, attributes: attributes)
            return
        }
        if namespaceURI == GPX.garminTripExtensions {
            startTripElement(element)
            return
        }
        if namespaceURI == GPX.swiftcampExtensions { return }

        // Anything from a namespace we do not handle is skipped whole,
        // children included. Garmin's TrackPointExtension lands here, as does
        // every vendor's private block.
        guard GPX.isGPXNamespace(namespaceURI) else {
            unknownExtensionDepth = 1
            return
        }

        path.append(element)

        switch element {
        case "gpx":
            sawGPXRoot = true
            document.creator = attributes["creator"] ?? GPX.creator

        case "wpt":
            guard let coordinate = coordinate(from: attributes, parser: parser) else { return }
            waypoint = Waypoint(name: "", lat: coordinate.lat, lon: coordinate.lon)

        case "rte":
            route = Route(name: "")
            routePoints = []

        case "rtept":
            guard let coordinate = coordinate(from: attributes, parser: parser) else { return }
            routePoint = RoutePoint(routeID: "", seq: routePoints.count,
                                    lat: coordinate.lat, lon: coordinate.lon)
            shapingPoints = []

        case "trk":
            track = Track(name: "")
            trackPoints = []
            segment = -1

        case "trkseg":
            segment += 1

        case "trkpt":
            guard let coordinate = coordinate(from: attributes, parser: parser) else { return }
            trackPoint = TrackPoint(trackID: "", seq: trackPoints.count,
                                    // A `<trkpt>` outside any `<trkseg>` is
                                    // invalid, but files in the wild do it.
                                    // Treat it as opening segment zero rather
                                    // than dropping the point.
                                    segment: max(segment, 0),
                                    lat: coordinate.lat, lon: coordinate.lon)
            if segment < 0 { segment = 0 }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard unknownExtensionDepth == 0 else { return }
        text += string
    }

    func parser(_ parser: XMLParser,
                didEndElement element: String,
                namespaceURI: String?,
                qualifiedName: String?) {
        if unknownExtensionDepth > 0 {
            unknownExtensionDepth -= 1
            return
        }
        if namespaceURI == GPX.garminExtensions {
            endGarminElement(element)
            return
        }
        if namespaceURI == GPX.garminTripExtensions {
            endTripElement(element)
            return
        }
        if namespaceURI == GPX.swiftcampExtensions {
            endSwiftcampElement(element)
            return
        }
        guard GPX.isGPXNamespace(namespaceURI) else { return }

        defer {
            if path.last == element { path.removeLast() }
            text = ""
        }

        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = path.dropLast().last

        switch element {
        case "wpt":
            if let waypoint { document.waypoints.append(waypoint) }
            waypoint = nil

        case "rte":
            if var route {
                if route.name.isEmpty { route.name = "Route" }
                document.routes.append(RouteDetail(route: route, points: routePoints))
            }
            route = nil
            routePoints = []

        case "rtept":
            if var point = routePoint {
                point.geometry = shapingPoints.isEmpty ? nil : shapingPoints
                routePoints.append(point)
            }
            routePoint = nil
            shapingPoints = []

        case "trk":
            if var track {
                if track.name.isEmpty { track.name = "Track" }
                document.tracks.append(TrackDetail(track: track, points: trackPoints))
            }
            track = nil
            trackPoints = []

        case "trkpt":
            if let trackPoint { trackPoints.append(trackPoint) }
            trackPoint = nil

        case "name":
            switch parent {
            case "metadata": document.name = value
            case "wpt": waypoint?.name = value
            case "rte": route?.name = value
            case "rtept": routePoint?.name = value
            case "trk": track?.name = value
            default: break
            }

        case "desc":
            switch parent {
            case "metadata": document.descriptionText = value
            case "wpt": waypoint?.descriptionText = value
            default: break
            }

        case "cmt":
            switch parent {
            case "wpt": waypoint?.comment = value
            case "rte": route?.comment = value
            case "trk": track?.comment = value
            default: break
            }

        case "sym":
            switch parent {
            case "wpt": waypoint?.symbol = value
            case "rtept": routePoint?.symbol = value
            default: break
            }

        case "ele":
            let elevation = Double(value)
            switch parent {
            case "wpt": waypoint?.elevation = elevation
            case "trkpt": trackPoint?.elevation = elevation
            default: break
            }

        case "time":
            let date = GPXDate.parse(value)
            switch parent {
            case "metadata": document.time = date
            case "trkpt": trackPoint?.time = date
            default: break
            }

        default:
            break
        }
    }

    // MARK: - Garmin extensions

    private func startGarminElement(_ element: String, attributes: [String: String]) {
        // The reason this reader exists in the shape it does.
        //
        // A Garmin route is via points plus, inside each one's extension, the
        // full road geometry leading away from it. Drop these and the device
        // re-routes from scratch on import, which is how a route that looks
        // right on screen arrives wrong on the GPS.
        guard element == "rpt",
              let lat = attributes["lat"].flatMap(Double.init),
              let lon = attributes["lon"].flatMap(Double.init) else { return }
        shapingPoints.append(Coordinate(lat: lat, lon: lon))
    }

    private func endGarminElement(_ element: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        guard element == "DisplayColor", !value.isEmpty else { return }

        // Carried verbatim rather than mapped to an internal palette. It is
        // Garmin's vocabulary, and a colour we do not recognise today should
        // still come back out of the file unchanged.
        if route != nil { route?.color = value } else if track != nil { track?.color = value }
    }

    /// Whether the current route point is a stop or only shapes the road.
    ///
    /// Matched on namespace like everything else, so a file that binds the
    /// trip extensions to some other prefix still reads. A point marked
    /// neither way stays a via point, which is what a device assumes too.
    private func startTripElement(_ element: String) {
        guard routePoint != nil else { return }
        switch element {
        case "ShapingPoint": routePoint?.isVia = false
        case "ViaPoint": routePoint?.isVia = true
        default: break
        }
    }

    /// The route's activity profile. Direct is the one word of Garmin's
    /// that changes how a route is edited here; every other profile is a
    /// road route, which is also what an unmarked route is.
    private func endTripElement(_ element: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        guard element == "TransportationMode", route != nil, routePoint == nil else { return }
        if value == "Direct" { route?.mode = .direct }
    }

    /// Our own word for what Garmin's cannot say; see `GPX.swiftcampExtensions`.
    private func endSwiftcampElement(_ element: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        guard element == "RoutingMode", route != nil, routePoint == nil,
              let mode = RoutingMode(rawValue: value) else { return }
        route?.mode = mode
    }

    // MARK: - Helpers

    /// `lat` and `lon` are required on every point element in the schema. A
    /// point without them is not a point, so the file is malformed rather
    /// than merely odd, and continuing would silently drop geometry.
    private func coordinate(from attributes: [String: String], parser: XMLParser) -> Coordinate? {
        guard let lat = attributes["lat"].flatMap(Double.init),
              let lon = attributes["lon"].flatMap(Double.init) else {
            failure = .malformed("a point is missing its lat or lon attribute")
            parser.abortParsing()
            return nil
        }
        return Coordinate(lat: lat, lon: lon)
    }
}

/// GPX timestamps.
///
/// The schema says `xsd:dateTime`, which permits fractional seconds and any
/// UTC offset. Real files use all of it: Garmin writes whole seconds and `Z`,
/// phone apps write milliseconds, and some tools write `+02:00`. One
/// formatter handles none of those cases alone, so this tries the shapes in
/// order rather than assuming.
enum GPXDate {
    private static let withFractionalSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let wholeSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return withFractionalSeconds.date(from: trimmed) ?? wholeSeconds.date(from: trimmed)
    }

    /// Always UTC with whole seconds, which is what Garmin writes and the
    /// most conservative thing a device will accept.
    static func string(from date: Date) -> String {
        wholeSeconds.string(from: date)
    }
}
