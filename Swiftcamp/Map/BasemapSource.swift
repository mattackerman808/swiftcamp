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
    /// ODbL obligation, not decoration. Must stay visible on the map.
    static let attribution = "© OpenStreetMap"

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
