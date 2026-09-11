import Foundation

/// Builds a MapLibre style JSON for the Protomaps basemap schema.
///
/// The same style feeds both platforms — MapLibre Native on iOS and
/// MapLibre GL JS on macOS — which is the whole reason the split-backend
/// plan is tolerable. Cartography is defined once here; only the host
/// view differs. Never fork this file per platform.
///
/// ## Three sources
///
/// - `world` — the bundled zoom 0–6 archive in the app bundle. Guarantees
///   something on screen with no network, and is the only thing that draws
///   outside the continental US.
/// - `streets` — the full-detail zoom 0–14 archive on our CDN, streamed by
///   byte range. Continental US only.
/// - `terrain` — Terrarium-encoded elevation on our CDN, feeding hillshade.
///   Continental US only.
///
/// Both remote sources are bounded, so MapLibre simply requests nothing
/// outside their bounds and the bundled world shows through. That is what
/// makes the offline tier and the streamed tier compose without a
/// "local or network" decision anywhere in the code.
///
/// ## Layer order is load-bearing
///
/// Fills first (world, then the detailed streets fills painting over them),
/// *then* hillshade, *then* roads and boundaries. Putting hillshade below
/// the streets fills would hide it entirely, since those fills are opaque.
///
/// **`places` and `pois` are not drawn.** Both are label layers, and text
/// needs a `glyphs` URL. Pointing that at a remote server would break the
/// offline guarantee the bundled archive exists to provide, so bundling a
/// glyph set (as tachbase-ios does under `Resources/Glyphs`) is the fix.
/// Deliberately deferred — it is the largest remaining visual gap.
enum MapStyle {
    /// The style as JSON text.
    ///
    /// macOS needs the string (it is injected into the web view before the
    /// page loads); iOS needs a file URL. Both come from here so there is
    /// exactly one definition of the cartography.
    static func json(bundledURL: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: dictionary(bundledURL: bundledURL),
                                              options: [.prettyPrinted])
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return text
    }

    /// Writes the style to a temp file and returns its URL, because
    /// MapLibre Native takes a style *URL* rather than a string.
    static func write(bundledURL: String) throws -> URL {
        let data = try JSONSerialization.data(withJSONObject: dictionary(bundledURL: bundledURL),
                                              options: [.prettyPrinted])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftcamp-style.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func dictionary(bundledURL: String) -> [String: Any] {
        [
            "version": 8,
            "name": "Swiftcamp Base",
            "sources": [
                "world": [
                    "type": "vector",
                    "url": bundledURL,
                    "attribution": BasemapSource.attribution,
                ],
                "streets": [
                    "type": "vector",
                    "url": BasemapSource.streetURL,
                    "attribution": BasemapSource.attribution,
                ],
                "terrain": [
                    "type": "raster-dem",
                    "url": BasemapSource.terrainURL,
                    // Mapterhorn ships Terrarium encoding at 512px. Getting
                    // either of these wrong yields a plausible-looking but
                    // completely wrong hillshade rather than an error.
                    "encoding": "terrarium",
                    "tileSize": 512,
                    "attribution": BasemapSource.terrainAttribution,
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
        static let roadCasing      = "#d8d2c4"
        static let roadMajorCasing = "#e8c77a"
        // Distinct enough from `earth` to read as built form rather than
        // ground. At z13 a downtown block is mostly building, so too little
        // contrast here and the city looks like an empty field.
        static let building        = "#dcd5c8"
    }

    private static func layers() -> [[String: Any]] {
        var out: [[String: Any]] = []

        out.append([
            "id": "background",
            "type": "background",
            "paint": ["background-color": Palette.background],
        ])

        // Bundled world, the only thing visible outside the streamed bounds.
        out.append(fill("world-earth", src: "world", layer: "earth", color: Palette.earth))
        out.append(fill("world-landcover", src: "world", layer: "landcover", color: Palette.landcover))
        out.append(fill("world-landuse", src: "world", layer: "landuse", color: Palette.landuse))
        out.append(fill("world-water", src: "world", layer: "water", color: Palette.water))

        // Streamed detail, painting over the bundled fills where it exists.
        out.append(fill("earth", src: "streets", layer: "earth", color: Palette.earth))
        out.append(fill("landcover", src: "streets", layer: "landcover", color: Palette.landcover))
        out.append(fill("landuse", src: "streets", layer: "landuse", color: Palette.landuse))
        out.append(fill("water", src: "streets", layer: "water", color: Palette.water))

        // Above every fill, below every road. Subtle on purpose: this is a
        // road-touring map, so relief is context for why a road bends, not
        // the subject.
        out.append([
            "id": "hillshade",
            "type": "hillshade",
            "source": "terrain",
            "paint": [
                "hillshade-exaggeration": 0.35,
                "hillshade-shadow-color": "#5a5048",
                "hillshade-highlight-color": "#ffffff",
            ],
        ])

        // Buildings sit above the fills and hillshade but below roads, so a
        // route line and the roads it follows stay readable across a dense
        // downtown block. Only present from z11 in the tileset.
        out.append(fill("buildings", src: "streets", layer: "buildings", color: Palette.building))

        // Roads are drawn casing-then-fill, minor classes first so majors
        // cross over them cleanly.
        //
        // The casing width must track its own fill width plus a couple of
        // pixels. An earlier version used one unfiltered casing layer at
        // motorway width beneath every road, which at z13 painted a solid
        // tan mass over the whole city and buried the street grid.
        let minor = ["minor_road", "other", "path"]
        let major = ["highway", "major_road"]

        out.append(line("roads-minor-casing", src: "streets", layer: "roads", color: Palette.roadCasing,
                        widths: [[11, 1.4], [13, 2.8], [15, 6.0], [17, 13.0]],
                        filter: ["match", ["get", "kind"], minor, true, false]))
        out.append(line("roads-minor", src: "streets", layer: "roads", color: Palette.roadMinor,
                        widths: [[11, 0.6], [13, 1.6], [15, 4.0], [17, 10.0]],
                        filter: ["match", ["get", "kind"], minor, true, false]))

        // Motorways and trunk roads read warmer than everything else —
        // these are the roads a touring route actually follows.
        out.append(line("roads-major-casing", src: "streets", layer: "roads", color: Palette.roadMajorCasing,
                        widths: [[6, 1.6], [10, 3.2], [13, 6.5], [16, 16.0], [18, 30.0]],
                        filter: ["match", ["get", "kind"], major, true, false]))
        out.append(line("roads-major", src: "streets", layer: "roads", color: Palette.roadMajor,
                        widths: [[6, 0.8], [10, 2.0], [13, 4.5], [16, 12.0], [18, 24.0]],
                        filter: ["match", ["get", "kind"], major, true, false]))

        out.append(line("boundaries", src: "streets", layer: "boundaries", color: Palette.boundary,
                        widths: [[2, 0.4], [6, 0.8], [10, 1.4]],
                        dashed: true))

        return out
    }

    // MARK: - Layer helpers

    private static func fill(_ id: String, src: String, layer: String, color: String) -> [String: Any] {
        [
            "id": id,
            "type": "fill",
            "source": src,
            "source-layer": layer,
            "paint": ["fill-color": color],
        ]
    }

    /// `widths` is a list of `[zoom, width]` stops, turned into a MapLibre
    /// interpolate expression. Line widths have to grow with zoom or roads
    /// vanish when zoomed out and turn into slabs when zoomed in.
    private static func line(_ id: String,
                             src: String,
                             layer: String,
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

        var out: [String: Any] = [
            "id": id,
            "type": "line",
            "source": src,
            "source-layer": layer,
            "layout": ["line-cap": "round", "line-join": "round"],
            "paint": paint,
        ]
        if let filter { out["filter"] = filter }
        return out
    }
}
