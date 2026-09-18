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
/// Land fills first (world, then the detailed streets fills painting over
/// them), then the two terrain layers, then water, then roads and
/// boundaries. Putting the terrain layers below the streets fills would
/// hide them entirely, since those fills are opaque.
///
/// Water sits *above* the terrain layers rather than with the other fills.
/// The DEM reads sea level across every lake and ocean, so a hypsometric
/// ramp drawn over water tints it with the low end of the elevation scale
/// and a shaded lake surface picks up relief it does not have. Painting
/// water last leaves it flat, which is also how a paper topo sheet reads.
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
    static func json(bundledURL: String, glyphsURL: String, spriteURL: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: dictionary(bundledURL: bundledURL, glyphsURL: glyphsURL, spriteURL: spriteURL),
                                              options: [.prettyPrinted])
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return text
    }

    /// Writes the style to a temp file and returns its URL, because
    /// MapLibre Native takes a style *URL* rather than a string.
    static func write(bundledURL: String, glyphsURL: String, spriteURL: String) throws -> URL {
        let data = try JSONSerialization.data(withJSONObject: dictionary(bundledURL: bundledURL, glyphsURL: glyphsURL, spriteURL: spriteURL),
                                              options: [.prettyPrinted])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftcamp-style.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func dictionary(bundledURL: String, glyphsURL: String, spriteURL: String) -> [String: Any] {
        [
            "version": 8,
            "name": "Swiftcamp Base",
            "glyphs": glyphsURL,
            "sprite": spriteURL,
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
            ].merging(overlaySources()) { a, _ in a },
            "layers": layers(),
        ]
    }

    // MARK: - Overlay

    /// Names of the GeoJSON sources the library's contents are pushed into.
    ///
    /// Declared in the style with no features rather than added at runtime.
    /// Layer order in this file is load-bearing, and an empty source costs
    /// nothing, so declaring them here fixes where the route sits relative to
    /// the roads and the labels once, instead of leaving it to whatever order
    /// the host happens to add layers in.
    ///
    /// At runtime the only operation is replacing the data, which is one call
    /// rather than a layer-management problem.
    enum Overlay {
        static let trackLines = "sc-track-lines"
        static let routeLines = "sc-route-lines"
        static let viaPoints  = "sc-via-points"
        static let waypoints  = "sc-waypoints"
        /// The one place a search landed on, until it is saved or dismissed.
        static let search     = "sc-search"

        static let all = [trackLines, routeLines, viaPoints, waypoints, search]
    }

    private static func overlaySources() -> [String: Any] {
        let empty: [String: Any] = ["type": "FeatureCollection", "features": []]
        return Dictionary(uniqueKeysWithValues: Overlay.all.map { id in
            var source: [String: Any] = ["type": "geojson", "data": empty]
            if id == Overlay.routeLines {
                // A cross-country route is 13,000 vertices, and every push
                // of it, which a drag makes many times a second, is re-tiled
                // by the page on its own thread: 300 ms to idle, measured.
                // Three dials cut that work without touching the stored
                // geometry: stop tiling at z14 and overzoom the rest, where
                // a line is still a line; simplify to three quarters of a
                // pixel rather than three eighths, under the seven-pixel
                // stroke; and halve the tile buffer, which for a thin line
                // is mostly empty.
                source["maxzoom"] = 14
                source["tolerance"] = 0.75
                source["buffer"] = 64
            }
            return (id, source)
        })
    }

    // MARK: - Palette

    // Muted enough that a magenta route line drawn on top stays the
    // loudest thing on screen. Touring routes are the subject; the
    // basemap is context.
    private enum Palette {
        static let background = "#f5f3ee"
        static let earth      = "#f5f3ee"
        static let water      = "#b9d9e8"

        // Ground cover. Green enough to read as terrain rather than paper,
        // desaturated enough that none of it competes with a route line.
        // These are the only saturated colours on the map that cover large
        // areas, so they are the easiest thing here to overdo.
        static let forest      = "#d4e2c2"
        static let park        = "#dcecd2"
        static let grass       = "#e7edd6"
        static let scrub       = "#e0e4c9"
        static let farmland    = "#f0ebd9"
        static let wetland     = "#d9e7e2"
        static let sand        = "#f3ecd6"
        static let bareRock    = "#dfdcd6"
        static let glacier     = "#eef4f7"
        static let urban       = "#edeae4"
        static let institution = "#efece5"
        static let boundary   = "#9a9a9a"
        static let roadMinor  = "#ffffff"
        static let roadMajor  = "#fdf3d8"
        static let roadCasing      = "#d8d2c4"
        static let roadMajorCasing = "#e8c77a"
        // Distinct enough from `earth` to read as built form rather than
        // ground. At z13 a downtown block is mostly building, so too little
        // contrast here and the city looks like an empty field.
        static let building        = "#dcd5c8"
        // The overlay. Everything above is context; these are the subject,
        // and the basemap was kept muted so they can be.
        static let routeLine       = "#e0218a"
        static let routeCasing     = "#ffffff"
        static let trackLine       = "#1f7a8c"
        static let viaFill         = "#ffffff"
        static let waypointFill    = "#f5a623"
        static let searchPin       = "#d62828"
        static let selection       = "#111111"

        static let label           = "#40464e"
        static let labelHalo       = "#f7f5f0"
        static let roadLabel       = "#5d6470"
        static let shieldText      = "#3d3226"
        static let track           = "#b9ab92"
        static let path            = "#cfc9bd"
    }

    // MARK: - Ground cover

    /// Colour per `kind`, shared by the `landcover` and `landuse` layers.
    ///
    /// The two layers key off the same vocabulary — `forest`, `grassland`,
    /// `scrub` and `farmland` all appear in both — so one table serves both
    /// and they cannot drift apart at the zoom where one hands over to the
    /// other.
    ///
    /// Grouped by colour rather than listed per kind because the interesting
    /// question at a glance is which kinds share a treatment. `wood` and
    /// `forest` are the same green on purpose: OSM uses `natural=wood` for
    /// the trees and `landuse=forest` for the managed boundary around them,
    /// and in the western US a National Forest is tagged the second way, so
    /// splitting them would colour the Rockies by land ownership.
    private static let landKinds: [(color: String, kinds: [String])] = [
        (Palette.forest,      ["forest", "wood"]),
        (Palette.park,        ["park", "nature_reserve", "protected_area",
                               "recreation_ground", "garden", "village_green", "allotments"]),
        (Palette.grass,       ["grassland", "meadow", "grass", "pitch", "golf_course"]),
        (Palette.scrub,       ["scrub", "heath"]),
        (Palette.farmland,    ["farmland", "orchard", "vineyard"]),
        (Palette.wetland,     ["wetland", "marsh", "swamp", "mud"]),
        (Palette.sand,        ["sand", "beach", "dune"]),
        (Palette.bareRock,    ["bare_rock", "barren", "scree", "quarry"]),
        (Palette.glacier,     ["glacier", "snow", "ice"]),
        (Palette.urban,       ["residential", "commercial", "industrial", "retail", "urban_area"]),
        (Palette.institution, ["school", "university", "college", "hospital",
                               "cemetery", "military", "aerodrome", "airfield", "dam", "pier"]),
    ]

    /// `landKinds` flattened into a MapLibre `match` expression.
    ///
    /// Unrecognised kinds fall through to `earth`, so they paint nothing
    /// visible. Protomaps introduces kinds between planet builds, and a
    /// loud default would make the next new one look like a rendering bug
    /// rather than a gap in this table.
    private static func landKindColor() -> [Any] {
        var out: [Any] = ["match", ["get", "kind"]]
        for (color, kinds) in landKinds {
            out.append(kinds)
            out.append(color)
        }
        out.append(Palette.earth)
        return out
    }

    /// Builds the `match` expression mapping a shield to its numeral
    /// colour. Flattened from `ShieldCatalog` so the colours travel with the
    /// generated sprite sheet instead of being restated here.
    private static func shieldTextColor(_ shieldBase: [Any]) -> [Any] {
        var out: [Any] = ["match", shieldBase]
        for (name, hex) in ShieldCatalog.textColors.sorted(by: { $0.key < $1.key }) {
            out.append(name)
            out.append(hex)
        }
        out.append("#1d1d1d")
        return out
    }

    /// Halo colour per shield: the opposite of its numeral colour, which
    /// approximates the shield's own background. Derived from the catalog
    /// rather than listed separately so it cannot fall out of step.
    private static func shieldHaloColor(_ shieldBase: [Any]) -> [Any] {
        var out: [Any] = ["match", shieldBase]
        for (name, hex) in ShieldCatalog.textColors.sorted(by: { $0.key < $1.key }) {
            out.append(name)
            out.append(isLight(hex) ? "#1d1d1d" : "#ffffff")
        }
        out.append("#ffffff")
        return out
    }

    /// Relative luminance of a `#rrggbb` string, used only to decide which
    /// way round a halo goes.
    private static func isLight(_ hex: String) -> Bool {
        let h = hex.dropFirst()
        guard h.count == 6, let v = Int(h, radix: 16) else { return false }
        let r = Double((v >> 16) & 0xff) / 255
        let g = Double((v >> 8) & 0xff) / 255
        let b = Double(v & 0xff) / 255
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) > 0.5
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
        out.append(fill("world-landcover", src: "world", layer: "landcover", color: landKindColor(),
                        maxZoom: worldLayerMaxZoom, opacity: landcoverFade(to: worldLayerMaxZoom)))
        out.append(fill("world-landuse", src: "world", layer: "landuse", color: landKindColor(), maxZoom: worldLayerMaxZoom))

        // Streamed detail, painting over the bundled fills where it exists.
        out.append(fill("earth", src: "streets", layer: "earth", color: Palette.earth))
        out.append(fill("landcover", src: "streets", layer: "landcover", color: landKindColor(),
                        opacity: landcoverFade(to: 8)))
        out.append(fill("landuse", src: "streets", layer: "landuse", color: landKindColor()))

        // Elevation tint and relief, in that order, over the land fills and
        // under the water.
        out.append(colorRelief())
        out.append(hillshade())

        // Water carries BOTH polygons (lakes, reservoirs, riverbanks) and
        // linestrings (stream and river centrelines) in the same layer.
        // Filling a linestring makes MapLibre close the path, which turns a
        // creek into an enormous blob following its course — this is what
        // produced the phantom blue bands across Campbell and Saratoga.
        // Fill polygons only; draw the centrelines as lines below.
        out.append(fill("world-water", src: "world", layer: "water", color: Palette.water, maxZoom: worldLayerMaxZoom,
                        filter: ["==", ["geometry-type"], "Polygon"]))
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
        //
        // Class matters as much as width. `path` covers sidewalks, footways
        // and pedestrian crossings, which in most US suburbs are mapped
        // separately and run parallel to every street. Drawing them at
        // residential width made each road look doubled or tripled. They
        // now get their own deliberately faint treatment, far down this
        // list, and never enter the casing layers.
        let residential = ["residential", "unclassified", "living_street"]
        let major = ["highway", "major_road"]

        out.append(line("roads-minor-casing", src: "streets", layer: "roads", color: Palette.roadCasing,
                        widths: [[11, 1.4], [13, 2.8], [15, 6.0], [17, 13.0]],
                        filter: ["all", ["==", ["get", "kind"], "minor_road"],
                                 ["match", ["get", "kind_detail"], residential, true, false]]))
        out.append(line("roads-minor", src: "streets", layer: "roads", color: Palette.roadMinor,
                        widths: [[11, 0.6], [13, 1.6], [15, 4.0], [17, 10.0]],
                        filter: ["all", ["==", ["get", "kind"], "minor_road"],
                                 ["match", ["get", "kind_detail"], residential, true, false]]))

        // Service roads: driveways, alleys, parking aisles. Real vehicle
        // ways, so they stay solid, but at roughly half width so they read
        // as subordinate rather than as more streets.
        out.append(line("roads-service", src: "streets", layer: "roads", color: Palette.roadMinor,
                        widths: [[14, 0.8], [16, 2.2], [18, 5.0]],
                        filter: ["all", ["==", ["get", "kind"], "minor_road"],
                                 ["==", ["get", "kind_detail"], "service"]],
                        minZoom: 14))

        // Motorways and trunk roads read warmer than everything else —
        // these are the roads a touring route actually follows.
        out.append(line("roads-major-casing", src: "streets", layer: "roads", color: Palette.roadMajorCasing,
                        widths: [[6, 1.6], [10, 3.2], [13, 6.5], [16, 16.0], [18, 30.0]],
                        filter: ["match", ["get", "kind"], major, true, false]))
        out.append(line("roads-major", src: "streets", layer: "roads", color: Palette.roadMajor,
                        widths: [[6, 0.8], [10, 2.0], [13, 4.5], [16, 12.0], [18, 24.0]],
                        filter: ["match", ["get", "kind"], major, true, false]))

        // Unpaved tracks. Kept visible from a regional zoom and styled
        // distinctly because on a touring map they are a route option, not
        // clutter — a dual-sport rider wants to see them.
        out.append(line("roads-track", src: "streets", layer: "roads", color: Palette.track,
                        widths: [[12, 0.6], [15, 1.4], [18, 3.0]],
                        filter: ["all", ["==", ["get", "kind"], "path"],
                                 ["==", ["get", "kind_detail"], "track"]]))

        // Sidewalks, footways, crossings. Deliberately faint and late —
        // pedestrian infrastructure is not what this map is for, but it
        // does help orient inside a town centre.
        out.append(line("roads-path", src: "streets", layer: "roads", color: Palette.path,
                        widths: [[16, 0.5], [18, 1.4]],
                        filter: ["all", ["==", ["get", "kind"], "path"],
                                 ["!=", ["get", "kind_detail"], "track"]]))

        out.append(line("boundaries", src: "streets", layer: "boundaries", color: Palette.boundary,
                        widths: [[2, 0.4], [6, 0.8], [10, 1.4]],
                        dashed: true))

        // Lines go under the labels: a route is the subject, but a place
        // name it happens to cross should still be readable.
        out.append(contentsOf: overlayLineLayers())

        out.append(contentsOf: labelLayers())

        // Points go over everything, including labels. A via point hidden
        // behind a street name is one the user cannot grab.
        out.append(contentsOf: overlayPointLayers())

        return out
    }

    /// Track and route lines, each drawn casing-then-stroke like the roads.
    ///
    /// The casing is what keeps a magenta line legible where it runs along a
    /// road of similar width, which on a touring map is most of the time.
    private static func overlayLineLayers() -> [[String: Any]] {
        [
            // Tracks first, so a route planned from a recorded track draws
            // on top of it rather than disappearing underneath.
            geoJSONLine("track-line", source: Overlay.trackLines,
                        color: ["coalesce", ["get", "color"], Palette.trackLine],
                        widths: [[6, 1.2], [11, 2.4], [16, 4.5]]),

            geoJSONLine("route-casing", source: Overlay.routeLines,
                        color: Palette.routeCasing,
                        widths: [[6, 4.0], [11, 7.0], [16, 12.0]]),
            geoJSONLine("route-line", source: Overlay.routeLines,
                        color: ["coalesce", ["get", "color"], Palette.routeLine],
                        widths: [[6, 2.0], [11, 4.0], [16, 7.0]]),
        ]
    }

    private static func overlayPointLayers() -> [[String: Any]] {
        [
            geoJSONCircle("waypoint-dot", source: Overlay.waypoints,
                          fill: Palette.waypointFill,
                          radii: [[6, 3.0], [11, 5.0], [16, 7.0]]),

            // Where a search landed. Larger than a waypoint and red, and
            // deliberately not among the layers a click hit-tests: a
            // right-click on it falls through to empty map, whose menu
            // already starts a route or drops a point exactly there.
            geoJSONCircle("search-pin", source: Overlay.search,
                          fill: Palette.searchPin,
                          stroke: Palette.viaFill,
                          radii: [[6, 5.0], [11, 8.0], [16, 10.0]]),

            // Via points read as handles rather than as places: white with a
            // route-coloured ring, and larger, because they are the thing the
            // user aims at with a cursor. A shaping point is the same handle
            // drawn smaller and solid in the route's colour, so a stop and a
            // bend in the road read differently at a glance. One layer for
            // both, because the hit test names layers and a point is a point
            // whichever kind it is.
            [
                "id": "via-point",
                "type": "circle",
                "source": Overlay.viaPoints,
                "paint": [
                    // Zoom may only drive the outermost expression, so the
                    // kind is decided at each stop rather than around them.
                    "circle-radius": ["interpolate", ["linear"], ["zoom"],
                                      6, byKind(via: 3.5, shaping: 2.0),
                                      11, byKind(via: 6.0, shaping: 3.5),
                                      16, byKind(via: 8.0, shaping: 4.5)],
                    "circle-color": byKind(via: Palette.viaFill,
                                           shaping: ["coalesce", ["get", "color"], Palette.routeLine]),
                    "circle-stroke-width": byKind(via: 2.0, shaping: 1.5),
                    "circle-stroke-color": byKind(via: ["coalesce", ["get", "color"], Palette.routeLine],
                                                  shaping: Palette.viaFill),
                ],
            ],

            // Selection is a property on the feature rather than a separate
            // source, so selecting something is a data push and never a layer
            // change.
            [
                "id": "via-point-selected",
                "type": "circle",
                "source": Overlay.viaPoints,
                "filter": ["==", ["coalesce", ["get", "selected"], false], true],
                "paint": [
                    "circle-radius": interpolate([[6, 6.0], [11, 9.0], [16, 12.0]]),
                    "circle-color": "rgba(0, 0, 0, 0)",
                    "circle-stroke-width": 2.0,
                    "circle-stroke-color": Palette.selection,
                ],
            ],
        ]
    }

    // MARK: - Terrain

    /// Fades `landcover` out as `landuse` takes over.
    ///
    /// Protomaps splits ground cover across two layers at different depths:
    /// `landcover` is coarse and stops at z7, `landuse` is per-polygon and
    /// runs z2 to z15. Colouring both and leaving it there makes every
    /// forest in view blink out of existence on the step from z7 to z8,
    /// because `landcover` simply has no features in the deeper tiles — it
    /// is not a maxzoom that MapLibre can overzoom past, it is absence.
    ///
    /// Fading from z6 hands the ground over gradually while `landuse` is
    /// already drawing underneath, so nothing pops.
    private static func landcoverFade(to zoom: Double) -> [Any] {
        ["interpolate", ["linear"], ["zoom"], 6, 1.0, zoom, 0.0]
    }

    /// Hypsometric tint: ground colour by absolute elevation.
    ///
    /// Reads the same Terrarium DEM the hillshade does, so it costs no new
    /// tiles. `color-relief` is a recent layer type and the split backend
    /// makes "recent" a real risk, so this was checked against both shipped
    /// binaries before being used — MapLibre Native 6.29.0 and MapLibre GL
    /// JS 5.6.1 both carry it, along with every `hillshade-method` value.
    ///
    /// The ramp carries its own alpha rather than leaning on
    /// `color-relief-opacity`, so the low end is fully transparent and the
    /// `landuse` greens below show through unmodified. A flat opacity would
    /// wash a tan haze over farmland at sea level.
    ///
    /// Elevation is absolute, not relative to the surrounding terrain, so
    /// the High Plains read as high because they are: Denver starts at
    /// 1600 m. That is honest and it is what a paper topo does, but it is
    /// the first thing to reach for if the map looks too warm out east.
    private static func colorRelief() -> [String: Any] {
        [
            "id": "hypsometric",
            "type": "color-relief",
            "source": "terrain",
            "paint": [
                "color-relief-opacity": 1.0,
                "color-relief-color": ["interpolate", ["linear"], ["elevation"],
                                       0,    "rgba(255, 255, 255, 0)",
                                       400,  "rgba(232, 236, 198, 0.06)",
                                       1200, "rgba(226, 214, 166, 0.12)",
                                       2200, "rgba(214, 196, 160, 0.16)",
                                       3000, "rgba(202, 194, 184, 0.26)",
                                       3600, "rgba(216, 212, 208, 0.44)",
                                       4200, "rgba(248, 250, 252, 0.64)"],
            ],
        ]
    }

    /// Relief shading, over the tint and under the water.
    ///
    /// `igor` rather than the default `standard`. The standard method lights
    /// slopes toward white and shades them toward black, which drains the
    /// colour out of exactly the terrain the tint above exists to colour.
    /// Igor shades only, leaving lit ground at its own colour, which is why
    /// hand-drawn relief on paper maps looks the way it does.
    ///
    /// The highlight is therefore fully transparent. Leaving it opaque white
    /// under `igor` reintroduces the washing-out that choosing `igor` was
    /// meant to avoid.
    private static func hillshade() -> [String: Any] {
        [
            "id": "hillshade",
            "type": "hillshade",
            "source": "terrain",
            "paint": [
                "hillshade-method": "igor",
                "hillshade-exaggeration": 0.45,
                "hillshade-shadow-color": "#6a6350",
                "hillshade-highlight-color": "rgba(255, 255, 255, 0)",
            ],
        ]
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

        // Highway markers, drawn as authentic route shields.
        //
        // Artwork is openstreetmap-americana's (CC0), so California gets its
        // green spade, Colorado its flag, New Mexico the zia, Texas and
        // Nevada their state outlines. See `scripts/make_shields.py`.
        //
        // Shields are NOT stretched to fit their text. A 3-digit California
        // spade is a different shape from a 2-digit one, not the same shape
        // scaled, so every network ships `-2` and `-3` artwork and the style
        // picks on text length.
        //
        // `network` gives `US:I`, `US:US`, or `US:<state>` (sometimes with a
        // further suffix, e.g. `US:CO:E470`, hence the slice). The state
        // code is matched against a known list rather than concatenated
        // blind: an unrecognised code would name an image that does not
        // exist, and MapLibre answers a missing image by logging on every
        // frame rather than by failing once.
        let net: [Any] = ["get", "network"]
        let digits: [Any] = ["case", [">", ["length", ["get", "shield_text"]], 2], "3", "2"]
        let stateCode: [Any] = ["downcase", ["slice", net, 3, 5]]
        let isInterstate: [Any] = ["==", net, "US:I"]
        let isUSRoute: [Any] = ["==", net, "US:US"]

        // Resolved once and reused for both the image and its text colour,
        // so the two can never disagree about which shield is being drawn.
        let shieldBase: [Any] = ["case",
                                 isInterstate, "shield-interstate",
                                 isUSRoute, "shield-us",
                                 ["match", stateCode, ShieldCatalog.states,
                                  ["concat", "shield-", stateCode],
                                  "shield-plate"]]

        out.append([
            "id": "highway-shields",
            "type": "symbol",
            "source": "streets",
            "source-layer": "roads",
            "minzoom": 7,
            "filter": ["all",
                       ["has", "shield_text"],
                       ["match", ["get", "kind"], ["highway", "major_road"], true, false]],
            "layout": [
                "symbol-placement": "line",
                "icon-image": ["concat", shieldBase, "-", digits],
                "text-field": ["get", "shield_text"],
                "text-font": ["Noto Sans Bold"],
                "text-size": ["interpolate", ["linear"], ["zoom"], 7, 8.5, 13, 10.5],
                "symbol-spacing": 220,
                // Shields stay upright when the map rotates; a rotated route
                // marker is unreadable in a way a street name is not.
                "text-rotation-alignment": "viewport",
                "icon-rotation-alignment": "viewport",
                "text-pitch-alignment": "viewport",
                "icon-pitch-alignment": "viewport",
                "symbol-sort-key": ["case", isInterstate, 0.0, isUSRoute, 1.0, 2.0],
            ],
            "paint": [
                // Numeral colour per shield, from americana's own
                // definitions rather than inferred: Idaho's plate is black,
                // Minnesota's blue, California's spade green.
                "text-color": shieldTextColor(shieldBase),
                // A halo in the shield's own background colour, so a numeral
                // stays readable where it crosses a line in the artwork —
                // DC's diagonal and Oklahoma's panhandle both run straight
                // through where the number sits.
                "text-halo-color": shieldHaloColor(shieldBase),
                "text-halo-width": 0.9,
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

    /// `color` takes a hex string or a MapLibre expression, so a layer whose
    /// colour varies per feature needs no separate helper.
    private static func fill(_ id: String,
                             src: String,
                             layer: String,
                             color: Any,
                             maxZoom: Double? = nil,
                             opacity: Any? = nil,
                             filter: [Any]? = nil) -> [String: Any] {
        var paint: [String: Any] = ["fill-color": color]
        if let opacity { paint["fill-opacity"] = opacity }

        var out: [String: Any] = [
            "id": id,
            "type": "fill",
            "source": src,
            "source-layer": layer,
            "paint": paint,
        ]
        if let maxZoom { out["maxzoom"] = maxZoom }
        if let filter { out["filter"] = filter }
        return out
    }

    /// The existing `line` and `fill` helpers hardcode `source-layer`, which
    /// only vector tile sources have. A GeoJSON source has no sub-layers, so
    /// the overlay needs its own pair.
    private static func geoJSONLine(_ id: String,
                                    source: String,
                                    color: Any,
                                    widths: [[Double]]) -> [String: Any] {
        [
            "id": id,
            "type": "line",
            "source": source,
            "layout": ["line-cap": "round", "line-join": "round"],
            "paint": ["line-color": color, "line-width": interpolate(widths)],
        ]
    }

    private static func geoJSONCircle(_ id: String,
                                      source: String,
                                      fill: String,
                                      stroke: Any? = nil,
                                      radii: [[Double]]) -> [String: Any] {
        var paint: [String: Any] = [
            "circle-radius": interpolate(radii),
            "circle-color": fill,
        ]
        if let stroke {
            paint["circle-stroke-width"] = 2.0
            paint["circle-stroke-color"] = stroke
        }
        return ["id": id, "type": "circle", "source": source, "paint": paint]
    }

    /// One value for a via point and another for a shaping point, read off
    /// the handle's `via` property. Absent counts as via, which is also what
    /// a device assumes of an unmarked route point.
    private static func byKind(via: Any, shaping: Any) -> [Any] {
        ["case", ["==", ["get", "via"], false], shaping, via]
    }

    /// `[zoom, value]` stops as a MapLibre interpolate expression.
    private static func interpolate(_ stops: [[Double]]) -> [Any] {
        var out: [Any] = ["interpolate", ["linear"], ["zoom"]]
        for pair in stops {
            out.append(pair[0])
            out.append(pair[1])
        }
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
                             minZoom: Double? = nil,
                             dash: [Double]? = nil,
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
        if let dash { paint["line-dasharray"] = dash }
        else if dashed { paint["line-dasharray"] = [2.0, 2.0] }

        var out: [String: Any] = [
            "id": id,
            "type": "line",
            "source": src,
            "source-layer": layer,
            "layout": ["line-cap": "round", "line-join": "round"],
            "paint": paint,
        ]
        if let filter { out["filter"] = filter }
        if let minZoom { out["minzoom"] = minZoom }
        return out
    }
}
