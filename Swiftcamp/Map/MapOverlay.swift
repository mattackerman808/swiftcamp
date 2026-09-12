import Foundation

/// What the map should be showing, as the exact bytes the renderer will be
/// handed.
///
/// A value type, `Equatable`, and pre-encoded on purpose. Two of those are
/// load-bearing:
///
/// **Equatable, so SwiftUI can see a change.** A representable does not
/// re-render when an `@Observable` property changes unless a value-type
/// mirror of that state is read in `body`. tachbase carries the scar comment
/// for this and restates the rule at its call site; the failure is a map that
/// silently never updates, which is expensive to diagnose because nothing
/// errors.
///
/// **Pre-encoded, so the comparison is cheap and exact.** `updateNSView` runs
/// on every SwiftUI invalidation, and a route being dragged invalidates
/// constantly. Comparing four strings decides whether to cross the bridge at
/// all, and `OverlayGeoJSON` encodes with sorted keys so identical content
/// really does produce identical bytes.
struct MapOverlay: Equatable {
    var sources: [String: String]

    static let empty = MapOverlay(sources: Dictionary(
        uniqueKeysWithValues: MapStyle.Overlay.all.map { ($0, emptyCollection) }))

    private static let emptyCollection = #"{"features":[],"type":"FeatureCollection"}"#

    /// Builds the overlay from library content.
    ///
    /// Encoding failures fall back to an empty collection rather than
    /// throwing. A route that cannot be encoded is a bug, but it is not worth
    /// taking the whole map down over, and the console bridge surfaces it.
    static func make(routes: [RouteDetail] = [],
                     tracks: [TrackDetail] = [],
                     waypoints: [Waypoint] = [],
                     selection: Set<String> = []) -> MapOverlay {
        func encode(_ collection: OverlayGeoJSON.FeatureCollection) -> String {
            (try? collection.json()) ?? emptyCollection
        }

        return MapOverlay(sources: [
            MapStyle.Overlay.trackLines: encode(OverlayGeoJSON.trackLines(tracks)),
            MapStyle.Overlay.routeLines: encode(OverlayGeoJSON.routeLines(routes)),
            MapStyle.Overlay.viaPoints: encode(OverlayGeoJSON.viaPoints(routes, selected: selection)),
            MapStyle.Overlay.waypoints: encode(OverlayGeoJSON.waypoints(waypoints, selected: selection)),
        ])
    }

    /// Only the sources whose content differs, so a drag that moves one via
    /// point does not resend every track in the library.
    func changes(from previous: MapOverlay) -> [String: String] {
        sources.filter { previous.sources[$0.key] != $0.value }
    }
}

/// Something the user clicked on the map.
///
/// `routeID` and `seq` together identify a via point. The database row id is
/// deliberately not used: saving a route rewrites every one of its points, so
/// a row id is not stable across the edit that a click usually precedes.
struct MapClick: Equatable {
    enum Target: Equatable {
        case viaPoint(routeID: String, seq: Int)
        case routeLine(routeID: String)
        case waypoint(id: String)
        case track(id: String)
        /// Empty map. The coordinate is still meaningful — this is how a new
        /// via point gets placed.
        case ground
    }

    var coordinate: Coordinate
    var target: Target
}
