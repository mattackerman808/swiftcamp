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
struct MapOverlay: Equatable, Sendable {
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
                     selection: Set<String> = [],
                     searchPin: SearchResult? = nil) -> MapOverlay {
        func encode(_ collection: OverlayGeoJSON.FeatureCollection) -> String {
            (try? collection.json()) ?? emptyCollection
        }

        return MapOverlay(sources: [
            MapStyle.Overlay.trackLines: encode(OverlayGeoJSON.trackLines(tracks)),
            MapStyle.Overlay.routeLines: encode(OverlayGeoJSON.routeLines(routes)),
            MapStyle.Overlay.viaPoints: encode(OverlayGeoJSON.handles(routes, selected: selection)),
            MapStyle.Overlay.waypoints: encode(OverlayGeoJSON.waypoints(waypoints, selected: selection)),
            MapStyle.Overlay.search: encode(OverlayGeoJSON.searchPin(searchPin)),
        ])
    }

    /// Only the sources whose content differs, so a drag that moves one via
    /// point does not resend every track in the library.
    func changes(from previous: MapOverlay) -> [String: String] {
        sources.filter { previous.sources[$0.key] != $0.value }
    }
}

/// Somewhere to move the map to.
///
/// Carries an `id` because this is a one-shot instruction, not a state the
/// map settles into. Selecting the same route twice should frame it twice,
/// and a plain `Equatable` value would compare equal the second time and do
/// nothing — which reads as the feature working intermittently.
struct MapCameraRequest: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case bounds(BoundingBox)
        /// A single point has no rectangle to fit, and fitting a degenerate
        /// one zooms to the renderer's maximum, which drops the user into a
        /// parking lot with no context.
        case point(Coordinate, zoom: Double)
    }

    var id: Int
    var target: Target
}

/// Something the user clicked on the map.
///
/// `routeID` and `seq` together identify a via point. The database row id is
/// deliberately not used: saving a route rewrites every one of its points, so
/// a row id is not stable across the edit that a click usually precedes.
struct MapClick: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case viaPoint(routeID: String, seq: Int)
        case routeLine(routeID: String)
        case waypoint(id: String)
        case track(id: String)
        /// The pin a search put down. There is only ever one, so it needs
        /// no id.
        case searchPin
        /// Empty map. The coordinate is still meaningful — this is how a new
        /// via point gets placed.
        case ground
    }

    var coordinate: Coordinate
    var target: Target
}

/// A via point, or the line itself, being dragged on the map.
///
/// `.begin` arrives once the pointer has moved far enough to be a drag and
/// says what was grabbed: via point `seq`, or the line when `seq` is nil,
/// which grows a new via point at `coordinate` and drags that — the Google
/// Maps gesture of pulling a route onto a different road. `.move` arrives
/// continuously and only updates what is drawn; `.end` arrives once and is
/// the edit. Writing the library on every mouse move would make a single
/// drag hundreds of transactions and hundreds of observation deliveries,
/// each of which re-renders the sidebar.
struct MapDrag: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case begin, move, end }

    var routeID: String
    var seq: Int?
    var coordinate: Coordinate
    var phase: Phase
}

/// One entry of the menu a right-click on the map puts up.
///
/// Data rather than a platform menu, so the model can say what applies to
/// what was hit without importing AppKit, and each host draws it natively.
/// On the Mac that is an `NSMenu`; a menu drawn inside the page would look
/// like a web page in a Mac app.
struct MapMenuItem {
    var title: String
    /// Ticked, for one of a set of choices.
    var isChecked = false
    /// A submenu. An item that has one runs nothing itself.
    var children: [MapMenuItem] = []
    /// A line between groups; nothing else on it means anything.
    var isSeparator = false
    var action: @MainActor () -> Void

    init(title: String, isChecked: Bool = false, action: @escaping @MainActor () -> Void) {
        self.title = title
        self.isChecked = isChecked
        self.action = action
    }

    init(title: String, children: [MapMenuItem]) {
        self.title = title
        self.children = children
        self.action = {}
    }

    static var separator: MapMenuItem {
        var item = MapMenuItem(title: "") {}
        item.isSeparator = true
        return item
    }

    /// The items that can be chosen, submenus opened, in menu order. For
    /// the harness, which names a choice rather than navigating to it.
    static func leaves(of items: [MapMenuItem]) -> [MapMenuItem] {
        items.flatMap { item -> [MapMenuItem] in
            if item.isSeparator { return [] }
            return item.children.isEmpty ? [item] : leaves(of: item.children)
        }
    }
}

/// A key the page saw and handed back, because the web view is first
/// responder whenever the mouse is over the map and SwiftUI's
/// `onDeleteCommand` never hears it.
enum MapKey: String, Sendable {
    case delete, escape
}

/// Synthetic input for the page, from `-SwiftcampScript`.
///
/// Debug affordance only. Nothing can drive a real click through a script
/// without Accessibility permission, so the harness dispatches DOM events
/// on the map canvas instead. They run through MapLibre's own hit testing
/// and the same handlers a real mouse reaches, which is what makes the
/// check worth anything; see `CLAUDE.md` on synthetic checks.
///
/// Carries an `id` for the same reason `MapCameraRequest` does: two
/// identical clicks in a row are two clicks.
struct MapPageEvent: Equatable, Sendable {
    var id: Int
    var kind: String
    var lon: Double = 0
    var lat: Double = 0
    var toLon: Double = 0
    var toLat: Double = 0
    var key: String = ""
}
