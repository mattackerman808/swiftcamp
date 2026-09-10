import Foundation

/// Builds a MapLibre style JSON on disk for the Protomaps basemap schema.
///
/// The same style feeds both platforms — MapLibre Native on iOS and
/// MapLibre GL JS on macOS — which is the whole reason the split-backend
/// plan is tolerable. Cartography is defined once here; only the host
/// view differs. Never fork this file per platform.
///
/// Layer names come from the tileset's own schema (`pmtiles show
/// --metadata`): boundaries, buildings, earth, landcover, landuse,
/// places, pois, roads, water.
///
/// **No text layers yet.** Labels need a `glyphs` URL, and pointing that
/// at a remote server would break the offline guarantee the bundled
/// basemap exists to provide. Bundling a glyph set (as tachbase-ios does
/// under `Resources/Glyphs`) is the fix, and is deliberately deferred.
enum MapStyle {
    /// The style as JSON text.
    ///
    /// macOS needs the string (it is injected into the web view before the
    /// page loads); iOS needs a file URL. Both come from here so there is
    /// exactly one definition of the cartography.
    static func json(sourceURL: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: dictionary(sourceURL: sourceURL),
                                              options: [.prettyPrinted])
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return text
    }

    /// Writes the style to a temp file and returns its URL, because
    /// MapLibre Native takes a style *URL* rather than a string.
    static func write(sourceURL: String) throws -> URL {
        let data = try JSONSerialization.data(withJSONObject: dictionary(sourceURL: sourceURL),
                                              options: [.prettyPrinted])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftcamp-style.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func dictionary(sourceURL: String) -> [String: Any] {
        [
            "version": 8,
            "name": "Swiftcamp Base",
            "sources": [
                "protomaps": [
                    "type": "vector",
                    "url": sourceURL,
                    "attribution": BasemapSource.attribution,
                ],
            ],
            "layers": layers(),
        ]
    }

    // MARK: - Palette

    // Muted enough that a magenta route line drawn on top stays the
    // loudest thing on screen. Touring routes are the subject; the
    // basemap is context.
    private enum Palette {
        static let background = "#f5f3ee"
        static let earth      = "#f5f3ee"
        static let landcover  = "#e6ebe0"
        static let landuse    = "#eceee8"
        static let water      = "#b9d9e8"
        static let boundary   = "#9a9a9a"
        static let roadMinor  = "#ffffff"
        static let roadMajor  = "#fdf3d8"
        static let roadCasing = "#e0d9c4"
    }

    private static func layers() -> [[String: Any]] {
        var out: [[String: Any]] = []

        out.append([
            "id": "background",
            "type": "background",
            "paint": ["background-color": Palette.background],
        ])

        out.append(fill("earth", source: "earth", color: Palette.earth))
        out.append(fill("landcover", source: "landcover", color: Palette.landcover))
        out.append(fill("landuse", source: "landuse", color: Palette.landuse))
        out.append(fill("water", source: "water", color: Palette.water))

        // Road casing under the fill gives roads a visible edge without
        // needing two colours per road class.
        out.append(line("roads-casing", source: "roads", color: Palette.roadCasing,
                        widths: [[4, 0.6], [8, 2.0], [12, 5.0], [16, 14.0]]))

        // Motorways and trunk roads read warmer than everything else —
        // these are the roads a touring route actually follows.
        out.append(line("roads-major", source: "roads", color: Palette.roadMajor,
                        widths: [[4, 0.4], [8, 1.4], [12, 3.6], [16, 10.0]],
                        filter: ["match", ["get", "kind"], ["highway", "major_road"], true, false]))

        out.append(line("roads-minor", source: "roads", color: Palette.roadMinor,
                        widths: [[8, 0.4], [12, 1.6], [16, 6.0]],
                        filter: ["match", ["get", "kind"], ["minor_road", "other", "path"], true, false]))

        out.append(line("boundaries", source: "boundaries", color: Palette.boundary,
                        widths: [[2, 0.4], [6, 0.8], [10, 1.4]],
                        dashed: true))

        return out
    }

    // MARK: - Layer helpers

    private static func fill(_ id: String, source: String, color: String) -> [String: Any] {
        [
            "id": id,
            "type": "fill",
            "source": "protomaps",
            "source-layer": source,
            "paint": ["fill-color": color],
        ]
    }

    /// `widths` is a list of `[zoom, width]` stops, turned into a MapLibre
    /// interpolate expression. Line widths have to grow with zoom or roads
    /// vanish when zoomed out and turn into slabs when zoomed in.
    private static func line(_ id: String,
                             source: String,
                             color: String,
                             widths: [[Double]],
                             filter: [Any]? = nil,
                             dashed: Bool = false) -> [String: Any] {
        var stops: [Any] = ["interpolate", ["linear"], ["zoom"]]
        for pair in widths {
            stops.append(pair[0])
            stops.append(pair[1])
        }

        var paint: [String: Any] = [
            "line-color": color,
            "line-width": stops,
        ]
        if dashed { paint["line-dasharray"] = [2.0, 2.0] }

        var layer: [String: Any] = [
            "id": id,
            "type": "line",
            "source": "protomaps",
            "source-layer": source,
            "layout": ["line-cap": "round", "line-join": "round"],
            "paint": paint,
        ]
        if let filter { layer["filter"] = filter }
        return layer
    }
}
