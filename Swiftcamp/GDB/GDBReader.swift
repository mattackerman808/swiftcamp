import Foundation

/// Reads Garmin's GDB, the binary format MapSource saved to and BaseCamp
/// exports and autosaves to. Written from Herbert Oppmann's published notes
/// on the format and checked against files GPSBabel writes and reads;
/// GPSBabel's own reader was read for understanding and not copied.
///
/// ## Why this exists
///
/// A BaseCamp user's years of waypoints and routes live in this format, in
/// their exports and in the `AllData.gdb` the app autosaves to. Telling
/// them to export everything to GPX first is a chore, and impossible on
/// the day BaseCamp stops launching. Reading GDB is what lets a library
/// come across whole.
///
/// ## Shape of the file
///
/// A signature, then records: a four-byte length, a one-byte type, and
/// that many bytes of content. Every record is parsed from its own slice,
/// so a field this reader misjudges spoils that record alone and never
/// desynchronises the file; the framing is trusted and the fields are
/// not. Record types this reader does not know, of which BaseCamp writes
/// several, are skipped whole.
///
/// ## Two layouts
///
/// The `D` record carries a format version. Everything through 1.9, which
/// is what MapSource wrote, what BaseCamp's Export writes as "version 3"
/// and what GPSBabel writes, has one layout of waypoint, route and track.
/// From 1.46, which is BaseCamp's autosaved `AllData.gdb`, they are laid
/// out differently, and the notes describe that layout with gaps. Both are
/// here; the newer one was corrected against a real BaseCamp 4.8 autosave
/// on the Mac, format 1.88, whose route walks field by field to the byte
/// and reproduces the same road as BaseCamp's export of it.
enum GDBReader {
    static func read(contentsOf url: URL) throws -> GPXDocument {
        try read(data: Data(contentsOf: url))
    }

    static func read(data: Data) throws -> GPXDocument {
        var parser = Parser(data: data)
        return try parser.read()
    }

    /// Whether the bytes start like a GDB file, for a caller deciding which
    /// reader a file wants.
    static func looksLikeGDB(_ data: Data) -> Bool {
        data.count > 6 && data.prefix(4) == Data("MsRc".utf8)
    }
}

enum GDBError: LocalizedError, Equatable {
    case notGDB
    case truncated
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .notGDB: "This is not a Garmin GDB file."
        case .truncated: "The GDB file ends in the middle of a record."
        case .malformed(let what): "The GDB file could not be read: \(what)."
        }
    }
}

// MARK: - Parser

private struct Parser {
    let data: Data
    /// The `D` record's version as major × 100 + minor: 1.9 is 109, 1.88
    /// is 188. Every layout decision below is a comparison against it.
    var version = 0

    /// Waypoints by name, for a route point that names one and carries no
    /// position of its own, which MapSource files do.
    var waypointsByName: [String: Waypoint] = [:]

    init(data: Data) { self.data = data }

    mutating func read() throws -> GPXDocument {
        guard GDBReader.looksLikeGDB(data) else { throw GDBError.notGDB }
        var cursor = GDBCursor(data, from: 4)
        let primary = try cursor.u16()  // 0x64 MPS, 0x65 early GDB, 0x66 GDB and GFI

        var document = GPXDocument()
        var sawHeader = false
        while cursor.remaining >= 5 {
            let length = Int(try cursor.u32())
            let type = try cursor.u8()
            guard cursor.remaining >= length else { throw GDBError.truncated }
            let slice = GDBCursor(data, from: cursor.offset, count: length)
            cursor.skip(length)

            switch type {
            case UInt8(ascii: "D"):
                var s = slice
                version = Int(try s.u16())
            case UInt8(ascii: "A"):
                // Author: program version, builder, build date and time.
                // Nothing here changes how the rest reads.
                sawHeader = true
                if primary > 0x64 {
                    // The application field, "MapSource" or "BaseCamp", is
                    // a bare string between the header and the records
                    // rather than a record of its own.
                    _ = try cursor.cString()
                }
            case UInt8(ascii: "W"):
                if let waypoint = try waypoint(from: slice) {
                    document.waypoints.append(waypoint.waypoint)
                    waypointsByName[waypoint.waypoint.name] = waypoint.waypoint
                }
            case UInt8(ascii: "R"):
                if let route = try route(from: slice) { document.routes.append(route) }
            case UInt8(ascii: "T"):
                if let track = try track(from: slice) { document.tracks.append(track) }
            case UInt8(ascii: "V"), UInt8(ascii: "X"):
                // Map set name, then end of file. Anything after is not ours.
                return document
            default:
                // Images, BirdsEye, map sections, geocaches: skipped whole.
                break
            }
        }
        guard sawHeader else { throw GDBError.malformed("no header records") }
        return document
    }

    private var newLayout: Bool { version >= 146 }
    private var utf8: Bool { version >= 109 }

    // MARK: Waypoints

    private struct ReadWaypoint {
        var waypoint: Waypoint
        var wptClass: Int
    }

    /// A waypoint, or nil for one that is a piece of a route rather than a
    /// place the user made: MapSource files carry every auto-routed turn as
    /// a hidden waypoint of a higher class, and a library import that put
    /// two hundred "turn left" points beside the user's forty campsites
    /// would be the migration nobody thanks you for.
    private mutating func waypoint(from slice: GDBCursor) throws -> ReadWaypoint? {
        var c = slice
        let name = try c.string(utf8: utf8)
        let wptClass = Int(try c.u32())

        var waypoint = Waypoint(name: name, lat: 0, lon: 0)
        var symbol = 18
        if newLayout {
            // BaseCamp's autosave layout, as a 4.8 autosave has it. The
            // subclass is eighteen bytes here, not the older twenty-two,
            // and is followed by four bytes the notes do not name; a
            // creation time comes twice, the first taken as created.
            waypoint.lat = try c.coordinate()
            waypoint.lon = try c.coordinate()
            waypoint.comment = nonEmpty(try c.string(utf8: true))
            _ = try c.fdouble()                          // proximity
            _ = try c.u32()                              // display mode
            symbol = Int(try c.u32())
            _ = try c.u32()                              // colour
            _ = try c.u8()
            if version >= 154 {
                if try c.u8() == 1 { c.skip(18) }        // subclass 1
                if try c.u8() == 1 { c.skip(18) }        // subclass 2
            } else {
                c.skip(18)
            }
            c.skip(4)
            do {
                waypoint.elevation = try c.fdouble()
                _ = try c.u8()
                let links = try c.u32()
                for _ in 0..<min(links, 64) { _ = try c.string(utf8: true) }
                _ = try c.fdouble()                      // temperature
                _ = try c.u8()
                if let time = try c.fint() { waypoint.createdAt = Date(timeIntervalSince1970: TimeInterval(time)) }
            } catch {
                // Name, position, notes and symbol are read; the rest of
                // this record was not where a 4.8 autosave puts it.
            }
        } else {
            _ = try c.string(utf8: utf8)                 // country code
            c.skip(version > 100 ? 22 : 21)              // subclass
            waypoint.lat = try c.coordinate()
            waypoint.lon = try c.coordinate()
            waypoint.elevation = try c.fdouble()
            waypoint.comment = nonEmpty(try c.string(utf8: utf8))
            _ = try c.fdouble()                          // proximity
            _ = try c.u32()                              // display mode
            _ = try c.u32()                              // colour
            symbol = Int(try c.u32())
            _ = try c.string(utf8: utf8)                 // city
            _ = try c.string(utf8: utf8)                 // state
            _ = try c.string(utf8: utf8)                 // facility
            _ = try c.u8()                               // map line
            _ = try c.fdouble()                          // depth
            _ = try c.string(utf8: utf8)                 // street
            if try c.u8() == 1 { _ = try c.string(utf8: utf8) }   // unknown string
            if version >= 102 {
                _ = try c.u32()                          // predicted leg time
                _ = try c.string(utf8: utf8)             // directions
            }
            if version >= 106, version <= 108 {
                _ = try c.string(utf8: utf8)             // link
            } else if version >= 109 {
                let links = try c.u32()
                for _ in 0..<min(links, 64) { _ = try c.string(utf8: utf8) }
            }
            if version >= 106 {
                _ = try c.u16()                          // categories
                _ = try c.fdouble()                      // temperature
                if let time = try c.fint() { waypoint.createdAt = Date(timeIntervalSince1970: TimeInterval(time)) }
            }
        }
        waypoint.symbol = GDBSymbols.name(for: symbol)
        // An altitude BaseCamp did not know is written as a huge number
        // rather than left out; GPSBabel treats anything past 1e24 the
        // same way.
        if let e = waypoint.elevation, !(e < 1.0e24) { waypoint.elevation = nil }
        waypoint.updatedAt = waypoint.createdAt

        let read = ReadWaypoint(waypoint: waypoint, wptClass: wptClass)
        // A hidden route point is still needed by name; see `route(from:)`.
        if wptClass != 0 {
            waypointsByName[name] = waypoint
            return nil
        }
        return read
    }

    // MARK: Routes

    private mutating func route(from slice: GDBCursor) throws -> RouteDetail? {
        var c = slice
        var route = Route(name: try c.string(utf8: utf8))
        _ = try c.u8()                                   // auto-name flag

        var points: [RoutePoint] = []
        if newLayout {
            points = try routePoints(count: Int(try c.u32()), &c)
            if try c.u8() == 0 {                         // bounds present
                c.skip(16)
            }
        } else {
            if try c.u8() == 0 {                         // bounds present
                c.skip(8); _ = try c.fdouble()
                c.skip(8); _ = try c.fdouble()
            }
            points = try routePoints(count: Int(try c.u32()), &c)
        }

        // Past the points every field is optional to the route being
        // useful, so a misjudged one here costs the colour, not the line.
        do {
            if version >= 106, version <= 108 {
                _ = try c.string(utf8: utf8)             // link
            } else if version >= 109 {
                let links = try c.u32()
                for _ in 0..<min(links, 64) { _ = try c.string(utf8: utf8) }
            }
            if version >= 109 {
                route.color = colorName(try c.u32())
                if try c.u8() == 1 {                     // auto-route info
                    let avoidTolls = try c.u8() == 1
                    _ = try c.u8()                       // unpaved
                    _ = try c.u8()                       // u-turns
                    _ = try c.u8()                       // carpool lanes
                    let avoidFerries = try c.u8() == 1
                    _ = try c.u8()                       // closures
                    let style = try c.u8()               // 0 direct, 1 auto-routing
                    let calculation = try c.u32()        // 0 faster time, 1 shorter distance
                    _ = try c.u8()                       // vehicle
                    let roads = Int32(bitPattern: try c.u32())  // -3 minor roads to 3 highways
                    c.skip(40)                           // five driving speeds
                    let areas = try c.u32()
                    for _ in 0..<min(areas, 1024) {
                        _ = try c.string(utf8: utf8)
                        if try c.u8() == 0 { c.skip(8); _ = try c.fdouble(); c.skip(8); _ = try c.fdouble() }
                    }
                    let roadAvoidances = try c.u32()
                    for _ in 0..<min(roadAvoidances, 1024) {
                        _ = try c.string(utf8: utf8)
                        c.skip(4)
                        c.skip(8); _ = try c.fdouble(); c.skip(8); _ = try c.fdouble()
                        let linkPoints = try c.u32()
                        for _ in 0..<min(linkPoints, 100_000) { try skipLinkPoint(&c) }
                        let segments = try c.u32()
                        c.skip(Int(min(segments, 100_000)) * 16)
                    }
                    if version >= 115 {
                        _ = try c.u32(); _ = try c.double(); _ = try c.u32(); _ = try c.u32()
                    }
                    if style == 0 { route.mode = .direct }
                    route.preferences.avoidTolls = avoidTolls
                    route.preferences.avoidFerries = avoidFerries
                    route.preferences.avoidHighways = roads < 0
                    if calculation == 1 { route.preferences.prefer = .shorterDistance }
                }
                route.comment = nonEmpty(try c.string(utf8: utf8))
                if newLayout {
                    // Observed in a 4.8 autosave: a flag, a count, three
                    // bytes, then the activity profile.
                    _ = try c.u8()
                    _ = try c.u32()
                    c.skip(3)
                    switch try c.u32() {                 // activity profile
                    case 6: route.mode = .direct
                    default: break
                    }
                } else if version >= 115 {
                    _ = try c.u8()                       // filtered route
                    let filtered = try c.u32()
                    for _ in 0..<min(filtered, 100_000) { try skipLinkPoint(&c) }
                    if try c.u8() == 0 { try skipLinkPoint(&c); try skipLinkPoint(&c) }
                    if version >= 129 { _ = try c.u8() }
                }
            }
        } catch {
            // The line is read; the trailing preferences were not.
        }

        guard !points.isEmpty else { return nil }
        // The last point leads nowhere; anything folded onto it was the
        // road to a via point that never came.
        points[points.count - 1].geometry = nil
        for i in points.indices { points[i].routeID = route.id; points[i].seq = i }
        route.createdAt = .now
        route.updatedAt = .now
        return RouteDetail(route: route, points: points)
    }

    /// The route's points. A user's via point is class 0 and has a waypoint
    /// of its own; anything else is a point the router placed at a turn,
    /// and those fold into the road rather than becoming points here. Each
    /// point carries the links to the next one, beginning with its own
    /// position, so a via point's geometry is its own links and every
    /// hidden point's after it, less the final vertex, which is the next
    /// via point. That is the reason a GDB route arrives on a device
    /// following the road MapSource chose.
    ///
    /// Folding the turn points is what BaseCamp's own GPX export and
    /// GPSBabel both do. A real BaseCamp route from Santa Clara to Reno
    /// carried 1,081 of them, and kept as shaping points they were a map of
    /// dots and a sidebar of 1,081 rows; folded, they are the line. A
    /// shaping point the user placed in BaseCamp is not distinguishable
    /// from a turn point in a file seen so far and folds with them: the
    /// line is unchanged, only the handle is lost.
    private mutating func routePoints(count: Int, _ c: inout GDBCursor) throws -> [RoutePoint] {
        var points: [RoutePoint] = []
        for _ in 0..<min(count, 100_000) {
            let name = try c.string(utf8: utf8)
            let wptClass = Int(try c.u32())
            if !newLayout {
                _ = try c.string(utf8: utf8)             // country code
                c.skip(version > 100 ? 22 : 21)          // subclass
            }
            if try c.u8() == 1 { _ = try c.string(utf8: utf8) }   // unknown string
            let links = try linkedPointTail(&c)
            if version >= 108 { c.skip(8) }
            if version >= 115, !newLayout { _ = try c.u32(); _ = try c.u8() }
            if version >= 109 {
                _ = try c.fint()
                if let _ = try c.fint(), version >= 129 { _ = try c.fdouble() }
            }
            if version >= 129, !newLayout {
                let some = Int(try c.u32())
                c.skip(some)
            }
            try append(name: name, wptClass: wptClass, links: links, to: &points)

            if newLayout {
                // The autosave keeps the turns the router placed inside
                // the via point they follow, each with its own links, its
                // instruction and its leg time: the same thing an older
                // file spreads over hidden route points.
                c.skip(13)
                let turns = try c.u32()
                for _ in 0..<min(turns, 100_000) {
                    let lat = try c.coordinate(), lon = try c.coordinate()
                    let turnClass = Int(try c.u32())
                    c.skip(18)                           // subclass
                    _ = try c.u32()                      // leg time, seconds
                    _ = try c.string(utf8: true)         // the instruction
                    c.skip(2)
                    let turnLinks = try linkedPointTail(&c)
                    c.skip(8 + 3)
                    try append(name: "", wptClass: max(turnClass, 1),
                               links: turnLinks.isEmpty ? [Coordinate(lat: lat, lon: lon)] : turnLinks,
                               to: &points)
                }
            }
        }
        return points
    }

    /// The part a via point and a turn share: five fields nobody has
    /// named, then the links to the next point, then bounds.
    private func linkedPointTail(_ c: inout GDBCursor) throws -> [Coordinate] {
        c.skip(12)                                       // unknown 2, 3, 4
        c.skip(version > 100 ? 2 : 1)                    // unknown 5
        _ = try c.u32()                                  // unknown 6
        let linkCount = Int(try c.u32())
        var links: [Coordinate] = []
        links.reserveCapacity(min(linkCount, 100_000))
        for _ in 0..<min(linkCount, 100_000) {
            let lat = try c.coordinate(), lon = try c.coordinate()
            if !newLayout { _ = try c.fdouble() }
            links.append(Coordinate(lat: lat, lon: lon))
        }
        if try c.u8() == 0 {                             // bounds present
            c.skip(8); if !newLayout { _ = try c.fdouble() }
            c.skip(8); if !newLayout { _ = try c.fdouble() }
        }
        return links
    }

    /// Adds a route point, or folds a turn into the previous one's leg.
    /// A point's links begin with its own position and end with the next
    /// point's, so the road it contributes is its links less the last.
    private func append(name: String, wptClass: Int, links: [Coordinate], to points: inout [RoutePoint]) throws {
        let position: Coordinate
        if let first = links.first {
            position = first
        } else if let known = waypointsByName[name] {
            position = known.coordinate
        } else {
            throw GDBError.malformed("route point \"\(name)\" has no position")
        }
        let road = links.count > 1 ? Array(links.dropLast()) : []

        if wptClass != 0, !points.isEmpty {
            var geometry = points[points.count - 1].geometry ?? []
            geometry.append(contentsOf: road.isEmpty ? [position] : road)
            points[points.count - 1].geometry = geometry
            return
        }
        var point = RoutePoint(routeID: "", seq: points.count, lat: position.lat, lon: position.lon,
                               name: wptClass == 0 ? nonEmpty(name) : nil,
                               isVia: wptClass == 0)
        if road.count > 1 { point.geometry = Array(road.dropFirst()) }
        points.append(point)
    }

    private func skipLinkPoint(_ c: inout GDBCursor) throws {
        c.skip(8)
        if !newLayout { _ = try c.fdouble() }
    }

    // MARK: Tracks

    private mutating func track(from slice: GDBCursor) throws -> TrackDetail? {
        var c = slice
        var track = Track(name: try c.string(utf8: utf8))
        _ = try c.u8()                                   // display
        track.color = colorName(try c.u32())
        var points: [TrackPoint] = []

        if newLayout {
            let links = try c.u32()
            for _ in 0..<min(links, 64) { _ = try c.string(utf8: true) }
            track.comment = nonEmpty(try c.string(utf8: true))
            _ = try c.double()                           // area
            _ = try c.fdouble()
            _ = try c.u8()
            c.skip(16)                                   // bounds
            _ = try c.fdouble()                          // duration
            _ = try c.double()                           // length
            _ = try c.fint()                             // start time
            let segments = try c.u32()
            for segment in 0..<min(segments, 100_000) {
                _ = try c.u8()
                c.skip(16)
                let n = Int(try c.u32())
                for _ in 0..<min(n, 10_000_000) {
                    let lat = try c.coordinate(), lon = try c.coordinate()
                    points.append(TrackPoint(trackID: track.id, seq: points.count, segment: Int(segment), lat: lat, lon: lon))
                }
            }
        } else {
            let n = Int(try c.u32())
            for _ in 0..<min(n, 10_000_000) {
                let lat = try c.coordinate(), lon = try c.coordinate()
                var elevation = try c.fdouble()
                if let e = elevation, !(e < 1.0e24) { elevation = nil }
                let time = try c.fint().map { Date(timeIntervalSince1970: TimeInterval($0)) }
                _ = try c.fdouble()                      // depth
                if version >= 106 { _ = try c.fdouble() }   // temperature
                if version >= 129 { _ = try c.fdouble(); _ = try c.fdouble() }
                points.append(TrackPoint(trackID: track.id, seq: points.count, lat: lat, lon: lon,
                                         elevation: elevation, time: time))
            }
            do {
                if version >= 106, version <= 108 {
                    _ = try c.string(utf8: utf8)
                } else if version >= 109 {
                    let links = try c.u32()
                    for _ in 0..<min(links, 64) { _ = try c.string(utf8: utf8) }
                }
                if version >= 115 { track.comment = nonEmpty(try c.string(utf8: utf8)) }
            } catch {
                // The points are read; the notes were not.
            }
        }
        guard !points.isEmpty else { return nil }
        return TrackDetail(track: track, points: points)
    }

    // MARK: Helpers

    /// MapSource's colour index to Garmin's GPX name. The same sixteen
    /// `ItemColor` holds, in MapSource's order; 0 is "no colour chosen"
    /// and 17 is transparent, which a line cannot usefully be.
    private func colorName(_ index: UInt32) -> String? {
        let names = ["Black", "DarkRed", "DarkGreen", "DarkYellow", "DarkBlue", "DarkMagenta", "DarkCyan",
                     "LightGray", "DarkGray", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
        guard index >= 1, Int(index) <= names.count else { return nil }
        return names[Int(index) - 1]
    }

    private func nonEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }
}

// MARK: - Cursor

/// A little-endian reader over a slice of the file. Every read is bounds
/// checked and throws `truncated` rather than trapping, because the input
/// is a file from somewhere else.
struct GDBCursor {
    let data: Data
    private(set) var offset: Int
    let end: Int

    init(_ data: Data, from offset: Int, count: Int? = nil) {
        self.data = data
        self.offset = offset
        self.end = count.map { min(offset + $0, data.count) } ?? data.count
    }

    var remaining: Int { end - offset }

    mutating func skip(_ n: Int) { offset = min(offset + max(n, 0), end) }

    private mutating func take(_ n: Int) throws -> Data {
        guard n >= 0, remaining >= n else { throw GDBError.truncated }
        defer { offset += n }
        return data.subdata(in: offset..<(offset + n))
    }

    mutating func u8() throws -> UInt8 { try take(1)[0] }

    mutating func u16() throws -> UInt16 {
        let b = try take(2)
        return UInt16(b[b.startIndex]) | UInt16(b[b.startIndex + 1]) << 8
    }

    mutating func u32() throws -> UInt32 {
        let b = try take(4)
        return b.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }

    mutating func double() throws -> Double {
        let b = try take(8)
        let bits = b.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        return Double(bitPattern: bits)
    }

    /// A latitude or longitude: a signed 32-bit semicircle count.
    mutating func coordinate() throws -> Double {
        Double(Int32(bitPattern: try u32())) * 360.0 / 4_294_967_296.0
    }

    /// A flag byte and, when it is 1, a double.
    mutating func fdouble() throws -> Double? {
        try u8() == 1 ? try double() : nil
    }

    /// A flag byte and, when it is 1, a signed int. Times are these.
    mutating func fint() throws -> Int32? {
        try u8() == 1 ? Int32(bitPattern: try u32()) : nil
    }

    /// A zero-terminated string, Latin-1 before format 1.9 and UTF-8 from
    /// it, which is when MapSource changed. A file that ends inside a
    /// string is truncated.
    mutating func string(utf8: Bool) throws -> String {
        guard let zero = data[offset..<end].firstIndex(of: 0) else { throw GDBError.truncated }
        let bytes = data[offset..<zero]
        offset = zero + 1
        if bytes.isEmpty { return "" }
        return String(data: bytes, encoding: utf8 ? .utf8 : .isoLatin1)
            ?? String(data: bytes, encoding: .isoLatin1) ?? ""
    }

    mutating func cString() throws -> String { try string(utf8: true) }
}
