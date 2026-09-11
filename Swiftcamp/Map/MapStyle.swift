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
    static func json(bundledURL: String, glyphsURL: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: dictionary(bundledURL: bundledURL, glyphsURL: glyphsURL),
                                              options: [.prettyPrinted])
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return text
    }

    /// Writes the style to a temp file and returns its URL, because
    /// MapLibre Native takes a style *URL* rather than a string.
    static func write(bundledURL: String, glyphsURL: String) throws -> URL {
        let data = try JSONSerialization.data(withJSONObject: dictionary(bundledURL: bundledURL, glyphsURL: glyphsURL),
                                              options: [.prettyPrinted])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftcamp-style.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func dictionary(bundledURL: String, glyphsURL: String) -> [String: Any] {
        [
            "version": 8,
            "name": "Swiftcamp Base",
            "glyphs": glyphsURL,
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
        static let label           = "#40464e"
        static let labelHalo       = "#f7f5f0"
        static let roadLabel       = "#5d6470"
        static let shieldText      = "#3d3226"
    }

    /// Zoom at which the bundled world layers stop drawing.
    ///
    /// One past the bundled archive's own depth of 6, so it stays visible
    /// for the whole range it actually has data for and no further.
    private static let worldLayerMaxZoom: Double = 7

    private static func layers() -> [[String: Any]] {
        var out: [[String: Any]] = []

        out.append([
            "id": "background",
            "type": "background",
            "paint": ["background-color": Palette.background],
        ])

        // Bundled world, the only thing visible outside the streamed bounds.
        //
        // Capped at `worldLayerMaxZoom`. The bundled archive only goes to
        // z6, and MapLibre overzooms past a source's depth rather than
        // dropping it — so without this cap, z6 coastline geometry gets
        // magnified several hundred times and smears across the detailed
        // map as huge diagonal blue bands where there is no water at all.
        // Above the cap the streamed archive is the only thing drawing.
        out.append(fill("world-earth", src: "world", layer: "earth", color: Palette.earth, maxZoom: worldLayerMaxZoom))
        out.append(fill("world-landcover", src: "world", layer: "landcover", color: Palette.landcover, maxZoom: worldLayerMaxZoom))
        out.append(fill("world-landuse", src: "world", layer: "landuse", color: Palette.landuse, maxZoom: worldLayerMaxZoom))
        out.append(fill("world-water", src: "world", layer: "water", color: Palette.water, maxZoom: worldLayerMaxZoom,
                        filter: ["==", ["geometry-type"], "Polygon"]))

        // Streamed detail, painting over the bundled fills where it exists.
        out.append(fill("earth", src: "streets", layer: "earth", color: Palette.earth))
        out.append(fill("landcover", src: "streets", layer: "landcover", color: Palette.landcover))
        out.append(fill("landuse", src: "streets", layer: "landuse", color: Palette.landuse))
        // Water carries BOTH polygons (lakes, reservoirs, riverbanks) and
        // linestrings (stream and river centrelines) in the same layer.
        // Filling a linestring makes MapLibre close the path, which turns a
        // creek into an enormous blob following its course — this is what
        // produced the phantom blue bands across Campbell and Saratoga.
        // Fill polygons only; draw the centrelines as lines below.
        out.append(fill("water", src: "streets", layer: "water", color: Palette.water,
                        filter: ["==", ["geometry-type"], "Polygon"]))

        // Stream and river centrelines, as lines. `min_zoom` is the
        // tileset's own hint for when a feature becomes appropriate to
        // show; honouring it keeps every irrigation ditch out of a
        // regional view.
        out.append(line("water-lines", src: "streets", layer: "water", color: Palette.water,
                        widths: [[10, 0.5], [13, 1.2], [16, 3.5]],
                        filter: ["all",
                                 ["==", ["geometry-type"], "LineString"],
                                 ["<=", ["coalesce", ["get", "min_zoom"], 0], ["zoom"]]]))

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

        out.append(contentsOf: labelLayers())

        return out
    }

    // MARK: - Labels

    /// Text layers, drawn last so nothing paints over them.
    ///
    /// Every one of these needs the `glyphs` URL set on the style; without
    /// it MapLibre silently renders no text at all rather than erroring.
    ///
    /// `text-field` uses the plain `name` rather than a localised
    /// `name:xx`. The tileset carries about 45 translations per feature,
    /// and picking one is a real decision about who the app is for, not a
    /// default to stumble into.
    private static func labelLayers() -> [[String: Any]] {
        var out: [[String: Any]] = []

        // Road names, laid along the line. Kept below place names: at a
        // junction the town matters more than the street.
        out.append([
            "id": "road-labels",
            "type": "symbol",
            "source": "streets",
            "source-layer": "roads",
            "minzoom": 12,
            "filter": ["all",
                       ["has", "name"],
                       ["match", ["get", "kind"],
                        ["highway", "major_road", "minor_road"], true, false]],
            "layout": [
                "symbol-placement": "line",
                "text-field": ["get", "name"],
                "text-font": ["Noto Sans Regular"],
                "text-size": ["interpolate", ["linear"], ["zoom"], 12, 9.0, 16, 12.0],
                "text-max-angle": 30,
                "text-padding": 4,
                // Repeat long streets so the name is never far off screen.
                "symbol-spacing": 260,
            ],
            "paint": [
                "text-color": Palette.roadLabel,
                "text-halo-color": Palette.labelHalo,
                "text-halo-width": 1.4,
            ],
        ])

        // Highway markers. The tileset carries `shield_text` (the bare
        // number) and `network` (e.g. US:I) alongside the full `ref`.
        // Real shields would need a sprite sheet keyed by network; the
        // number in bold with a heavy halo reads well enough without one
        // and costs no extra assets.
        out.append([
            "id": "highway-shields",
            "type": "symbol",
            "source": "streets",
            "source-layer": "roads",
            "minzoom": 7,
            "filter": ["all",
                       ["has", "shield_text"],
                       ["match", ["get", "kind"], ["highway"], true, false]],
            "layout": [
                "symbol-placement": "line",
                "text-field": ["get", "shield_text"],
                "text-font": ["Noto Sans Bold"],
                "text-size": ["interpolate", ["linear"], ["zoom"], 7, 10.0, 14, 13.0],
                "symbol-spacing": 200,
                "text-padding": 6,
                "text-rotation-alignment": "viewport",
                "text-pitch-alignment": "viewport",
            ],
            "paint": [
                "text-color": Palette.shieldText,
                "text-halo-color": "#ffffff",
                "text-halo-width": 2.6,
            ],
        ])

        // Place names. `population_rank` is the tileset's own importance
        // ordering, so it drives both size and which labels survive
        // collision — larger towns win, which is what a touring map wants.
        out.append([
            "id": "place-labels",
            "type": "symbol",
            "source": "streets",
            "source-layer": "places",
            "filter": ["all",
                       ["has", "name"],
                       ["match", ["get", "kind"],
                        ["locality", "region", "country"], true, false]],
            "layout": [
                "text-field": ["get", "name"],
                "text-font": ["Noto Sans Bold"],
                "text-size": ["interpolate", ["linear"], ["zoom"],
                              4, ["interpolate", ["linear"], ["get", "population_rank"], 0, 9.0, 15, 15.0],
                              12, ["interpolate", ["linear"], ["get", "population_rank"], 0, 11.0, 15, 22.0]],
                "text-max-width": 7,
                "text-padding": 6,
                "symbol-sort-key": ["-", 20, ["coalesce", ["get", "population_rank"], 0]],
            ],
            "paint": [
                "text-color": Palette.label,
                "text-halo-color": Palette.labelHalo,
                "text-halo-width": 1.8,
            ],
        ])

        return out
    }

    // MARK: - Layer helpers

    private static func fill(_ id: String,
                             src: String,
                             layer: String,
                             color: String,
                             maxZoom: Double? = nil,
                             filter: [Any]? = nil) -> [String: Any] {
        var out: [String: Any] = [
            "id": id,
            "type": "fill",
            "source": src,
            "source-layer": layer,
            "paint": ["fill-color": color],
        ]
        if let maxZoom { out["maxzoom"] = maxZoom }
        if let filter { out["filter"] = filter }
        return out
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
