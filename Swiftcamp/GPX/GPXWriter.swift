import Foundation

/// Writes GPX 1.1, with the Garmin extensions a device needs.
///
/// Hand-rolled emission rather than a tree API, to match the reader and to
/// keep the file's exact shape under our control. What it writes is the
/// product: a route that looks right on screen and imports wrong is a failed
/// feature, and every rule below is about not being that.
enum GPXWriter {
    static func write(_ document: GPXDocument) -> String {
        var out = ""
        out += #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
        out += "<gpx version=\"1.1\" creator=\"\(escape(document.creator))\"\n"
        out += "     xmlns=\"\(GPX.namespace)\"\n"
        out += "     xmlns:gpxx=\"\(GPX.garminExtensions)\"\n"
        out += "     xmlns:trp=\"\(GPX.garminTripExtensions)\"\n"
        out += "     xmlns:sc=\"\(GPX.swiftcampExtensions)\">\n"

        out += metadata(document)
        // Order is fixed by the schema: metadata, then every wpt, then every
        // rte, then every trk. Interleaving them produces a file that opens
        // in forgiving readers and fails validation everywhere else.
        document.waypoints.forEach { out += waypoint($0) }
        document.routes.forEach { out += route($0) }
        document.tracks.forEach { out += track($0) }

        out += "</gpx>\n"
        return out
    }

    static func data(_ document: GPXDocument) -> Data {
        Data(write(document).utf8)
    }

    // MARK: - Sections

    private static func metadata(_ document: GPXDocument) -> String {
        var inner = ""
        inner += element("name", document.name, indent: 4)
        inner += element("desc", document.descriptionText, indent: 4)
        if let time = document.time {
            inner += element("time", GPXDate.string(from: time), indent: 4)
        }
        guard !inner.isEmpty else { return "" }
        return "  <metadata>\n\(inner)  </metadata>\n"
    }

    private static func waypoint(_ w: Waypoint) -> String {
        var out = "  <wpt lat=\"\(number(w.lat))\" lon=\"\(number(w.lon))\">\n"
        // wptType is a sequence, not a choice: ele, time, …, name, cmt, desc,
        // …, sym. These four have to appear in this order.
        if let elevation = w.elevation { out += element("ele", number(elevation), indent: 4) }
        out += element("name", w.name, indent: 4)
        out += element("cmt", w.comment, indent: 4)
        out += element("desc", w.descriptionText, indent: 4)
        out += element("sym", w.symbol, indent: 4)
        out += "  </wpt>\n"
        return out
    }

    private static func route(_ detail: RouteDetail) -> String {
        var out = "  <rte>\n"
        out += element("name", detail.route.name, indent: 4)
        out += element("cmt", detail.route.comment, indent: 4)

        // rteType puts extensions before the first rtept.
        out += "    <extensions>\n"
        if let color = detail.route.color {
            out += "      <gpxx:RouteExtension>\n"
            // BaseCamp writes IsAutoNamed and some readers expect the element
            // to exist. False is the honest answer: these names came from a
            // file or from the user, never from a road we picked.
            out += "        <gpxx:IsAutoNamed>false</gpxx:IsAutoNamed>\n"
            out += element("gpxx:DisplayColor", color, indent: 8)
            out += "      </gpxx:RouteExtension>\n"
        }
        // The activity profile, in Garmin's vocabulary: Motorcycling for a
        // road or adventure route, Direct for straight lines. Which of the
        // first two it was is ours to remember, in our own namespace, so a
        // re-import does not turn an adventure route back into a road one
        // at its next edit.
        let mode = detail.route.mode
        out += "      <trp:Trip>\n"
        out += "        <trp:TransportationMode>\(mode == .direct ? "Direct" : "Motorcycling")</trp:TransportationMode>\n"
        out += "      </trp:Trip>\n"
        if mode == .adventure {
            out += "      <sc:RoutingMode>\(mode.rawValue)</sc:RoutingMode>\n"
        }
        // The route's preferences. Garmin's own word for what to optimise
        // goes on every via point below, as BaseCamp writes it; which
        // curvy level it was, and what to avoid, are ours.
        let preferences = detail.route.preferences
        if preferences.prefer != .fasterTime {
            out += "      <sc:Prefer>\(preferences.prefer.rawValue)</sc:Prefer>\n"
        }
        if !preferences.avoided.isEmpty {
            out += "      <sc:Avoid>\(preferences.avoided.joined(separator: " "))</sc:Avoid>\n"
        }
        out += "    </extensions>\n"

        for point in detail.points.sorted(by: { $0.seq < $1.seq }) {
            out += routePoint(point, calculationMode: preferences.prefer.garminCalculationMode)
        }
        out += "  </rte>\n"
        return out
    }

    /// A route point, carrying the road that leads away from it and whether
    /// it is a stop.
    ///
    /// The `gpxx:rpt` list is the whole reason this file format is worth
    /// getting exactly right. Without it a Garmin unit re-routes between via
    /// points using its own map and its own preferences, and the rider ends
    /// up somewhere other than where the route was planned. With it, the
    /// device follows the shape it was given.
    ///
    /// The `trp` element says what kind of point this is, in the exact
    /// shape BaseCamp writes: a shaping point is an empty element, a via
    /// point carries the two modes BaseCamp always gives it. Written for
    /// every point, because a unit reading a file with neither treats the
    /// point as a stop, and a shaping point that is announced as a
    /// destination is the bug this distinction exists to prevent.
    private static func routePoint(_ p: RoutePoint, calculationMode: String) -> String {
        var out = "    <rtept lat=\"\(number(p.lat))\" lon=\"\(number(p.lon))\">\n"
        out += element("name", p.name, indent: 6)
        out += element("sym", p.symbol, indent: 6)

        out += "      <extensions>\n"
        if p.isVia {
            out += "        <trp:ViaPoint>\n"
            out += "          <trp:CalculationMode>\(calculationMode)</trp:CalculationMode>\n"
            out += "          <trp:ElevationMode>Standard</trp:ElevationMode>\n"
            out += "        </trp:ViaPoint>\n"
        } else {
            out += "        <trp:ShapingPoint/>\n"
        }
        if let geometry = p.geometry, !geometry.isEmpty {
            out += "        <gpxx:RoutePointExtension>\n"
            for c in geometry {
                out += "          <gpxx:rpt lat=\"\(number(c.lat))\" lon=\"\(number(c.lon))\"/>\n"
            }
            out += "        </gpxx:RoutePointExtension>\n"
        }
        out += "      </extensions>\n"

        out += "    </rtept>\n"
        return out
    }

    private static func track(_ detail: TrackDetail) -> String {
        var out = "  <trk>\n"
        out += element("name", detail.track.name, indent: 4)
        out += element("cmt", detail.track.comment, indent: 4)

        if let color = detail.track.color {
            out += "    <extensions>\n"
            out += "      <gpxx:TrackExtension>\n"
            out += element("gpxx:DisplayColor", color, indent: 8)
            out += "      </gpxx:TrackExtension>\n"
            out += "    </extensions>\n"
        }

        // One trkseg per segment. The break between them is where the
        // recording stopped, and merging them would draw a line down a road
        // the rider never took.
        let bySegment = Dictionary(grouping: detail.points.sorted { $0.seq < $1.seq },
                                   by: \.segment).sorted { $0.key < $1.key }
        for (_, points) in bySegment {
            out += "    <trkseg>\n"
            for p in points {
                out += "      <trkpt lat=\"\(number(p.lat))\" lon=\"\(number(p.lon))\">\n"
                if let elevation = p.elevation { out += element("ele", number(elevation), indent: 8) }
                if let time = p.time { out += element("time", GPXDate.string(from: time), indent: 8) }
                out += "      </trkpt>\n"
            }
            out += "    </trkseg>\n"
        }

        out += "  </trk>\n"
        return out
    }

    // MARK: - Primitives

    private static func element(_ name: String, _ value: String?, indent: Int) -> String {
        guard let value, !value.isEmpty else { return "" }
        // Already-qualified names like `gpxx:DisplayColor` pass through; the
        // value is what gets escaped.
        return String(repeating: " ", count: indent)
            + "<\(name)>\(escape(value))</\(name)>\n"
    }

    /// The five XML predefined entities.
    ///
    /// `&` first, or the ampersands introduced by the other four get escaped
    /// a second time and `<` comes out as `&amp;lt;`.
    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Swift's own `Double` description, which is the shortest string that
    /// reads back as the same value, and is locale-independent — unlike a
    /// `NumberFormatter`, which would write `40,3772` for a German user and
    /// produce a file no GPS on earth can read.
    ///
    /// Exponent notation would be invalid here, but `xsd:decimal` values in
    /// this file are coordinates, elevations in metres, and nothing else, so
    /// the magnitudes never reach it.
    private static func number(_ value: Double) -> String {
        String(value)
    }
}
