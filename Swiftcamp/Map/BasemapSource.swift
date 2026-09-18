import Foundation

/// Where the basemap tiles come from.
///
/// Two tiers exist by design (see `docs/data-architecture.md`):
///
///   - **bundled** — `world-z6.pmtiles`, ~43 MB, cut from the Protomaps
///     planet build. Guarantees a map on first paint with no network and
///     no blank screen. Zoom 0–6 only, so it is continents and coastlines,
///     not streets.
///   - **remote** — the full-detail archive on our own R2 bucket, read by
///     HTTP range request as the user zooms in. Not wired up yet; the
///     bucket does not exist.
///
/// MapLibre Native has a PMTiles v3 reader compiled in, so both tiers are
/// the same kind of source and differ only by URL. There is no tile server
/// anywhere in this design.
enum BasemapSource {
    /// Our own R2 bucket, fronted by a Cloudflare custom domain.
    ///
    /// Never point this at an upstream provider. Protomaps retains only
    /// about a week of daily builds, so a shipping app aimed at their
    /// bucket breaks when one rotates, and it is their bandwidth.
    static let cdnBase = "https://cdn.swiftcamp.app"

    /// Archive filenames carry their build date on purpose.
    ///
    /// PMTiles is read as a long sequence of byte-range requests against
    /// one file — header, then directory pages, then tiles. Overwriting an
    /// archive in place while a client has it open means their next range
    /// lands at the same offset in a *different* file, and the reads come
    /// back corrupt. Publishing under a new name and switching the
    /// reference makes a refresh atomic from the client's point of view.
    ///
    /// `manifest.json` in the same bucket already carries these names,
    /// along with bounds and attribution, and is the eventual source of
    /// truth. Reading it at launch is deferred until the region picker
    /// needs it, so for now these must be kept in step with it by hand.
    static let streetArchive  = "street-z15-20260910.pmtiles"
    static let terrainArchive = "terrain-20260910.pmtiles"

    /// Deepest zoom the map will go to.
    ///
    /// The street archive stops at z15, which is as deep as the upstream
    /// Protomaps planet publishes. Past a vector tileset's maxzoom MapLibre
    /// overzooms — it magnifies the deepest tiles it has — and because
    /// vector geometry is quantised to a fixed grid inside each tile, that
    /// shows up as visibly stair-stepped building edges.
    ///
    /// Capping two levels past the data keeps some zoom headroom for
    /// inspecting a junction without ever reaching the depth where the
    /// quantisation is obvious. A route-planning app lives at z10-z15
    /// anyway.
    ///
    /// Raster basemaps do not have this problem, because every zoom level
    /// is pre-rendered; that is why tachbase's CARTO raster layers stayed
    /// crisp at z18 while its vector base was capped at z14 exactly like
    /// this one. Going deeper than the upstream tileset would mean either
    /// a raster layer (and a vendor back in the serving path) or generating
    /// our own tiles with Planetiler.
    static let maxZoom: Double = 17

    /// Full-detail street tiles, zoom 0-15, continental US.
    static var streetURL: String { "pmtiles://\(cdnBase)/\(streetArchive)" }

    /// Terrarium-encoded elevation, zoom 0-12, continental US, feeding the
    /// hillshade layer. MapLibre Native decodes terrarium natively, so this
    /// works identically on both platforms.
    static var terrainURL: String { "pmtiles://\(cdnBase)/\(terrainArchive)" }

    /// The Valhalla routing graph: one gzipped object per tile under a
    /// dated prefix, plus `index.json` listing them. Valhalla fetches each
    /// tile as a route first needs it and caches it on disk; the prefetcher
    /// fills the highway levels ahead of time. Gzipped, a tile is a third
    /// of the size, and `.gz` is a type Cloudflare caches at the edge by
    /// default, which the earlier single tar was too big for. Dated for the
    /// same reason as the archives, and doubly so here: the reader records
    /// the graph's build id beside its cache and refuses to mix tiles from
    /// a rebuilt one, so a new graph must be a new name.
    static let routingArchive = "graph-us-20260917"

    static var routingURL: String { "\(cdnBase)/\(routingArchive)" }

    /// The search index: `places.sqlite` for the whole country and one
    /// shard per 4° cell under `cells/`, built by `scripts/build-search.py`
    /// from the same extract as the graph. Dated like everything else.
    static let searchArchive = "search-us-20260918"

    /// The address index: one shard per 1° tile under `tiles/`, built by
    /// `scripts/build-addresses.py` from the National Address Database with
    /// OpenAddresses behind it. A new build is a new name, never the same
    /// one overwritten, so a cache keyed by this never holds a mix.
    static let addressArchive = "addresses-us-20260918b"
    static var addressURL: String { "\(cdnBase)/\(addressArchive)" }

    static var searchURL: String { "\(cdnBase)/\(searchArchive)" }

    /// ODbL obligation, not decoration. Must stay visible on the map.
    static let attribution = "© OpenStreetMap"

    /// Copernicus requires this exact notice wherever its DEM is shown,
    /// not a generic credit. Belongs on screen whenever terrain is visible.
    static let terrainAttribution = "© DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018 provided under COPERNICUS by the European Union and ESA"

    /// Bundled glyph directory, as a `file://` URL template.
    ///
    /// Label text needs a `glyphs` URL. Pointing it at a remote font server
    /// would break the offline guarantee the bundled archive exists to
    /// provide, so the ranges ship in the app: Noto Sans Regular and Bold,
    /// Latin plus Latin Extended, about 1.7 MB. SIL Open Font License.
    ///
    /// macOS does not use this — its web view cannot fetch `file://`, so it
    /// goes through `BundleSchemeHandler` instead.
    static var bundledGlyphsURL: String? {
        guard let root = Bundle.main.resourceURL else { return nil }
        return root.appendingPathComponent("glyphs", isDirectory: true)
            .absoluteString + "{fontstack}/{range}.pbf"
    }

    /// Bundled sprite sheet base URL, without extension.
    ///
    /// MapLibre appends `.json`/`.png` and the `@2x` variant itself, so the
    /// style gets the stem only. Sprites carry the highway shields; see
    /// `scripts/make_shields.py`.
    static var bundledSpriteURL: String? {
        guard let root = Bundle.main.resourceURL else { return nil }
        return root.appendingPathComponent("sprites/sprite").absoluteString
    }

    /// Name of the bundled archive, without extension.
    static let bundledName = "world-z6"

    /// On-disk location of the bundled archive.
    ///
    /// `Resources/` is a *folder reference* in `project.yml`, not a group,
    /// so the directory survives into the built bundle and the file lands
    /// at `Swiftcamp.app/basemap/world-z6.pmtiles` rather than at the
    /// bundle root. `Bundle.path(forResource:ofType:)` does not recurse,
    /// so the subdirectory has to be named explicitly. The root lookup is
    /// kept as a fallback in case the folder reference ever becomes a
    /// plain group.
    static var bundledFileURL: URL? {
        if let p = Bundle.main.path(forResource: bundledName, ofType: "pmtiles", inDirectory: "basemap") {
            return URL(fileURLWithPath: p)
        }
        if let p = Bundle.main.path(forResource: bundledName, ofType: "pmtiles") {
            return URL(fileURLWithPath: p)
        }
        return nil
    }

    /// The `pmtiles://` URL MapLibre reads the bundled archive through.
    ///
    /// MapLibre understands `pmtiles://` and `asset://`; the former wraps
    /// an ordinary URL, so a bundled file becomes `pmtiles://file:///…`.
    static var bundledURL: String? {
        guard let url = bundledFileURL else { return nil }
        return "pmtiles://" + url.absoluteString
    }
}
