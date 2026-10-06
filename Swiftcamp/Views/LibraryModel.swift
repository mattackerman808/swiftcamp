import Foundation
import GRDB
import Observation
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

/// What the window is showing: the library's contents, what is selected, and
/// the overlay derived from both.
///
/// Rows arrive through `ValueObservation`, so an edit made anywhere reaches
/// every view without anyone remembering to post a notification. tachbase
/// does the opposite and documents the two bugs it bought: a 4,000-per-second
/// update storm, and a change that kept the row count identical and therefore
/// never refreshed the list.
@Observable
@MainActor
final class LibraryModel {
    private(set) var lists: [LibraryList] = []
    private(set) var routes: [RouteDetail] = []
    private(set) var tracks: [TrackDetail] = []
    private(set) var waypoints: [Waypoint] = []

    /// What the sidebar lists: the library narrowed to the selected list
    /// and the typed filter, in the chosen order. Derived once when any
    /// of those change rather than in a view body, for the reason
    /// `summaries` gives: a body runs far more often than the data moves.
    private(set) var shownRoutes: [RouteDetail] = []
    private(set) var shownTracks: [TrackDetail] = []
    private(set) var shownWaypoints: [Waypoint] = []

    /// The list whose contents are shown, or nil for the whole collection.
    /// The map follows it too, as BaseCamp's does: with a few years of
    /// rides in the library, picking a list is how the map is decluttered.
    var selectedListID: String? {
        didSet {
            guard selectedListID != oldValue else { return }
            rebuildShown()
            rebuildOverlay()
        }
    }

    /// Words typed into the sidebar's filter field. Narrows the sidebar
    /// only, never the map: a route that vanished from the map as its
    /// name was typed would read as deleted.
    var filterText = "" {
        didSet { if filterText != oldValue { rebuildShown() } }
    }

    var sort: LibrarySort = LibrarySort(rawValue: UserDefaults.standard.string(forKey: LibrarySort.key) ?? "") ?? .name {
        didSet {
            guard sort != oldValue else { return }
            UserDefaults.standard.set(sort.rawValue, forKey: LibrarySort.key)
            rebuildShown()
        }
    }

    var sortDescending = UserDefaults.standard.bool(forKey: LibrarySort.descendingKey) {
        didSet {
            guard sortDescending != oldValue else { return }
            UserDefaults.standard.set(sortDescending, forKey: LibrarySort.descendingKey)
            rebuildShown()
        }
    }

    /// Lengths in metres, for the sort; built with `summaries`.
    @ObservationIgnored private var lengths: [String: Double] = [:]

    /// Where the map is looking, for a waypoint made from the menu bar
    /// rather than from a click on the map.
    @ObservationIgnored private var viewCenter: Coordinate?

    /// A waypoint being dragged on the map: where it is drawn between the
    /// press and the release. The library is written once, at the end.
    @ObservationIgnored private var waypointDrag: (id: String, to: Coordinate)?

    /// Whether there is anything to export.
    ///
    /// Stored, not computed, and that is the whole point. The File menu is
    /// declared in the `App`, so reading `routes`, `tracks` or `waypoints`
    /// from a command ties the scene graph to every library change — and a
    /// scene graph invalidated while it is being rebuilt recurses between
    /// `graphDidChange` and `scenesDidChange` until the stack runs out. That
    /// is a crash with no frame of ours anywhere in it. This flips twice in a
    /// session rather than on every edit.
    private(set) var hasContent = false

    var selection: Set<String> = [] {
        // Guarded against a no-op write. `List(selection:)` assigns through
        // this binding during layout, and `Set` assignment fires `didSet`
        // whether or not the value changed — so an unguarded rebuild here
        // publishes a new overlay, which invalidates the view, which lays
        // out again. That loop pegs the main thread and the window stops
        // answering events.
        didSet { if selection != oldValue { rebuildOverlay() } }
    }

    /// The map's input. A value, `Equatable`, rebuilt only when the content
    /// behind it changes — see `MapWebView` for why that matters.
    private(set) var overlay: MapOverlay = .empty

    /// Set while a file is being read or written. The window stays live and
    /// says what it is doing, rather than going grey and unresponsive.
    private(set) var isBusy = false

    /// Per-item counts and lengths, computed once when the rows change.
    ///
    /// Never in a view body. `TrackDetail.length` sorts every point and sums
    /// a haversine over all of them, and SwiftUI re-evaluates a row's body
    /// far more often than the data changes — so a recorded track turns
    /// scrolling the sidebar into seconds of work per frame.
    private(set) var summaries: [String: String] = [:]

    /// Distance from the start of its route to each point, keyed by the
    /// point's handle, for the sidebar's list of a route's points. Built
    /// with `summaries`, for the same reason.
    private(set) var pointSummaries: [String: String] = [:]

    /// Each track's statistics, computed with the summaries: the inspector
    /// shows them and the sidebar's length comes from the same pass.
    private(set) var trackStatistics: [String: TrackStatistics] = [:]

    /// Whether the open or save panel is up.
    ///
    /// On the model rather than in the view because the File menu and the
    /// toolbar both raise them, and a menu command lives in the `App` where
    /// a view's `@State` cannot be reached.
    var isImporting = false
    var isExporting = false

    /// Where to move the map next, or nil if it should stay put.
    private(set) var camera: MapCameraRequest?
    @ObservationIgnored private var nextCameraID = 0

    /// The last thing that went wrong, for the banner. Import failures are
    /// the common case and the user chose the file, so they are owed a
    /// reason rather than a silent no-op.
    var failure: String?

    /// The route being edited, if any. While set, a click on empty map adds
    /// a via point to it and its handles can be dragged.
    private(set) var editingRouteID: String?

    /// The drag in flight, if any. See `Drag`.
    @ObservationIgnored private var drag: Drag?

    /// The editor's state while a via point is being dragged.
    ///
    /// The library is written once, when the drag ends. Between mouse
    /// moves `points` is what the overlay draws, so the line follows the
    /// pointer without a transaction and an observation delivery per frame.
    ///
    /// The legs either side of the moving point are routed on every move,
    /// so the line follows the road under the pointer rather than going
    /// straight and snapping on release. Routing runs off the main actor,
    /// one pass at a time, and only the newest position is worth routing:
    /// `pending` holds it while a pass is in flight and the pass that lands
    /// starts the next. Positions between are never routed, which is what
    /// keeps a fast drag across a slow leg from queueing seconds of work
    /// that describe where the pointer no longer is.
    @MainActor private final class Drag {
        let routeID: String
        let seq: Int
        /// Whether the drag grew this via point, for the undo action's name.
        let inserted: Bool
        /// The route's points as the drag found them, the grown point included.
        let base: [RoutePoint]
        /// What the overlay draws: `base` with the point moved and its
        /// legs routed for `shapedFor`.
        var points: [RoutePoint]
        var shapedFor: Coordinate?
        var pending: Coordinate?
        var inFlight = false

        init(routeID: String, seq: Int, inserted: Bool, base: [RoutePoint]) {
            self.routeID = routeID
            self.seq = seq
            self.inserted = inserted
            self.base = base
            self.points = base
        }
    }

    /// Undo and redo for edits. Owned here rather than taken from the
    /// window, because the web view is first responder whenever the mouse
    /// is over the map and the responder chain's undo manager is then the
    /// web view's own, which knows nothing about routes.
    let undoManager: UndoManager = {
        // One group per edit, opened and closed by hand. Automatic grouping
        // closes a group when the run loop goes to sleep, and edits that
        // arrive as main-queue blocks — every message from the web view,
        // every awaited step — can run back to back without it waking, so
        // a whole session of clicks undid as one.
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }()

    private func registerUndo(_ actionName: String, _ handler: @escaping @MainActor (LibraryModel) -> Void) {
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { handler(model) }
        }
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
    }

    private let store: LibraryStore
    @ObservationIgnored private var cancellables: [AnyDatabaseCancellable] = []
    @ObservationIgnored private var overlayTask: Task<Void, Never>?

    /// Items an import just created, waiting for their rows to arrive so
    /// they can be framed. The write and the observation that reports it are
    /// separate events, so the ids are known before the geometry is.
    @ObservationIgnored private var pendingFocus: Set<String> = []

    /// Scripted input in flight, for the map to replay. See `MapPageEvent`.
    private(set) var pageEvent: MapPageEvent?

    /// Routes being routed in the background, for the sidebar.
    private(set) var routing: Set<String> = []

    /// The last narrative computed for each route, against the edit
    /// signature it was computed for. Computed, never stored; see
    /// `RouteDirections`. A failure is kept the same way so the pane can
    /// say why rather than spin.
    struct DirectionsEntry: Equatable {
        var key: String
        var directions: RouteDirections?
        var failure: String?
    }
    private(set) var directionsByRoute: [String: DirectionsEntry] = [:]

    /// Legs the engine refused, keyed by mode and both ends, so a leg with
    /// no road between its points is not asked again on every edit.
    @ObservationIgnored private var refusedLegs: Set<String> = []
    @ObservationIgnored private var reroutePending: Set<String> = []

    /// Fills the streamed graph's cache ahead of routes. Nil for a
    /// developer's local graph.
    let prefetch: RoutingPrefetch?

    /// The search field's state; see `SearchModel`.
    let search = SearchModel()

    /// Where the last chosen search result is, shown as a pin until it is
    /// saved as a waypoint or dismissed. Not in the library: a search is a
    /// look, and most looks are not kept.
    private(set) var searchPin: SearchResult?

    /// A rename asked for from the map, for the sidebar to open its field
    /// on. The sidebar owns the field, and a name typed into the list row
    /// is one place to rename rather than two.
    struct RenameRequest: Equatable {
        var id: String
        /// Distinguishes two requests for the same item.
        var token: Int
    }
    private(set) var renameRequest: RenameRequest?

    init(store: LibraryStore = LibraryStore()) {
        self.store = store
        if UserDefaults.standard.string(forKey: "SwiftcampRouting") == nil,
           let base = URL(string: BasemapSource.routingURL) {
            prefetch = RoutingPrefetch(base: base,
                                       cache: RoutingEngine.cacheDirectory(for: BasemapSource.routingArchive))
        } else {
            prefetch = nil
        }
        RoutingEngine.warm()
        // The gigabyte fill is for a real launch. A scratch run still warms
        // the tiles around what it edits, which is what a click check needs.
        if UserDefaults.standard.string(forKey: "SwiftcampLibrary") == nil {
            prefetch?.fillBackground()
        }
        observe()
        importAtLaunchIfRequested()
        runScriptIfRequested()
    }

    // MARK: - Scripted checks

    /// `-SwiftcampScript <path>` replays a list of editing actions at launch.
    ///
    /// Debug affordance, the companion of `-SwiftcampSnapshot`. Route editing
    /// is clicks and drags, and nothing can script those against a real
    /// window without Accessibility permission, so the check goes in through
    /// the front door instead: the page dispatches DOM events on its own
    /// canvas and everything from MapLibre's hit test onward is the real
    /// path. Actions are `newRoute`, `click`, `drag`, `hover`, `key`, `menu`,
    /// `mode`, `search`, `searchShow`, `searchSave`, `undo`, `redo`, `done`,
    /// `wait`, `probe` and `dump`, as JSON objects with an `action` key.
    /// `menu` right-clicks and chooses the item named in `choose`, which
    /// may sit in a submenu ("Flag, Red" under Change Icon); `mode`
    /// sets the routing mode in `value`; `search` types `query` into the
    /// field, `searchShow` picks the first result, `searchSave` keeps the
    /// pin as a waypoint.
    private func runScriptIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "SwiftcampScript"),
              let data = FileManager.default.contents(atPath: path),
              let steps = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return }

        Task { await run(steps) }
    }

    private func run(_ steps: [[String: Any]]) async {
        func number(_ key: String, _ step: [String: Any]) -> Double { (step[key] as? Double) ?? 0 }

        for step in steps {
            // Long enough for a click to cross the bridge, be written, come
            // back through the observation and reach the renderer.
            try? await Task.sleep(for: .milliseconds(500))

            switch step["action"] as? String {
            case "wait":
                try? await Task.sleep(for: .seconds(number("seconds", step)))
            case "newRoute":
                newRoute()
            case "undo":
                undoManager.undo()
            case "redo":
                undoManager.redo()
            case "done":
                finishEditing()
            case "search":
                // Types into the search field; results arrive on their
                // own schedule, so a `wait` follows in any script.
                search.query = step["query"] as? String ?? ""
            case "searchShow":
                if let first = search.results.first { show(first) }
            case "searchSave":
                saveSearchPin()
            case "newWaypoint":
                newWaypoint(at: Coordinate(lat: number("lat", step), lon: number("lon", step)))
            case "importBaseCamp":
                importBaseCampLibrary()
            case "addPoint":
                // Straight into the model, past the page: for checking
                // routing while another copy of the app holds the only
                // window, when a click has nothing to land on.
                appendPoint(Coordinate(lat: number("lat", step), lon: number("lon", step)), isVia: true)
            case "addWaypoint":
                // The waypoint named into the route named, before point
                // `before` or at the end: the sidebar's drop, without the
                // sidebar.
                if let waypoint = waypoints.first(where: { $0.name == step["name"] as? String }),
                   let route = routes.first(where: { $0.route.name == step["route"] as? String }) {
                    addWaypoint(waypoint.id, toRoute: route.route.id, before: step["before"] as? Int)
                }
            case "directions":
                // The selected route's narrative, as the pane would ask
                // for it; waits for the routing in progress first.
                if let id = routes.first(where: { selection.contains($0.route.id) })?.route.id {
                    while routing.contains(id) { try? await Task.sleep(for: .milliseconds(200)) }
                    await loadDirections(for: id)
                }
            case "duplicate":
                duplicateSelection()
            case "invert":
                if let id = tracks.first(where: { selection.contains($0.track.id) })?.track.id { invertTrack(id) }
            case "split":
                if let id = tracks.first(where: { selection.contains($0.track.id) })?.track.id {
                    splitTrack(id, at: Coordinate(lat: number("lat", step), lon: number("lon", step)))
                }
            case "join":
                joinTracks(selection)
            case "simplify":
                if let id = tracks.first(where: { selection.contains($0.track.id) })?.track.id {
                    simplifyTrack(id, atMost: step["count"] as? Int ?? 10_000)
                }
            case "backup":
                if let path = step["path"] as? String { await backup(to: URL(fileURLWithPath: path)) }
            case "restore":
                if let path = step["path"] as? String { await restore(from: URL(fileURLWithPath: path)) }
            case "movePoint":
                // Point `from` of the route named to before the point now
                // at `to`, as a drag of the sidebar's rows reports it.
                if let route = routes.first(where: { $0.route.name == step["route"] as? String }),
                   let from = step["from"] as? Int, let to = step["to"] as? Int {
                    movePoints(routeID: route.route.id, fromOffsets: IndexSet(integer: from), toOffset: to)
                }
            case "select":
                // By name, any kind, or nothing with no name.
                let name = step["name"] as? String ?? ""
                selection = Set([routes.first { $0.route.name == name }?.route.id,
                                 tracks.first { $0.track.name == name }?.track.id,
                                 waypoints.first { $0.name == name }?.id].compactMap { $0 })
            case "rename":
                if let id = selection.first { rename(id, to: step["name"] as? String ?? "") }
            case "set":
                // A field of the selected item, as the inspector would
                // write it: comment, description, symbol, lat, lon,
                // elevation, color.
                setField(step["field"] as? String ?? "", to: step["value"])
            case "trackFromRoute":
                if let id = routes.first(where: { selection.contains($0.route.id) })?.route.id {
                    makeTrack(fromRoute: id)
                }
            case "routeFromTrack":
                if let id = tracks.first(where: { selection.contains($0.track.id) })?.track.id {
                    makeRoute(fromTrack: id)
                }
            case "newList":
                newList(in: (step["parent"] as? String).flatMap { name in lists.first { $0.name == name }?.id })
            case "deleteList":
                if let id = lists.first(where: { $0.name == step["name"] as? String })?.id { deleteList(id) }
            case "selectList":
                selectedListID = (step["name"] as? String).flatMap { name in lists.first { $0.name == name }?.id }
            case "file":
                // The selection into the list named, or out of any list.
                file(selection, in: (step["list"] as? String).flatMap { name in lists.first { $0.name == name }?.id })
            case "nest":
                if let id = lists.first(where: { $0.name == step["name"] as? String })?.id {
                    nest(id, under: (step["under"] as? String).flatMap { name in lists.first { $0.name == name }?.id })
                }
            case "filter":
                filterText = step["text"] as? String ?? ""
            case "sort":
                if let sort = (step["by"] as? String).flatMap(LibrarySort.init(rawValue:)) { self.sort = sort }
                sortDescending = step["descending"] as? Bool ?? false
            #if os(macOS)
            case "focusSearch":
                _ = Harness.focusSearchField()
            case "type":
                Harness.type(step["text"] as? String ?? "")
            case "snapshotWindows":
                if let path = step["path"] as? String { Harness.snapshotWindows(to: path) }
            case "menuBar":
                // A menu bar item by its titles, ["Window", "Transfer"].
                Harness.chooseMenuItem(step["path"] as? [String] ?? [])
            #endif
            case "mode":
                // On the route being edited, else the selected one.
                if let mode = (step["value"] as? String).flatMap(RoutingMode.init(rawValue:)),
                   let id = editingRouteID ?? routes.first(where: { selection.contains($0.route.id) })?.route.id {
                    setMode(mode, forRoute: id)
                }
            case "prefer", "avoid":
                // `prefer` names a preference; `avoid` lists the kinds.
                if let id = editingRouteID ?? routes.first(where: { selection.contains($0.route.id) })?.route.id,
                   var preferences = routes.first(where: { $0.route.id == id })?.route.preferences {
                    if let prefer = (step["value"] as? String).flatMap(RoutePreferences.Preference.init(rawValue:)) {
                        preferences.prefer = prefer
                    }
                    if let kinds = step["kinds"] as? [String] { preferences.setAvoided(kinds) }
                    setPreferences(preferences, forRoute: id)
                }
            case "click", "drag", "key", "probe", "menu", "hover":
                pageEvent = MapPageEvent(id: (pageEvent?.id ?? 0) + 1,
                                         kind: step["action"] as! String,
                                         lon: number("lon", step), lat: number("lat", step),
                                         toLon: number("toLon", step), toLat: number("toLat", step),
                                         key: step["key"] as? String ?? step["choose"] as? String ?? "")
            case "dump":
                if let path = step["path"] as? String {
                    dump(to: path, geometry: step["geometry"] as? Bool ?? false)
                }
            default:
                NSLog("[Swiftcamp] script: unknown step %@", String(describing: step))
            }
        }
    }

    /// The inspector's fields, for a script. Nil and an empty string both
    /// clear a text field.
    private func setField(_ field: String, to value: Any?) {
        let text = (value as? String).flatMap { $0.isEmpty ? nil : $0 }
        let number = value as? Double
        if let id = selection.first, var waypoint = waypoints.first(where: { $0.id == id }) {
            switch field {
            case "comment": waypoint.comment = text
            case "description": waypoint.descriptionText = text
            case "symbol": waypoint.symbol = text
            case "elevation": waypoint.elevation = number
            case "lat": if let number { waypoint.lat = number }
            case "lon": if let number { waypoint.lon = number }
            default: return
            }
            update(waypoint)
        } else if let id = selection.first, var route = routes.first(where: { $0.route.id == id })?.route {
            switch field {
            case "comment": route.comment = text
            case "color": route.color = text
            default: return
            }
            update(route)
        } else if let id = selection.first, var track = tracks.first(where: { $0.track.id == id })?.track {
            switch field {
            case "comment": track.comment = text
            case "color": track.color = text
            default: return
            }
            update(track)
        }
    }

    /// The library's routes as JSON, for a script to assert against.
    /// With `geometry`, each point also carries its leg's path as
    /// `[lon, lat]` pairs, so a check can find a coordinate on the line to
    /// grab. Off by default because a road leg is thousands of them.
    private func dump(to path: String, geometry: Bool = false) {
        let listNames = Dictionary(uniqueKeysWithValues: lists.map { ($0.id, $0.name) })
        let routes = self.routes.map { detail -> [String: Any] in
            ["name": detail.route.name,
             "editing": detail.route.id == editingRouteID,
             "list": detail.route.listID.flatMap { listNames[$0] } as Any,
             "comment": detail.route.comment as Any,
             "color": detail.route.color as Any,
             "mode": detail.route.mode.rawValue,
             "prefer": detail.route.preferences.prefer.rawValue,
             "avoid": detail.route.preferences.avoided,
             "miles": (detail.length / 1609.344 * 10).rounded() / 10,
             "directions": directionsByRoute[detail.route.id].map { entry -> [String: Any] in
                 ["failure": entry.failure as Any,
                  "miles": ((entry.directions?.length ?? 0) / 1609.344 * 10).rounded() / 10,
                  "minutes": ((entry.directions?.time ?? 0) / 60).rounded(),
                  "turns": (entry.directions?.maneuvers ?? []).map { m -> [String: Any] in
                      ["instruction": m.instruction, "kind": m.kind.rawValue, "leg": m.leg,
                       "miles": (m.distanceFromStart / 1609.344 * 10).rounded() / 10,
                       "lat": m.coordinate.lat, "lon": m.coordinate.lon]
                  }]
             } as Any,
             "points": detail.points.map { p -> [String: Any] in
                 var out: [String: Any] = ["seq": p.seq, "lat": p.lat, "lon": p.lon,
                                           "name": p.name ?? "", "via": p.isVia,
                                           "symbol": p.symbol as Any,
                                           "waypoint": p.waypointID.flatMap { id in waypoints.first { $0.id == id }?.name } as Any,
                                           "geometry": p.geometry?.count ?? 0]
                 if geometry { out["path"] = (p.geometry ?? []).map { [$0.lon, $0.lat] } }
                 return out
             }]
        }
        let payload: [String: Any] = ["routes": routes,
                                      "waypoints": waypoints.map { ["name": $0.name, "lat": $0.lat, "lon": $0.lon,
                                                                    "symbol": $0.symbol as Any,
                                                                    "comment": $0.comment as Any,
                                                                    "description": $0.descriptionText as Any,
                                                                    "elevation": $0.elevation as Any,
                                                                    "list": $0.listID.flatMap { listNames[$0] } as Any] },
                                      "tracks": tracks.map { ["name": $0.track.name, "points": $0.points.count,
                                                              "segments": $0.segments.count,
                                                              "first": $0.points.min { $0.seq < $1.seq }.map { [$0.lat, $0.lon] } as Any,
                                                              "stats": trackStatistics[$0.track.id].map { s in
                                                                  ["miles": (s.distance / 1609.344 * 10).rounded() / 10,
                                                                   "elapsed": s.elapsed as Any, "moving": s.moving as Any,
                                                                   "ascent": s.ascent as Any, "descent": s.descent as Any] } as Any,
                                                              "comment": $0.track.comment as Any,
                                                              "color": $0.track.color as Any,
                                                              "list": $0.track.listID.flatMap { listNames[$0] } as Any] },
                                      "lists": lists.map { ["name": $0.name,
                                                            "parent": $0.parentID.flatMap { listNames[$0] } as Any] },
                                      "selectedList": selectedListID.flatMap { listNames[$0] } as Any,
                                      "shown": ["routes": shownRoutes.map(\.route.name),
                                                "tracks": shownTracks.map(\.track.name),
                                                "waypoints": shownWaypoints.map(\.name)],
                                      "filter": filterText,
                                      "sort": sort.rawValue,
                                      "query": search.query,
                                      "search": search.results.map { ["name": $0.name, "detail": $0.detail, "kind": $0.kind.rawValue,
                                                                      "lat": $0.coordinate.lat, "lon": $0.coordinate.lon] },
                                      "pin": searchPin.map { ["name": $0.name, "lat": $0.coordinate.lat, "lon": $0.coordinate.lon] } as Any,
                                      "selection": Array(selection).sorted(),
                                      "canUndo": undoManager.canUndo,
                                      "canRedo": undoManager.canRedo]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// `-SwiftcampImport <path>` loads a GPX file at launch.
    ///
    /// Debug affordance, and the companion to `-SwiftcampSnapshot`: there is
    /// no way to drive a file picker from a script, so without this nothing
    /// automated can check that an imported route actually draws. Pair it
    /// with `-SwiftcampLibrary` so it lands in a scratch file — it imports on
    /// every launch, and against the real library that accumulates copies.
    private func importAtLaunchIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "SwiftcampImport") else { return }
        importGPX(from: URL(fileURLWithPath: path))
    }

    // MARK: - Observation

    private func observe() {
        // Routes and tracks are observed whole rather than as headers,
        // because the map needs their geometry and the sidebar needs their
        // length. Splitting them would mean two observations racing to
        // describe the same edit.
        track(ValueObservation.tracking { db in try Self.allRoutes(db) }) { [weak self] in
            self?.routes = $0
            self?.refreshHasContent()
            self?.rebuildSummaries()
            self?.rebuildShown()
            self?.rebuildOverlay()
            self?.applyPendingFocus()
        }
        track(ValueObservation.tracking { db in try Self.allTracks(db) }) { [weak self] in
            self?.tracks = $0
            self?.refreshHasContent()
            self?.rebuildSummaries()
            self?.rebuildShown()
            self?.rebuildOverlay()
            self?.applyPendingFocus()
        }
        track(store.observeWaypoints()) { [weak self] in
            self?.waypoints = $0
            self?.refreshHasContent()
            self?.rebuildShown()
            self?.rebuildOverlay()
            self?.applyPendingFocus()
        }
        track(store.observeLists()) { [weak self] in
            guard let self else { return }
            lists = $0
            // A list deleted from under the selection leaves the whole
            // collection showing, not an empty sidebar named after nothing.
            if let selectedListID, !lists.contains(where: { $0.id == selectedListID }) {
                self.selectedListID = nil
            }
            rebuildShown()
            rebuildOverlay()
        }
    }

    // MARK: - Lists, filter and order

    /// The lists inside `id`, itself included, however deep. A list in
    /// BaseCamp shows what its sublists hold as well as its own items.
    func listIDs(under id: String) -> Set<String> {
        var out: Set<String> = [id]
        var frontier = [id]
        while let parent = frontier.popLast() {
            for child in lists where child.parentID == parent && !out.contains(child.id) {
                out.insert(child.id)
                frontier.append(child.id)
            }
        }
        return out
    }

    /// The lists at the top, or inside one, in sidebar order.
    func lists(in parentID: String?) -> [LibraryList] {
        lists.filter { $0.parentID == parentID }
    }

    /// Whether an item filed in `listID` belongs on screen under the
    /// selected list.
    private func isShown(_ listID: String?) -> Bool {
        guard let selectedListID else { return true }
        guard let listID else { return false }
        return listIDs(under: selectedListID).contains(listID)
    }

    /// The routes, tracks and waypoints the map draws: the selected list's,
    /// or everything.
    private var mappedRoutes: [RouteDetail] { routes.filter { isShown($0.route.listID) } }
    private var mappedTracks: [TrackDetail] { tracks.filter { isShown($0.track.listID) } }
    private var mappedWaypoints: [Waypoint] { waypoints.filter { isShown($0.listID) } }

    private func rebuildShown() {
        let query = filterText
        let sort = self.sort, descending = sortDescending
        shownRoutes = LibraryOrder.sorted(
            mappedRoutes.filter { LibraryOrder.matches(query, $0.route.name, $0.route.comment) },
            by: sort, descending: descending,
            name: \.route.name, created: \.route.createdAt, updated: \.route.updatedAt,
            length: { self.lengths[$0.route.id] })
        shownTracks = LibraryOrder.sorted(
            mappedTracks.filter { LibraryOrder.matches(query, $0.track.name, $0.track.comment) },
            by: sort, descending: descending,
            name: \.track.name, created: \.track.createdAt, updated: \.track.updatedAt,
            length: { self.lengths[$0.track.id] })
        shownWaypoints = LibraryOrder.sorted(
            mappedWaypoints.filter { LibraryOrder.matches(query, $0.name, $0.comment, $0.descriptionText, $0.symbol) },
            by: sort, descending: descending,
            name: \.name, created: \.createdAt, updated: \.updatedAt, length: { _ in nil })
    }

    /// The list an item is in, for the sidebar's menu tick.
    func listID(of id: String) -> String? {
        routes.first { $0.route.id == id }?.route.listID
            ?? tracks.first { $0.track.id == id }?.track.listID
            ?? waypoints.first { $0.id == id }?.listID
    }

    /// Whether this id is a list.
    func isList(_ id: String) -> Bool { lists.contains { $0.id == id } }

    /// A new, empty list, named and ready to rename, at the top or inside
    /// another. Undo removes it; it held nothing yet.
    func newList(in parentID: String? = nil) {
        let taken = Set(lists.map(\.name))
        var n = lists.count + 1
        while taken.contains("List \(n)") { n += 1 }
        let list = LibraryList(name: "List \(n)", parentID: parentID, sortOrder: lists.count)
        do {
            try store.save(list)
        } catch {
            failure = error.localizedDescription
            return
        }
        registerUndo("New List") { model in model.deleteList(list.id) }
        lists.append(list)
        requestRename(list.id)
    }

    /// Removes a list and unfiles what it held; undo puts both back.
    func deleteList(_ id: String) {
        guard let list = lists.first(where: { $0.id == id }) else { return }
        let members = routes.filter { $0.route.listID == id }.map(\.route.id)
            + tracks.filter { $0.track.listID == id }.map(\.track.id)
            + waypoints.filter { $0.listID == id }.map(\.id)
        let children = lists.filter { $0.parentID == id }
        do {
            try store.deleteList(id: id)
        } catch {
            failure = error.localizedDescription
            return
        }
        if selectedListID == id { selectedListID = list.parentID }
        selection.remove(id)
        registerUndo("Delete List") { model in
            model.restore(list, members: members, children: children)
        }
    }

    private func restore(_ list: LibraryList, members: [String], children: [LibraryList]) {
        do {
            try store.save(list)
            try store.file(members, in: list.id)
            // Sublists cascade on delete, so they come back with it. Their
            // own contents do not: a nested list two deep is rare enough
            // that undo of its parent's deletion restoring it empty is a
            // known gap rather than a promise broken silently.
            for child in children { try store.save(child) }
        } catch {
            failure = error.localizedDescription
            return
        }
        registerUndo("Delete List") { model in model.deleteList(list.id) }
    }

    /// Files items into a list, or with nil out of any, undoably. Undo
    /// puts each back where it was, which may be several lists.
    func file(_ ids: Set<String>, in listID: String?) {
        let items = ids.filter { !isList($0) }
        let before = items.map { ($0, self.listID(of: $0)) }
        guard !items.isEmpty, before.contains(where: { $0.1 != listID }) else { return }
        do {
            try store.file(Array(items), in: listID)
        } catch {
            failure = error.localizedDescription
            return
        }
        let name = listID.flatMap { id in lists.first { $0.id == id }?.name }
        registerUndo(name.map { "Move to \($0)" } ?? "Remove from List") { model in
            for (id, previous) in before { model.file([id], in: previous) }
        }
    }

    /// Moves a list under another, or to the top. The store refuses a
    /// cycle, so dropping a list on its own descendant does nothing.
    func nest(_ id: String, under parentID: String?) {
        guard let list = lists.first(where: { $0.id == id }), list.parentID != parentID, id != parentID,
              parentID.map({ !listIDs(under: id).contains($0) }) ?? true else { return }
        do {
            try store.setParent(parentID, forList: id)
        } catch {
            failure = error.localizedDescription
            return
        }
        registerUndo("Move List") { model in model.nest(id, under: list.parentID) }
    }

    /// Only ever writes when the answer changes, so a menu bound to it is not
    /// invalidated by an edit that leaves the library non-empty.
    private func refreshHasContent() {
        let any = !routes.isEmpty || !tracks.isEmpty || !waypoints.isEmpty
        if any != hasContent { hasContent = any }
    }

    private func track<R: ValueReducer>(_ observation: ValueObservation<R>,
                                        onChange: @escaping @MainActor (R.Value) -> Void)
    where R.Value: Sendable {
        cancellables.append(observation.start(
            in: store.database.writer,
            scheduling: .async(onQueue: .main),
            onError: { [weak self] error in
                Task { @MainActor in self?.failure = error.localizedDescription }
            },
            onChange: { value in MainActor.assumeIsolated { onChange(value) } }))
    }

    private static func allRoutes(_ db: Database) throws -> [RouteDetail] {
        try Route.order(Column("name")).fetchAll(db).map { route in
            RouteDetail(route: route,
                        points: try RoutePoint
                            .filter(Column("route_id") == route.id)
                            .order(Column("seq"))
                            .fetchAll(db))
        }
    }

    private static func allTracks(_ db: Database) throws -> [TrackDetail] {
        try Track.order(Column("name")).fetchAll(db).map { track in
            TrackDetail(track: track,
                        points: try TrackPoint
                            .filter(Column("track_id") == track.id)
                            .order(Column("seq"))
                            .fetchAll(db))
        }
    }

    /// Rebuilds the overlay away from the main actor, and publishes it only
    /// if it differs.
    ///
    /// Encoding is proportional to the library: every point of every track
    /// becomes JSON. Doing that on the main thread is what turns importing a
    /// long ride into a frozen window. Publishing unconditionally is what
    /// turns a redundant rebuild into another round of view invalidation.
    private func rebuildOverlay() {
        var routes = mappedRoutes
        if let drag, let i = routes.firstIndex(where: { $0.route.id == drag.routeID }) {
            routes[i].points = drag.points
        }
        let tracks = mappedTracks
        var waypoints = mappedWaypoints
        if let waypointDrag, let i = waypoints.firstIndex(where: { $0.id == waypointDrag.id }) {
            waypoints[i].lat = waypointDrag.to.lat
            waypoints[i].lon = waypointDrag.to.lon
        }
        let selection = self.selection
        let searchPin = self.searchPin

        // Only the newest rebuild matters. Three observations can land in
        // quick succession on one import, and the first two describe a state
        // nobody will ever see.
        overlayTask?.cancel()
        overlayTask = Task {
            let started = ContinuousClock.now
            let built = await Task.detached(priority: .userInitiated) {
                MapOverlay.make(routes: routes, tracks: tracks,
                                waypoints: waypoints, selection: selection, searchPin: searchPin)
            }.value
            Timing.log("overlay.encode", since: started,
                       "\(built.sources.values.reduce(0) { $0 + $1.utf8.count } / 1000) KB")

            guard !Task.isCancelled else { return }
            if built != overlay { overlay = built }
        }
    }

    /// Row subtitles, recomputed only when the rows themselves change.
    private func rebuildSummaries() {
        let started = ContinuousClock.now
        defer { Timing.log("summaries", since: started) }
        var out: [String: String] = [:]
        var points: [String: String] = [:]
        var metres: [String: Double] = [:]
        for detail in routes {
            let vias = detail.viaPoints.count
            let shaping = detail.points.count - vias
            let length = detail.length
            metres[detail.route.id] = length
            var summary = "\(vias) via point\(vias == 1 ? "" : "s")"
            if shaping > 0 { summary += ", \(shaping) shaping" }
            summary += " · \(Self.miles(length))"
            if detail.route.mode != .road { summary += " · \(detail.route.mode.title)" }
            out[detail.route.id] = summary

            for (seq, metres) in detail.distancesFromStart() {
                points[OverlayGeoJSON.handle(detail.route.id, seq)] = Self.miles(metres)
            }
        }
        var statistics: [String: TrackStatistics] = [:]
        for detail in tracks {
            let stats = TrackStatistics(detail)
            statistics[detail.track.id] = stats
            metres[detail.track.id] = stats.distance
            out[detail.track.id] = "\(detail.points.count) points · \(Self.miles(stats.distance))"
        }
        summaries = out
        pointSummaries = points
        lengths = metres
        trackStatistics = statistics
    }

    /// Miles, because this is a US touring app and the GPS it feeds is set
    /// the same way. Everything below the UI carries metres and no unit in
    /// its name.
    private static func miles(_ metres: Double) -> String {
        let miles = metres / 1609.344
        return miles < 10 ? String(format: "%.1f mi", miles) : String(format: "%.0f mi", miles)
    }

    // MARK: - Import and export

    /// Reads a GPX file into the library, off the main thread.
    ///
    /// Parsing and the insert both happen away from the main actor. A day's
    /// recorded track is a few hundred thousand points, and doing that work
    /// where the window lives means the window stops drawing — which macOS
    /// reports as "not responding" and the user reasonably reads as a crash.
    func importGPX(from url: URL) {
        guard !isBusy else { return }
        isBusy = true

        let store = self.store
        Task {
            let outcome = await Self.read(url, into: store)
            isBusy = false

            switch outcome {
            case .success(let result) where result.count.isEmpty:
                failure = "\(url.lastPathComponent) has no waypoints, routes or tracks in it."
            case .success(let result):
                failure = nil
                // Framed once the rows arrive. Importing a route and being
                // left looking at wherever the map already was is the version
                // of this that makes a user think nothing happened.
                pendingFocus = Set(result.ids)
                applyPendingFocus()
            case .failure(let error):
                failure = error.localizedDescription
            }
        }
    }

    /// Frames the newest import as soon as its geometry is loaded.
    ///
    /// Called from both sides of the race: the import finishing, and the
    /// observation delivering the rows. Whichever lands second does the work.
    private func applyPendingFocus() {
        guard !pendingFocus.isEmpty else { return }
        let known = Set(routes.map(\.route.id))
            .union(tracks.map(\.track.id))
            .union(waypoints.map(\.id))
        guard !pendingFocus.isDisjoint(with: known) else { return }

        focus(on: pendingFocus)
        pendingFocus = []
    }

    private static func read(_ url: URL, into store: LibraryStore) async -> Result<GPXImportResult, Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                // A file the user picked from outside the app needs its
                // access scope opened. Without this the read fails only once
                // the app is sandboxed, which is a change nobody will connect
                // to this line.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }

                let document = try FileImport.read(contentsOf: url)
                guard !document.isEmpty else {
                    return .success(GPXImportResult(count: GPXImportCount(), ids: []))
                }
                return .success(try store.importGPX(document))
            } catch {
                return .failure(error)
            }
        }.value
    }

    func exportGPX(to url: URL) {
        guard !isBusy else { return }
        isBusy = true

        let store = self.store
        let waypointIDs = waypoints.map(\.id).filter(isSelectedOrNothingIs)
        let routeIDs = routes.map(\.route.id).filter(isSelectedOrNothingIs)
        let trackIDs = tracks.map(\.track.id).filter(isSelectedOrNothingIs)

        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Error? in
                do {
                    let document = try store.exportGPX(waypointIDs: waypointIDs,
                                                       routeIDs: routeIDs,
                                                       trackIDs: trackIDs)
                    try GPXWriter.data(document).write(to: url, options: .atomic)
                    return nil
                } catch {
                    return error
                }
            }.value

            isBusy = false
            failure = outcome?.localizedDescription
        }
    }

    /// One item as its own document, for sending a named file to a device.
    func document(for id: String) -> GPXDocument? {
        if routes.contains(where: { $0.route.id == id }) {
            return try? store.exportGPX(routeIDs: [id])
        }
        if tracks.contains(where: { $0.track.id == id }) {
            return try? store.exportGPX(trackIDs: [id])
        }
        return try? store.exportGPX(waypointIDs: [id])
    }

    /// Several items in one document.
    func document(for ids: Set<String>) -> GPXDocument? {
        try? store.exportGPX(waypointIDs: waypoints.map(\.id).filter(ids.contains),
                             routeIDs: routes.map(\.route.id).filter(ids.contains),
                             trackIDs: tracks.map(\.track.id).filter(ids.contains))
    }

    /// The library items named, as device files ready to write.
    ///
    /// One file per item, because a Garmin lists what it finds by filename
    /// and three routes in one file appear on the unit as a single entry.
    func files(for ids: Set<String>) -> [(name: String, data: Data)] {
        ids.compactMap { id in
            guard let document = document(for: id) else { return nil }
            return (DeviceFilename.make(from: name(for: id) ?? "Route"),
                    GPXWriter.data(document))
        }
        .sorted { $0.name < $1.name }
    }

    /// What something is called, for a filename and a checkbox.
    func name(for id: String) -> String? {
        routes.first { $0.route.id == id }?.route.name
            ?? tracks.first { $0.track.id == id }?.track.name
            ?? waypoints.first { $0.id == id }?.name
    }

    /// The document the current selection would export as, or the whole
    /// library when nothing is selected. Built for the device panel, which
    /// needs the bytes rather than a file on disk.
    func exportDocument() -> GPXDocument? {
        try? store.exportGPX(waypointIDs: waypoints.map(\.id).filter(isSelectedOrNothingIs),
                             routeIDs: routes.map(\.route.id).filter(isSelectedOrNothingIs),
                             trackIDs: tracks.map(\.track.id).filter(isSelectedOrNothingIs))
    }

    /// Brings BaseCamp's own library on this Mac across, lists included,
    /// without opening BaseCamp. Says so when there is none.
    func importBaseCampLibrary() {
        guard let url = FileImport.baseCampLibrary() else {
            failure = "No BaseCamp library was found on this Mac. BaseCamp keeps one under Library/Application Support/Garmin once it has run."
            return
        }
        importGPX(from: url)
    }

    /// Imports GPX that came from somewhere other than a file, such as a
    /// device.
    func importGPX(data: Data, named name: String) {
        do {
            let document = try FileImport.read(data: data)
            guard !document.isEmpty else {
                failure = "\(name) has no waypoints, routes or tracks in it."
                return
            }
            let result = try store.importGPX(document)
            pendingFocus = Set(result.ids)
            applyPendingFocus()
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    /// With nothing selected, export means the whole library. Writing an
    /// empty file because the user had not clicked anything first would be
    /// obedient and useless.
    private func isSelectedOrNothingIs(_ id: String) -> Bool {
        selection.isEmpty || selection.contains(id)
    }

    // MARK: - Directions

    /// What a narrative of the route would be computed from, or nil while
    /// there is nothing to narrate yet: a Direct route, a route with one
    /// point, or one whose legs are still being routed. The pane runs
    /// `loadDirections` whenever this changes.
    func directionsKey(for routeID: String) -> String? {
        guard let detail = routes.first(where: { $0.route.id == routeID }),
              detail.route.mode != .direct, detail.points.count >= 2,
              !routing.contains(routeID) else { return nil }
        return Self.signature(of: detail)
    }

    /// The narrative for a route as it stands, into `directionsByRoute`,
    /// unless the one there is already for this state of the route. Off
    /// the main actor: a cross-country route is a search of the graph.
    func loadDirections(for routeID: String) async {
        guard let key = directionsKey(for: routeID), directionsByRoute[routeID]?.key != key,
              let detail = routes.first(where: { $0.route.id == routeID }) else { return }
        let result = await Task.detached(priority: .userInitiated) { () -> Result<RouteDirections, Error> in
            guard let engine = RoutingEngine.shared else {
                return .failure(RoutingError(message: "the routing engine is not available"))
            }
            return Result { try engine.directions(for: detail) }
        }.value
        // An edit that landed meanwhile asked for its own pass.
        guard directionsKey(for: routeID) == key else { return }
        switch result {
        case .success(let directions):
            directionsByRoute[routeID] = DirectionsEntry(key: key, directions: directions)
        case .failure(let error):
            NSLog("[Swiftcamp] no directions: %@", error.localizedDescription)
            directionsByRoute[routeID] = DirectionsEntry(key: key, failure: error.localizedDescription)
        }
    }

    /// Looks at a spot on the road, close enough to read the junction.
    func look(at coordinate: Coordinate, zoom: Double = 15) {
        nextCameraID += 1
        camera = MapCameraRequest(id: nextCameraID, target: .point(coordinate, zoom: zoom))
    }

    // MARK: - Selection

    /// Selecting in the sidebar also frames what was selected.
    ///
    /// Deliberately not what a click on the map does. Something the user
    /// just clicked is by definition already on screen, and recentring it
    /// would pull the view out from under the hand that aimed at it. In the
    /// sidebar the item may be a thousand miles away, and a selection that
    /// changes nothing visible reads as a broken list.
    func selectFromSidebar(_ ids: Set<String>) {
        guard ids != selection else { return }
        selection = ids
        if ids.count == 1 { focus(on: ids) }
    }

    /// Frames one item, or several together.
    func focus(on ids: Set<String>) {
        var corners: [Coordinate] = []

        for detail in routes where ids.contains(detail.route.id) {
            corners.append(contentsOf: detail.path
        )
        }
        for detail in tracks where ids.contains(detail.track.id) {
            corners.append(contentsOf: detail.points.map(\.coordinate))
        }
        for waypoint in waypoints where ids.contains(waypoint.id) {
            corners.append(waypoint.coordinate)
        }
        // A route point picked from the sidebar's list, by its handle.
        for handle in ids.compactMap(OverlayGeoJSON.parseHandle) {
            if let point = routes.first(where: { $0.route.id == handle.routeID })?
                .points.first(where: { $0.seq == handle.seq }) {
                corners.append(point.coordinate)
            }
        }

        guard let box = BoundingBox(corners) else { return }
        nextCameraID += 1
        // A single waypoint, or a route whose points all landed on one spot,
        // has no rectangle to fit. Zoom 14 puts a town and the roads into it
        // on screen, which is the context that makes a pin mean anything.
        camera = MapCameraRequest(id: nextCameraID,
                                  target: box.isDegenerate
                                      ? .point(box.center, zoom: 14)
                                      : .bounds(box))
    }

    func select(_ click: MapClick) {
        if editingRouteID != nil, edit(with: click) { return }

        switch click.target {
        case .viaPoint(let routeID, let seq):
            selection = [OverlayGeoJSON.handle(routeID, seq), routeID]
        case .routeLine(let routeID):
            selection = [routeID]
        case .waypoint(let id):
            selection = [id]
        case .track(let id):
            selection = [id]
        case .searchPin:
            break   // a look, not a library item; the menu is its interface
        case .ground:
            selection = []
        }
    }

    // MARK: - Route editing

    /// Starts a new, empty route and begins editing it.
    ///
    /// Written to the library at once rather than held until the first
    /// click, so it appears in the sidebar and can be named while the map
    /// is still being aimed. An empty route left behind on Done is deleted.
    func newRoute() {
        finishEditing()

        let taken = Set(routes.map(\.route.name))
        var n = routes.count + 1
        while taken.contains("Route \(n)") { n += 1 }

        let route = Route(name: "Route \(n)",
                          color: ItemColor.default(for: routes.count + tracks.count).name,
                          mode: Self.defaultMode,
                          preferences: RoutePreferences.stored)
        do {
            try store.insert(route)
        } catch {
            failure = error.localizedDescription
            return
        }
        // Undoing the creation removes the route, points and all. Redo
        // cannot bring the points back — but there were none when this was
        // registered, and every later edit sits above it on the stack.
        registerUndo("New Route") { model in
            model.finishEditing()
            model.delete(route.id)
        }

        // In the editor's view of the library at once. The observation
        // delivers the same row a moment later, but a fast first click
        // would otherwise find no route to add to.
        routes.append(RouteDetail(route: route, points: []))
        refreshHasContent()
        editingRouteID = route.id
        selection = [route.id]
    }

    func editRoute(_ id: String) {
        guard routes.contains(where: { $0.route.id == id }) else { return }
        finishEditing()
        editingRouteID = id
        selection = [id]
    }

    /// Leaves editing mode. A route with no points is not a route and is
    /// removed rather than left as an empty row.
    func finishEditing() {
        guard let id = editingRouteID else { return }
        editingRouteID = nil
        if drag?.routeID == id { drag = nil }
        if let detail = routes.first(where: { $0.route.id == id }), detail.points.isEmpty {
            do { try store.deleteRoute(id: id) } catch { failure = error.localizedDescription }
            selection.remove(id)
        }
    }

    /// The mode a new route starts in, from Settings.
    static var defaultMode: RoutingMode {
        RoutingMode(rawValue: UserDefaults.standard.string(forKey: RoutingMode.defaultKey) ?? "") ?? .road
    }

    /// The map moved. From zoom 9 the local tiles under it are worth
    /// having before a drag asks for them.
    func viewChanged(_ box: BoundingBox, zoom: Double) {
        viewCenter = box.center
        search.prepare(near: box.center)
        guard zoom >= 9 else { return }
        prefetch?.warm(box)
    }

    // MARK: - Search

    /// Flies to a result and pins it. Zoom 14 puts a town and its roads on
    /// screen, the context that makes a pin mean anything; a street is
    /// shown a little closer.
    func show(_ result: SearchResult) {
        searchPin = result
        rebuildOverlay()
        nextCameraID += 1
        camera = MapCameraRequest(id: nextCameraID,
                                  target: .point(result.coordinate, zoom: result.kind == .address ? 15 : 13))
    }

    func dismissSearchPin() {
        searchPin = nil
        rebuildOverlay()
    }

    /// Keeps the pinned result as a waypoint, which can then be routed
    /// through, renamed and sent to the device like any other.
    func saveSearchPin() {
        guard let result = searchPin else { return }
        let waypoint = Waypoint(name: result.name, lat: result.coordinate.lat, lon: result.coordinate.lon,
                                comment: result.kind == .coordinate ? nil : result.detail)
        do {
            try store.save(waypoint)
        } catch {
            failure = error.localizedDescription
            return
        }
        registerUndo("Save Waypoint") { model in model.delete(waypoint.id) }
        waypoints.append(waypoint)
        refreshHasContent()
        searchPin = nil
        selection = [waypoint.id]
    }

    // MARK: - Waypoints

    /// A new waypoint where the right-click landed, or at the middle of
    /// the map from the menu bar, named and ready to rename. Garmin's
    /// default symbol, so the device draws it the way BaseCamp's would.
    /// Filed in the selected list: what is made while looking at a list
    /// belongs to it, or it would vanish on creation.
    func newWaypoint(at coordinate: Coordinate? = nil) {
        guard let coordinate = coordinate ?? viewCenter else { return }
        let taken = Set(waypoints.map(\.name))
        var n = waypoints.count + 1
        while taken.contains("Waypoint \(n)") { n += 1 }
        let waypoint = Waypoint(listID: selectedListID, name: "Waypoint \(n)",
                                lat: coordinate.lat, lon: coordinate.lon, symbol: "Flag, Blue")
        do {
            try store.save(waypoint)
        } catch {
            failure = error.localizedDescription
            return
        }
        registerUndo("New Waypoint") { model in model.delete(waypoint.id) }
        waypoints.append(waypoint)
        refreshHasContent()
        rebuildShown()
        requestRename(waypoint.id)
    }

    /// Writes a waypoint's fields as the inspector has them, undoably.
    /// The whole record, because the inspector edits several fields and
    /// one undo per field typed would be a stack of nothing.
    func update(_ waypoint: Waypoint, actionName: String = "Edit Waypoint") {
        guard let before = waypoints.first(where: { $0.id == waypoint.id }), before != waypoint else { return }
        do {
            try store.save(waypoint)
        } catch {
            failure = error.localizedDescription
            return
        }
        if let i = waypoints.firstIndex(where: { $0.id == waypoint.id }) {
            waypoints[i] = waypoint
            rebuildShown()
            rebuildOverlay()
        }
        // One group around the waypoint and the routes that follow it, so
        // a dragged campsite and the legs that moved with it undo together.
        undoManager.beginUndoGrouping()
        registerUndo(actionName) { model in model.update(before, actionName: actionName) }
        followWaypoint(waypoint)
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
    }

    /// A route's header, from the inspector. The points are untouched.
    func update(_ route: Route, actionName: String = "Edit Route") {
        guard let i = routes.firstIndex(where: { $0.route.id == route.id }), routes[i].route != route else { return }
        let before = routes[i].route
        do {
            try store.update(route)
        } catch {
            failure = error.localizedDescription
            return
        }
        routes[i].route = route
        rebuildSummaries()
        rebuildShown()
        rebuildOverlay()
        registerUndo(actionName) { model in model.update(before, actionName: actionName) }
    }

    func update(_ track: Track, actionName: String = "Edit Track") {
        guard let i = tracks.firstIndex(where: { $0.track.id == track.id }), tracks[i].track != track else { return }
        let before = tracks[i].track
        do {
            try store.update(track)
        } catch {
            failure = error.localizedDescription
            return
        }
        tracks[i].track = track
        rebuildShown()
        rebuildOverlay()
        registerUndo(actionName) { model in model.update(before, actionName: actionName) }
    }

    /// Moves a waypoint, from a drag on the map or coordinates typed into
    /// the inspector.
    func moveWaypoint(_ id: String, to coordinate: Coordinate) {
        guard var waypoint = waypoints.first(where: { $0.id == id }) else { return }
        waypoint.lat = coordinate.lat
        waypoint.lon = coordinate.lon
        update(waypoint, actionName: "Move Waypoint")
    }

    /// A waypoint being dragged. Drawn where the pointer is between the
    /// press and the release; the release is the edit.
    private func dragWaypoint(_ id: String, _ event: MapDrag) {
        switch event.phase {
        case .begin:
            selection = [id]
            waypointDrag = (id, event.coordinate)
        case .move:
            waypointDrag = (id, event.coordinate)
            rebuildOverlay()
        case .end:
            waypointDrag = nil
            moveWaypoint(id, to: event.coordinate)
        }
    }

    // MARK: - Conversions

    /// A track that follows the route exactly, so a device draws the line
    /// that was planned rather than re-routing between the stops. See
    /// `TrackDetail.init(fromRoute:)`.
    func makeTrack(fromRoute id: String) {
        guard let source = routes.first(where: { $0.route.id == id }), !source.points.isEmpty else { return }
        var detail = TrackDetail(fromRoute: source)
        detail.track.name = uniqueName(source.route.name, among: tracks.map(\.track.name))
        do {
            try store.save(detail.track, points: detail.points)
        } catch {
            failure = error.localizedDescription
            return
        }
        registerUndo("Create Track") { model in model.delete(detail.track.id) }
        tracks.append(detail)
        refreshHasContent()
        rebuildSummaries()
        rebuildShown()
        selection = [detail.track.id]
    }

    /// A route whose legs are the track, with a few of its points as
    /// handles. See `RouteDetail.init(fromTrack:mode:)`.
    func makeRoute(fromTrack id: String) {
        guard let source = tracks.first(where: { $0.track.id == id }), !source.points.isEmpty else { return }
        var detail = RouteDetail(fromTrack: source, mode: Self.defaultMode)
        detail.route.name = uniqueName(source.track.name, among: routes.map(\.route.name))
        do {
            try store.save(detail)
        } catch {
            failure = error.localizedDescription
            return
        }
        registerUndo("Create Route") { model in model.delete(detail.route.id) }
        routes.append(detail)
        refreshHasContent()
        rebuildSummaries()
        rebuildShown()
        selection = [detail.route.id]
    }

    // MARK: - Duplicate

    /// A copy of whatever this is, beside it, named after it and selected
    /// so the rename field has it. Undo removes the copy.
    func duplicate(_ id: String) {
        if let source = routes.first(where: { $0.route.id == id }) {
            var detail = source
            detail.route.id = newID()
            detail.route.name = uniqueName("\(source.route.name) copy", among: routes.map(\.route.name))
            detail.route.createdAt = .now
            detail.route.updatedAt = .now
            detail.points = detail.points.map { point in
                var p = point
                p.id = nil
                p.routeID = detail.route.id
                return p
            }
            do {
                try store.save(detail)
            } catch {
                failure = error.localizedDescription
                return
            }
            registerUndo("Duplicate") { model in model.delete(detail.route.id) }
            routes.append(detail)
            refreshHasContent()
            rebuildSummaries()
            rebuildShown()
            rebuildOverlay()
            selection = [detail.route.id]
        } else if let source = tracks.first(where: { $0.track.id == id }) {
            var detail = source.joined(with: [])
            detail.track.name = uniqueName("\(source.track.name) copy", among: tracks.map(\.track.name))
            insert(detail, actionName: "Duplicate")
        } else if let source = waypoints.first(where: { $0.id == id }) {
            var waypoint = source
            waypoint.id = newID()
            waypoint.name = uniqueName("\(source.name) copy", among: waypoints.map(\.name))
            waypoint.createdAt = .now
            waypoint.updatedAt = .now
            do {
                try store.save(waypoint)
            } catch {
                failure = error.localizedDescription
                return
            }
            registerUndo("Duplicate") { model in model.delete(waypoint.id) }
            waypoints.append(waypoint)
            refreshHasContent()
            rebuildShown()
            rebuildOverlay()
            selection = [waypoint.id]
        }
    }

    /// Duplicates every selected item, for the Edit menu.
    func duplicateSelection() {
        let ids = selection.filter { !isList($0) && OverlayGeoJSON.parseHandle($0) == nil }
        guard !ids.isEmpty else { return }
        undoManager.beginUndoGrouping()
        var made: Set<String> = []
        for id in ids.sorted() {
            duplicate(id)
            made.formUnion(selection)
        }
        undoManager.setActionName("Duplicate")
        undoManager.endUndoGrouping()
        selection = made
    }

    // MARK: - Track tools

    /// The same ride the other way. See `TrackDetail.inverted`.
    func invertTrack(_ id: String) {
        guard let detail = tracks.first(where: { $0.track.id == id }) else { return }
        replace([detail], with: [detail.inverted()], actionName: "Invert Track")
    }

    /// Cuts a track at the fix nearest a spot on it, from the map's menu.
    /// See `TrackDetail.split(at:)`.
    func splitTrack(_ id: String, at coordinate: Coordinate) {
        guard let detail = tracks.first(where: { $0.track.id == id }),
              let index = detail.nearestPointIndex(to: coordinate),
              let (first, second) = detail.split(at: index) else { return }
        replace([detail], with: [first, second], actionName: "Split Track")
    }

    /// One track from the selected ones, in the sidebar's order, which is
    /// the order the rider sees them in. See `TrackDetail.joined(with:)`.
    func joinTracks(_ ids: Set<String>) {
        let details = shownTracks.filter { ids.contains($0.track.id) }
        guard details.count >= 2 else { return }
        replace(details, with: [details[0].joined(with: Array(details.dropFirst()))], actionName: "Join Tracks")
    }

    /// Thins a track to a device's point limit. See `TrackDetail.simplified(atMost:)`.
    func simplifyTrack(_ id: String, atMost count: Int) {
        guard let detail = tracks.first(where: { $0.track.id == id }), detail.points.count > count else { return }
        replace([detail], with: [detail.simplified(atMost: count)], actionName: "Simplify Track")
    }

    /// Writes a new track and selects it; undo removes it.
    private func insert(_ detail: TrackDetail, actionName: String) {
        do {
            try store.save(detail.track, points: detail.points)
        } catch {
            failure = error.localizedDescription
            return
        }
        registerUndo(actionName) { model in model.delete(detail.track.id) }
        tracks.append(detail)
        refreshHasContent()
        rebuildSummaries()
        rebuildShown()
        rebuildOverlay()
        selection = [detail.track.id]
    }

    /// Swaps some tracks for others as one step, and undo swaps them back
    /// whole. The originals are held in the undo closure, which is the
    /// same memory `tracks` already holds for them; a track edit is the
    /// one deletion of a track that is undoable, because here the points
    /// are in hand.
    private func replace(_ originals: [TrackDetail], with results: [TrackDetail], actionName: String) {
        let gone = Set(originals.map(\.track.id))
        do {
            try store.replaceTracks(deleting: Array(gone), inserting: results)
        } catch {
            failure = error.localizedDescription
            return
        }
        tracks.removeAll { gone.contains($0.track.id) }
        tracks.append(contentsOf: results)
        refreshHasContent()
        rebuildSummaries()
        rebuildShown()
        rebuildOverlay()
        selection = Set(results.map(\.track.id))
        registerUndo(actionName) { model in model.replace(results, with: originals, actionName: actionName) }
    }

    // MARK: - Backup and restore

    /// Writes the library to a file of the user's choosing.
    func backup(to url: URL) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let store = self.store
        let outcome = await Task.detached(priority: .userInitiated) { () -> Error? in
            do { try store.backup(to: url) } catch { return error }
            return nil
        }.value
        if let outcome { failure = outcome.localizedDescription }
    }

    /// Replaces the library with a backup's contents. The undo stack is
    /// emptied, since every entry on it names rows that are now gone.
    func restore(from url: URL) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        finishEditing()
        drag = nil
        waypointDrag = nil
        selection = []
        let store = self.store
        let outcome = await Task.detached(priority: .userInitiated) { () -> Error? in
            do { try store.restore(from: url) } catch { return error }
            return nil
        }.value
        undoManager.removeAllActions()
        directionsByRoute = [:]
        if let outcome { failure = outcome.localizedDescription }
    }

    #if os(macOS)
    /// File, Back Up Library: a save panel, then the copy.
    func backupLibrary() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.swiftcampLibrary]
        panel.nameFieldStringValue = "Swiftcamp Library \(Date.now.formatted(.iso8601.year().month().day())).sqlite"
        panel.title = "Back Up Library"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { await self?.backup(to: url) }
        }
    }

    /// File, Restore Library: an open panel, a warning that says what
    /// is about to happen, then the replacement.
    func restoreLibrary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.swiftcampLibrary]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Restore Library"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            let alert = NSAlert()
            alert.messageText = "Replace the library with “\(url.lastPathComponent)”?"
            alert.informativeText = "Everything in the library will be replaced by the backup's contents. This cannot be undone."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            Task { await self?.restore(from: url) }
        }
    }
    #endif

    /// `name`, or `name 2`, `name 3`… when it is taken. Two rows called
    /// the same thing in one section are indistinguishable on a device.
    private func uniqueName(_ name: String, among taken: [String]) -> String {
        let taken = Set(taken)
        guard taken.contains(name) else { return name }
        var n = 2
        while taken.contains("\(name) \(n)") { n += 1 }
        return "\(name) \(n)"
    }

    // MARK: - Routing after an edit

    /// Routes whatever legs of a route are still straight, away from the
    /// main actor, and writes the roads back when they arrive.
    ///
    /// An edit writes straight legs at once and returns; the road is a
    /// derivation that follows, like the summaries. That is what keeps a
    /// click from freezing the window: a cross-country leg over a cold
    /// cache is twenty seconds of fetching, and it used to happen inside
    /// the click. The written road carries no undo entry of its own, so
    /// undo restores the edit's straight legs and this routes them again,
    /// warm. A leg the engine refuses stays straight and is not asked
    /// again until one of its ends moves.
    private func routeStraightLegs(of routeID: String) {
        guard let detail = routes.first(where: { $0.route.id == routeID }),
              detail.route.mode != .direct else { return }
        let legs = detail.straightLegs.filter { !refusedLegs.contains(Self.legKey(detail, $0)) }
        guard !legs.isEmpty else { return }
        guard !routing.contains(routeID) else {
            // One pass per route at a time; the pass that lands starts the next.
            reroutePending.insert(routeID)
            return
        }
        routing.insert(routeID)
        let signature = Self.signature(of: detail)
        let header = detail.route

        Task {
            // The tiles at each leg's ends, together, before the engine
            // asks for them one at a time.
            let ends = legs.flatMap { [detail.points[$0].coordinate, detail.points[$0 + 1].coordinate] }
            await prefetch?.warm(around: ends)

            let started = ContinuousClock.now
            let routed = await Task.detached(priority: .userInitiated) { () -> [RoutePoint]? in
                guard let shaping = RoutingEngine.shaping(for: header) else { return nil }
                var working = detail
                working.reshape(legs: legs, snap: shaping.snap, shape: shaping.shape)
                return working.points
            }.value
            Timing.log("derive.route", since: started, "\(legs.count) leg(s)")
            routing.remove(routeID)
            defer {
                if reroutePending.remove(routeID) != nil { routeStraightLegs(of: routeID) }
            }

            // An edit that landed meanwhile makes this answer stale; its
            // own write asked for a fresh pass.
            guard let routed, let i = routes.firstIndex(where: { $0.route.id == routeID }),
                  Self.signature(of: routes[i]) == signature else { return }

            var after = routes[i]
            after.points = routed
            for leg in legs where after.points[leg].geometry == nil {
                refusedLegs.insert(Self.legKey(after, leg))
            }
            guard routed != routes[i].points else { return }

            let writing = ContinuousClock.now
            do {
                try store.replacePoints(routeID: routeID, with: routed)
            } catch {
                failure = error.localizedDescription
                return
            }
            Timing.log("derive.write", since: writing, "\(routed.reduce(0) { $0 + 1 + ($1.geometry?.count ?? 0) }) coordinates")
            routes[i].points = routed
            rebuildOverlay()
        }
    }

    /// What an edit changes that would make a routing answer stale.
    private static func signature(of detail: RouteDetail) -> String {
        detail.route.routingKey + detail.points.map {
            "|\($0.seq):\($0.lat),\($0.lon),\($0.isVia),\($0.isPinned)"
        }.joined()
    }

    private static func legKey(_ detail: RouteDetail, _ leg: Int) -> String {
        let a = detail.points[leg], b = detail.points[leg + 1]
        return "\(detail.route.routingKey):\(a.lat),\(a.lon)->\(b.lat),\(b.lon)"
    }

    /// The route being edited, as the editor sees it.
    private var editingDetail: RouteDetail? {
        guard let editingRouteID else { return nil }
        return routes.first { $0.route.id == editingRouteID }
    }

    /// A click while editing. Returns false when the click means what it
    /// would have meant outside editing, so the caller falls through to
    /// selection.
    private func edit(with click: MapClick) -> Bool {
        guard var detail = editingDetail else { return false }

        switch click.target {
        case .ground:
            appendPoint(click.coordinate, isVia: true)
            return true

        case .waypoint(let id):
            // Routing through a waypoint is how BaseCamp users plan: pins
            // first, then a route that visits them. The via point takes the
            // waypoint's exact position and its name, and keeps the
            // position whatever the mode: a campsite is where it is, and
            // the leg runs to the road from there, as BaseCamp draws it.
            guard let waypoint = waypoints.first(where: { $0.id == id }) else { return false }
            appendPoint(waypoint)
            return true

        case .searchPin:
            // The same, for the place a search found: named after it and
            // kept exactly there.
            guard let pin = searchPin else { return false }
            appendPoint(pin.coordinate, isVia: true, name: pin.name, pinned: true)
            return true

        case .routeLine(let routeID) where routeID == detail.route.id:
            guard let leg = detail.nearestLeg(to: click.coordinate) else { return false }
            detail.insertVia(click.coordinate, inLeg: leg)
            commit(detail, actionName: "Insert Point")
            return true

        case .viaPoint(let routeID, _) where routeID == detail.route.id:
            return false    // selects the handle, so Delete knows which

        case .viaPoint, .routeLine, .track:
            return false
        }
    }

    /// A via point, or the line, being dragged. Moves redraw along the
    /// road; the end is the edit.
    ///
    /// Any route, not only the one being edited. Grabbing a route is how
    /// it gets selected, as in Google Maps; editing mode exists for adding
    /// points by clicking, which needs a mode because a click on empty map
    /// otherwise means nothing.
    func drag(_ event: MapDrag) {
        let routeID: String
        let grabbedSeq: Int?
        switch event.subject {
        case .waypoint(let id):
            dragWaypoint(id, event)
            return
        case .routePoint(let id, let seq):
            routeID = id
            grabbedSeq = seq
        }
        guard var detail = routes.first(where: { $0.route.id == routeID }) else { return }

        switch event.phase {
        case .begin:
            let seq: Int
            if let grabbed = grabbedSeq {
                seq = grabbed
            } else {
                // The line was grabbed: it grows a point where the press
                // landed, and the drag moves that. A shaping point, as
                // BaseCamp and Google Maps both make it: pulling a route
                // onto a different road is about the road, not a stop. A
                // click on the line makes a via point, and the right-click
                // menu converts either way. Its legs are straight only
                // until the first move routes them, which is the same frame.
                guard let leg = detail.nearestLeg(to: event.coordinate) else { return }
                detail.insertVia(event.coordinate, inLeg: leg, isVia: false)
                seq = leg + 1
            }
            guard detail.points.indices.contains(seq) else { return }
            // Selected before the drag state exists, so the rebuild the
            // selection triggers draws the route as it was. A grown point
            // with its straight legs would otherwise flash for a frame
            // before the first move routes them.
            selection = [OverlayGeoJSON.handle(detail.route.id, seq), detail.route.id]
            drag = Drag(routeID: detail.route.id, seq: seq, inserted: grabbedSeq == nil, base: detail.points)

        case .move:
            guard let drag, drag.routeID == routeID else { return }
            drag.pending = event.coordinate
            if !drag.inFlight { routeDrag(drag) }

        case .end:
            guard let drag, drag.routeID == routeID else { return }
            self.drag = nil
            if drag.shapedFor == event.coordinate {
                // The release is where the last move was routed, which is
                // nearly always: the pointer does not move between the
                // final mousemove and the mouseup.
                detail.points = drag.points
            } else {
                detail.points = drag.base
                detail.moveVia(at: drag.seq, to: event.coordinate)
            }
            commit(detail, actionName: drag.inserted ? "Insert Point" : "Move Point")
        }
    }

    /// Routes the legs either side of the dragged point for its newest
    /// position, away from the main actor, then draws the result and
    /// routes again if the pointer moved meanwhile.
    ///
    /// Always from `base`, never from the previous pass: only one point
    /// moves and only its two legs change, so the result is the same and
    /// nothing can accumulate.
    private func routeDrag(_ drag: Drag) {
        guard let target = drag.pending,
              let detail = routes.first(where: { $0.route.id == drag.routeID }) else { return }
        drag.pending = nil
        drag.inFlight = true

        var base = detail
        base.points = drag.base
        let seq = drag.seq
        let header = detail.route
        Task {
            // The moving point and its neighbours: a preview routes the
            // two legs between them.
            let around = [seq - 1, seq + 1].filter { drag.base.indices.contains($0) }.map { drag.base[$0].coordinate }
            await prefetch?.warm(around: [target] + around)

            let started = ContinuousClock.now
            let points = await Task.detached(priority: .userInitiated) { () -> [RoutePoint] in
                var working = base
                let shaping = RoutingEngine.previewShaping(for: header) ?? (snap: .never, shape: RouteEditing.straight)
                working.moveVia(at: seq, to: target, snap: shaping.snap, shape: shaping.shape)
                return working.points
            }.value
            Timing.log("preview.route", since: started)

            // The drag may have ended, or a new one begun, while this was
            // routing; the result then describes nothing on screen.
            guard self.drag === drag else { return }
            drag.inFlight = false
            drag.points = points
            drag.shapedFor = target
            rebuildOverlay()
            if drag.pending != nil { routeDrag(drag) }
        }
    }

    /// Removes the selected via point of the route being edited.
    func deleteSelectedViaPoint() {
        guard let detail = editingDetail,
              let seq = selection.compactMap(OverlayGeoJSON.parseHandle).first(where: { $0.routeID == detail.route.id })?.seq
        else { return }
        deleteViaPoint(routeID: detail.route.id, seq: seq)
    }

    /// Makes a point a stop or a bend in the road. See `RouteDetail.setVia`.
    func setVia(routeID: String, seq: Int, _ isVia: Bool) {
        guard var detail = routes.first(where: { $0.route.id == routeID }) else { return }
        detail.setVia(at: seq, isVia)
        commit(detail, actionName: isVia ? "Make Via Point" : "Make Shaping Point")
    }

    /// Names a via point. A shaping point ignores it; see `RouteDetail.rename`.
    func renamePoint(routeID: String, seq: Int, to name: String) {
        guard var detail = routes.first(where: { $0.route.id == routeID }) else { return }
        detail.rename(at: seq, to: name)
        commit(detail, actionName: "Rename Point")
    }

    /// Removes point `seq` of route `routeID`. Its neighbours are joined
    /// by a fresh leg, routed like any other.
    func deleteViaPoint(routeID: String, seq: Int) {
        guard var detail = routes.first(where: { $0.route.id == routeID }),
              detail.points.indices.contains(seq) else { return }
        detail.removeVia(at: seq)
        selection.remove(OverlayGeoJSON.handle(routeID, seq))
        commit(detail, actionName: "Delete Point")
    }

    /// Changes how a route is routed, and routes every leg again to match.
    /// Undo restores the legs exactly as they were, not a re-route in the
    /// old mode: a point that Road snapped onto the pavement would stay
    /// there under Adventure, and the rider's off-road drop would be gone.
    func setMode(_ mode: RoutingMode, forRoute id: String) {
        guard let i = routes.firstIndex(where: { $0.route.id == id }), routes[i].route.mode != mode else { return }
        var header = routes[i].route
        header.mode = mode
        reroute(id, with: header, actionName: "Change Routing")
    }

    /// Changes what a route's legs optimise for and avoid, and routes
    /// every leg again to match, undoably like a change of mode.
    func setPreferences(_ preferences: RoutePreferences, forRoute id: String) {
        guard let i = routes.firstIndex(where: { $0.route.id == id }), routes[i].route.preferences != preferences else { return }
        var header = routes[i].route
        header.preferences = preferences
        reroute(id, with: header, actionName: "Change Preferences")
    }

    /// Writes a new header and drops every leg's road so it is found
    /// again under the new settings.
    private func reroute(_ id: String, with header: Route, actionName: String) {
        guard let i = routes.firstIndex(where: { $0.route.id == id }) else { return }
        let before = (header: routes[i].route, points: routes[i].points)
        var detail = routes[i]
        detail.route = header
        detail.straightenAll()
        apply(header: header, points: detail.points, to: id, undoing: before, actionName: actionName)
    }

    private func apply(header: Route, points: [RoutePoint], to routeID: String,
                       undoing before: (header: Route, points: [RoutePoint]), actionName: String) {
        do {
            try store.update(header)
            try store.replacePoints(routeID: routeID, with: points)
        } catch {
            failure = error.localizedDescription
            return
        }
        if let i = routes.firstIndex(where: { $0.route.id == routeID }) {
            routes[i].route = header
            routes[i].points = points
            rebuildSummaries()
            rebuildShown()
            rebuildOverlay()
            routeStraightLegs(of: routeID)
        }
        registerUndo(actionName) { model in
            model.apply(header: before.header, points: before.points, to: routeID,
                        undoing: (header, points), actionName: actionName)
        }
    }

    // MARK: - Context menu

    /// What a right-click on the map offers, for the host to draw.
    ///
    /// A via point can be deleted from any route, not only the one being
    /// edited. The right-click names its target, where the Delete key has
    /// only the selection to go on, and that is confined to the editor.
    func contextMenu(for click: MapClick) -> [MapMenuItem] {
        switch click.target {
        case .viaPoint(let routeID, let seq):
            let isVia = routes.first { $0.route.id == routeID }?.points.first { $0.seq == seq }?.isVia ?? true
            return [
                MapMenuItem(title: isVia ? "Make Shaping Point" : "Make Via Point") {
                    self.setVia(routeID: routeID, seq: seq, !isVia)
                },
                MapMenuItem(title: "Delete Point") { self.deleteViaPoint(routeID: routeID, seq: seq) },
            ]

        case .routeLine(let routeID):
            let editing = routeID == editingRouteID
            let current = routes.first { $0.route.id == routeID }?.route.mode ?? .road
            var items: [MapMenuItem] = []
            if editing {
                // On the line, the point goes into the leg under the click
                // rather than on the end, as a click on the line does.
                items.append(MapMenuItem(title: "Insert Via Point Here") { self.insertPoint(click.coordinate, isVia: true) })
                items.append(MapMenuItem(title: "Insert Shaping Point Here") { self.insertPoint(click.coordinate, isVia: false) })
            }
            return items + [
                editing ? MapMenuItem(title: "Done Editing") { self.finishEditing() }
                        : MapMenuItem(title: "Edit Route") { self.editRoute(routeID) },
                MapMenuItem(title: "Reverse Route") { self.reverseRoute(routeID) },
            ] + RoutingMode.allCases.map { mode in
                MapMenuItem(title: "\(mode.title) Routing", isChecked: mode == current) {
                    self.setMode(mode, forRoute: routeID)
                }
            } + [
                MapMenuItem(title: "Prefer", children: preferMenu(for: routeID)),
                MapMenuItem(title: "Avoid", children: avoidMenu(for: routeID)),
                .separator,
                MapMenuItem(title: "Create Track from Route") { self.makeTrack(fromRoute: routeID) },
                MapMenuItem(title: "Rename…") { self.requestRename(routeID) },
            ]

        case .ground:
            // While a route is being edited, the point is the likelier
            // intent and goes first; a shaping point is the one thing a
            // click cannot place, since a click makes a via point.
            var items: [MapMenuItem] = []
            if editingRouteID != nil {
                items.append(MapMenuItem(title: "Add Via Point Here") { self.appendPoint(click.coordinate, isVia: true) })
                items.append(MapMenuItem(title: "Add Shaping Point Here") { self.appendPoint(click.coordinate, isVia: false) })
            }
            items.append(MapMenuItem(title: "New Route Here") { self.startRoute(at: click.coordinate) })
            items.append(MapMenuItem(title: "New Waypoint Here") { self.newWaypoint(at: click.coordinate) })
            return items

        case .waypoint(let id):
            guard let waypoint = waypoints.first(where: { $0.id == id }) else { return [] }
            var items: [MapMenuItem] = []
            if editingRouteID != nil {
                items.append(MapMenuItem(title: "Add Via Point at \(waypoint.name)") {
                    self.appendPoint(waypoint)
                })
            }
            items.append(MapMenuItem(title: "New Route from \(waypoint.name)") {
                self.startRoute(from: waypoint)
            })
            return items + [
                .separator,
                MapMenuItem(title: "Rename…") { self.requestRename(id) },
                MapMenuItem(title: "Change Icon", children: symbolMenu(for: waypoint)),
                .separator,
                MapMenuItem(title: "Delete") { self.delete(id) },
            ]

        case .searchPin:
            // The pin's own place, not the click's: a right-click lands
            // anywhere on the pin's picture, and the route should start
            // where the search put it.
            guard let pin = searchPin else { return [] }
            var items = [MapMenuItem(title: "Save as Waypoint") { self.saveSearchPin() }]
            if editingRouteID != nil {
                items.append(MapMenuItem(title: "Add Via Point at \(pin.name)") {
                    self.appendPoint(pin.coordinate, isVia: true, name: pin.name, pinned: true)
                })
            }
            items.append(MapMenuItem(title: "New Route from \(pin.name)") {
                self.startRoute(at: pin.coordinate, name: pin.name, pinned: true)
            })
            return items + [.separator, MapMenuItem(title: "Dismiss") { self.dismissSearchPin() }]

        case .track(let id):
            guard let detail = tracks.first(where: { $0.track.id == id }) else { return [] }
            return [
                MapMenuItem(title: "Split Track Here") { self.splitTrack(id, at: click.coordinate) },
                MapMenuItem(title: "Invert Track") { self.invertTrack(id) },
                MapMenuItem(title: "Create Route from Track") { self.makeRoute(fromTrack: id) },
                .separator,
                MapMenuItem(title: "Rename…") { self.requestRename(id) },
                MapMenuItem(title: "Colour", children: ItemColor.palette.map { color in
                    MapMenuItem(title: color.name, isChecked: color.name == detail.track.color) {
                        self.setColor(color, for: id)
                    }
                }),
                .separator,
                MapMenuItem(title: "Delete") { self.delete(id) },
            ]
        }
    }

    /// What the legs optimise for, the route's own ticked.
    private func preferMenu(for routeID: String) -> [MapMenuItem] {
        let current = routes.first { $0.route.id == routeID }?.route.preferences ?? RoutePreferences()
        return RoutePreferences.Preference.allCases.map { prefer in
            MapMenuItem(title: prefer.title, isChecked: prefer == current.prefer) {
                var next = current
                next.prefer = prefer
                self.setPreferences(next, forRoute: routeID)
            }
        }
    }

    /// The kinds of road to keep off, each ticked while avoided.
    private func avoidMenu(for routeID: String) -> [MapMenuItem] {
        let current = routes.first { $0.route.id == routeID }?.route.preferences ?? RoutePreferences()
        let kinds: [(String, WritableKeyPath<RoutePreferences, Bool>)] = [
            ("Highways", \.avoidHighways), ("Tolls", \.avoidTolls), ("Ferries", \.avoidFerries),
        ]
        return kinds.map { title, path in
            MapMenuItem(title: title, isChecked: current[keyPath: path]) {
                var next = current
                next[keyPath: path].toggle()
                self.setPreferences(next, forRoute: routeID)
            }
        }
    }

    /// Garmin's symbols, in the catalog's groups, the waypoint's own ticked.
    /// A symbol the catalog lacks ticks nothing: the waypoint keeps it, and
    /// the generic marker it draws with is not a choice the user made.
    private func symbolMenu(for waypoint: Waypoint) -> [MapMenuItem] {
        let current = SymbolCatalog.known(waypoint.symbol)
        var items: [MapMenuItem] = []
        var group: String?
        for entry in SymbolCatalog.entries {
            if let group, group != entry.group { items.append(.separator) }
            group = entry.group
            items.append(MapMenuItem(title: entry.name, isChecked: entry == current) {
                self.setSymbol(entry.name, forWaypoint: waypoint.id)
            })
        }
        return items
    }

    /// Asks the sidebar to open its rename field on an item or a list.
    /// A list is not selectable, so the selection is left alone for one.
    func requestRename(_ id: String) {
        if !isList(id) { selection = [id] }
        renameRequest = RenameRequest(id: id, token: (renameRequest?.token ?? 0) + 1)
    }

    /// Changes a waypoint's Garmin symbol, which is what the device draws
    /// it as, and undoably: an icon picked from a long menu is easy to
    /// pick wrong.
    func setSymbol(_ symbol: String?, forWaypoint id: String) {
        guard let waypoint = waypoints.first(where: { $0.id == id }), waypoint.symbol != symbol else { return }
        do {
            try store.setSymbol(symbol, forWaypoint: id)
        } catch {
            failure = error.localizedDescription
            return
        }
        undoManager.beginUndoGrouping()
        registerUndo("Change Icon") { model in model.setSymbol(waypoint.symbol, forWaypoint: id) }
        var changed = waypoint
        changed.symbol = symbol
        followWaypoint(changed)
        undoManager.setActionName("Change Icon")
        undoManager.endUndoGrouping()
    }

    /// Appends a point to the route being edited: a via point, or a
    /// shaping point, which only the right-click menu can place since a
    /// click makes a via point. The road follows the write; see
    /// `routeStraightLegs`.
    func appendPoint(_ coordinate: Coordinate, isVia: Bool, name: String? = nil, pinned: Bool = false) {
        guard var detail = editingDetail else { return }
        detail.appendVia(coordinate, name: name, isVia: isVia, isPinned: pinned)
        commit(detail, actionName: isVia ? "Add Point" : "Add Shaping Point")
    }

    /// Appends a waypoint to the route being edited as a stop, linked to
    /// it. Routing through waypoints is how BaseCamp users plan: pins
    /// first, then a route that visits them.
    func appendPoint(_ waypoint: Waypoint) {
        guard var detail = editingDetail else { return }
        detail.appendVia(waypoint)
        commit(detail, actionName: "Add Point")
    }

    /// Puts a waypoint into a route as a stop, before point `index` or at
    /// the end, from a drop in the sidebar. Any route, editing or not: the
    /// drop names the route, so there is nothing a mode would add.
    func addWaypoint(_ waypointID: String, toRoute routeID: String, before index: Int? = nil) {
        guard let waypoint = waypoints.first(where: { $0.id == waypointID }),
              var detail = routes.first(where: { $0.route.id == routeID }) else { return }
        detail.insertVia(waypoint, before: index ?? detail.points.count)
        commit(detail, actionName: "Add Point")
    }

    /// Reorders a route's points, as the sidebar's rows are dragged. See
    /// `RouteDetail.move(fromOffsets:toOffset:)` for which legs are routed
    /// again.
    func movePoints(routeID: String, fromOffsets source: IndexSet, toOffset destination: Int) {
        guard var detail = routes.first(where: { $0.route.id == routeID }) else { return }
        let before = detail.points
        detail.move(fromOffsets: source, toOffset: destination)
        guard detail.points != before else { return }
        // Handles name a position, and the positions just changed.
        selection = selection.filter { OverlayGeoJSON.parseHandle($0)?.routeID != routeID }
        commit(detail, actionName: "Reorder Points")
    }

    /// Carries a changed waypoint onto every route point made from it:
    /// name, symbol and position, with the legs either side of a moved
    /// one routed again. Each route is its own undo registration, inside
    /// whatever group the caller opened, so undoing the waypoint's edit
    /// undoes the routes' too.
    ///
    /// Not while undoing or redoing: the routes' own entries are on the
    /// stack beside the waypoint's and put the points back themselves.
    private func followWaypoint(_ waypoint: Waypoint) {
        guard !undoManager.isUndoing, !undoManager.isRedoing else { return }
        for detail in routes where !detail.indices(ofWaypoint: waypoint.id).isEmpty {
            var updated = detail
            guard updated.follow(waypoint) else { continue }
            commit(updated, actionName: "Edit Waypoint")
        }
    }

    /// Inserts a point into the leg of the edited route nearest a spot on
    /// its line, as the right-click menu asks.
    func insertPoint(_ coordinate: Coordinate, isVia: Bool) {
        guard var detail = editingDetail, let leg = detail.nearestLeg(to: coordinate) else { return }
        detail.insertVia(coordinate, inLeg: leg, isVia: isVia)
        commit(detail, actionName: isVia ? "Insert Point" : "Insert Shaping Point")
    }

    /// A new route whose first point is where the right-click landed, as
    /// one undo step: creating the route and placing the point are one
    /// gesture to the user, so undoing it should not leave an empty route
    /// behind for a second undo to collect.
    func startRoute(at coordinate: Coordinate, name: String? = nil, pinned: Bool = false) {
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
        newRoute()
        guard var detail = editingDetail else { return }
        detail.appendVia(coordinate, name: name, isPinned: pinned)
        commit(detail, actionName: "New Route")
        undoManager.setActionName("New Route")
    }

    /// A new route starting at a waypoint, linked to it.
    func startRoute(from waypoint: Waypoint) {
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
        newRoute()
        guard var detail = editingDetail else { return }
        detail.appendVia(waypoint)
        commit(detail, actionName: "New Route")
        undoManager.setActionName("New Route")
    }

    func reverseRoute(_ id: String) {
        guard var detail = routes.first(where: { $0.route.id == id }) else { return }
        detail.reverse()
        commit(detail, actionName: "Reverse Route")
    }

    func key(_ key: MapKey) {
        switch key {
        case .delete: deleteSelectedViaPoint()
        case .escape: finishEditing()
        }
    }

    /// Writes an edit and makes it undoable.
    ///
    /// Header-only changes made meanwhile in the sidebar survive, because
    /// only the points are written. The previous points are captured for
    /// undo and the new ones for redo, so the stack is a list of snapshots
    /// rather than of inverse operations, which is fewer things to get
    /// wrong for routes this small.
    private func commit(_ detail: RouteDetail, actionName: String) {
        let before = routes.first { $0.route.id == detail.route.id }?.points ?? []
        write(detail.route.id, points: detail.points, undoing: before, actionName: actionName)
    }

    private func write(_ routeID: String, points: [RoutePoint], undoing before: [RoutePoint], actionName: String) {
        do {
            try store.replacePoints(routeID: routeID, with: points)
        } catch {
            failure = error.localizedDescription
            return
        }

        // Applied to the in-memory routes at once rather than waiting for
        // the observation, so two quick clicks each build on the other.
        // The observation delivers the same rows a moment later.
        if let i = routes.firstIndex(where: { $0.route.id == routeID }) {
            routes[i].points = points
            rebuildOverlay()
            routeStraightLegs(of: routeID)
        }

        registerUndo(actionName) { model in
            model.write(routeID, points: before, undoing: points, actionName: actionName)
        }
    }

    /// Recolours whichever kind of item this is.
    ///
    /// The sidebar knows it is looking at a route or a track, but the
    /// selection it carries is just an id, so the lookup happens once here
    /// rather than at every call site.
    func setColor(_ color: ItemColor, for id: String) {
        do {
            if routes.contains(where: { $0.route.id == id }) {
                try store.setColor(color, forRoute: id)
            } else if tracks.contains(where: { $0.track.id == id }) {
                try store.setColor(color, forTrack: id)
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Renames whatever this id belongs to.
    ///
    /// An empty name is ignored rather than accepted. A track called nothing
    /// is unfindable in a sidebar and exports as a file with no name.
    func rename(_ id: String, to name: String) {
        do { try store.rename(id, to: name) } catch { failure = error.localizedDescription }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if var waypoint = waypoints.first(where: { $0.id == id }), !trimmed.isEmpty {
            waypoint.name = trimmed
            followWaypoint(waypoint)
        }
    }

    /// Deleting a waypoint can be undone; it is one row, and Delete sits
    /// on a right-click menu where a slip is easy. A route or a track is
    /// not, yet: a day's track is a few hundred thousand rows to hold.
    func delete(_ id: String) {
        if isList(id) {
            deleteList(id)
            return
        }
        if id == editingRouteID { editingRouteID = nil }
        if drag?.routeID == id { drag = nil }
        if waypointDrag?.id == id { waypointDrag = nil }
        do {
            if routes.contains(where: { $0.route.id == id }) {
                try store.deleteRoute(id: id)
            } else if tracks.contains(where: { $0.track.id == id }) {
                try store.deleteTrack(id: id)
            } else if let waypoint = waypoints.first(where: { $0.id == id }) {
                try store.deleteWaypoint(id: id)
                registerUndo("Delete Waypoint") { model in model.restore(waypoint) }
            } else {
                try store.deleteWaypoint(id: id)
            }
            selection.remove(id)
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Puts a deleted waypoint back as it was, id included, so anything
    /// that remembered it finds it again.
    private func restore(_ waypoint: Waypoint) {
        do {
            try store.save(waypoint)
        } catch {
            failure = error.localizedDescription
            return
        }
        registerUndo("Delete Waypoint") { model in model.delete(waypoint.id) }
    }
}
