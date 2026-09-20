import Foundation
import GRDB
import Observation

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
            #if os(macOS)
            case "focusSearch":
                _ = Harness.focusSearchField()
            case "type":
                Harness.type(step["text"] as? String ?? "")
            case "snapshotWindows":
                if let path = step["path"] as? String { Harness.snapshotWindows(to: path) }
            #endif
            case "mode":
                // On the route being edited, else the selected one.
                if let mode = (step["value"] as? String).flatMap(RoutingMode.init(rawValue:)),
                   let id = editingRouteID ?? routes.first(where: { selection.contains($0.route.id) })?.route.id {
                    setMode(mode, forRoute: id)
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

    /// The library's routes as JSON, for a script to assert against.
    /// With `geometry`, each point also carries its leg's path as
    /// `[lon, lat]` pairs, so a check can find a coordinate on the line to
    /// grab. Off by default because a road leg is thousands of them.
    private func dump(to path: String, geometry: Bool = false) {
        let routes = self.routes.map { detail -> [String: Any] in
            ["name": detail.route.name,
             "editing": detail.route.id == editingRouteID,
             "points": detail.points.map { p -> [String: Any] in
                 var out: [String: Any] = ["seq": p.seq, "lat": p.lat, "lon": p.lon,
                                           "name": p.name ?? "", "via": p.isVia,
                                           "geometry": p.geometry?.count ?? 0]
                 if geometry { out["path"] = (p.geometry ?? []).map { [$0.lon, $0.lat] } }
                 return out
             }]
        }
        let payload: [String: Any] = ["routes": routes,
                                      "waypoints": waypoints.map { ["name": $0.name, "lat": $0.lat, "lon": $0.lon,
                                                                    "symbol": $0.symbol as Any] },
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
            self?.rebuildOverlay()
            self?.applyPendingFocus()
        }
        track(ValueObservation.tracking { db in try Self.allTracks(db) }) { [weak self] in
            self?.tracks = $0
            self?.refreshHasContent()
            self?.rebuildSummaries()
            self?.rebuildOverlay()
            self?.applyPendingFocus()
        }
        track(store.observeWaypoints()) { [weak self] in
            self?.waypoints = $0
            self?.refreshHasContent()
            self?.rebuildOverlay()
            self?.applyPendingFocus()
        }
        track(store.observeLists()) { [weak self] in self?.lists = $0 }
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
        var routes = self.routes
        if let drag, let i = routes.firstIndex(where: { $0.route.id == drag.routeID }) {
            routes[i].points = drag.points
        }
        let tracks = self.tracks
        let waypoints = self.waypoints
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
        for detail in routes {
            let vias = detail.viaPoints.count
            let shaping = detail.points.count - vias
            var summary = "\(vias) via point\(vias == 1 ? "" : "s")"
            if shaping > 0 { summary += ", \(shaping) shaping" }
            summary += " · \(Self.miles(detail.length))"
            if detail.route.mode != .road { summary += " · \(detail.route.mode.title)" }
            out[detail.route.id] = summary

            for (seq, metres) in detail.distancesFromStart() {
                points[OverlayGeoJSON.handle(detail.route.id, seq)] = Self.miles(metres)
            }
        }
        for detail in tracks {
            out[detail.track.id] = "\(detail.points.count) points · \(Self.miles(detail.length))"
        }
        summaries = out
        pointSummaries = points
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

                let document = try GPXReader.read(contentsOf: url)
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

    /// Imports GPX that came from somewhere other than a file, such as a
    /// device.
    func importGPX(data: Data, named name: String) {
        do {
            let document = try GPXReader.read(data: data)
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
                          mode: Self.defaultMode)
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
        let mode = detail.route.mode

        Task {
            // The tiles at each leg's ends, together, before the engine
            // asks for them one at a time.
            let ends = legs.flatMap { [detail.points[$0].coordinate, detail.points[$0 + 1].coordinate] }
            await prefetch?.warm(around: ends)

            let started = ContinuousClock.now
            let routed = await Task.detached(priority: .userInitiated) { () -> [RoutePoint]? in
                guard let shaping = RoutingEngine.shaping(for: mode) else { return nil }
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
        detail.route.mode.rawValue + detail.points.map {
            "|\($0.seq):\($0.lat),\($0.lon),\($0.isVia),\($0.isPinned)"
        }.joined()
    }

    private static func legKey(_ detail: RouteDetail, _ leg: Int) -> String {
        let a = detail.points[leg], b = detail.points[leg + 1]
        return "\(detail.route.mode.rawValue):\(a.lat),\(a.lon)->\(b.lat),\(b.lon)"
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
            appendPoint(waypoint.coordinate, isVia: true, name: waypoint.name, pinned: true)
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
        guard var detail = routes.first(where: { $0.route.id == event.routeID }) else { return }

        switch event.phase {
        case .begin:
            let seq: Int
            if let grabbed = event.seq {
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
            drag = Drag(routeID: detail.route.id, seq: seq, inserted: event.seq == nil, base: detail.points)

        case .move:
            guard let drag, drag.routeID == event.routeID else { return }
            drag.pending = event.coordinate
            if !drag.inFlight { routeDrag(drag) }

        case .end:
            guard let drag, drag.routeID == event.routeID else { return }
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
        let mode = detail.route.mode
        Task {
            // The moving point and its neighbours: a preview routes the
            // two legs between them.
            let around = [seq - 1, seq + 1].filter { drag.base.indices.contains($0) }.map { drag.base[$0].coordinate }
            await prefetch?.warm(around: [target] + around)

            let started = ContinuousClock.now
            let points = await Task.detached(priority: .userInitiated) { () -> [RoutePoint] in
                var working = base
                let shaping = RoutingEngine.previewShaping(for: mode) ?? (snap: .never, shape: RouteEditing.straight)
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
        let before = (mode: routes[i].route.mode, points: routes[i].points)
        var detail = routes[i]
        detail.route.mode = mode
        detail.straightenAll()
        apply(mode: mode, points: detail.points, to: id, undoing: before, actionName: "Change Routing")
    }

    private func apply(mode: RoutingMode, points: [RoutePoint], to routeID: String,
                       undoing before: (mode: RoutingMode, points: [RoutePoint]), actionName: String) {
        do {
            try store.setMode(mode, forRoute: routeID)
            try store.replacePoints(routeID: routeID, with: points)
        } catch {
            failure = error.localizedDescription
            return
        }
        if let i = routes.firstIndex(where: { $0.route.id == routeID }) {
            routes[i].route.mode = mode
            routes[i].points = points
            rebuildOverlay()
            routeStraightLegs(of: routeID)
        }
        registerUndo(actionName) { model in
            model.apply(mode: before.mode, points: before.points, to: routeID,
                        undoing: (mode, points), actionName: actionName)
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
            }

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
            return items

        case .waypoint(let id):
            guard let waypoint = waypoints.first(where: { $0.id == id }) else { return [] }
            var items: [MapMenuItem] = []
            if editingRouteID != nil {
                items.append(MapMenuItem(title: "Add Via Point at \(waypoint.name)") {
                    self.appendPoint(waypoint.coordinate, isVia: true, name: waypoint.name, pinned: true)
                })
            }
            items.append(MapMenuItem(title: "New Route from \(waypoint.name)") {
                self.startRoute(at: waypoint.coordinate, name: waypoint.name, pinned: true)
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

        case .track:
            return []
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

    /// Asks the sidebar to open its rename field on an item.
    func requestRename(_ id: String) {
        selection = [id]
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
        registerUndo("Change Icon") { model in model.setSymbol(waypoint.symbol, forWaypoint: id) }
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
    }

    /// Deleting a waypoint can be undone; it is one row, and Delete sits
    /// on a right-click menu where a slip is easy. A route or a track is
    /// not, yet: a day's track is a few hundred thousand rows to hold.
    func delete(_ id: String) {
        if id == editingRouteID { editingRouteID = nil }
        if drag?.routeID == id { drag = nil }
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
