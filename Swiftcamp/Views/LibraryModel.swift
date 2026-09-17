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

    /// The editor's copy of the route's points while a drag is in flight.
    ///
    /// The library is written once, when the drag ends. Between mouse
    /// moves this is what the overlay draws, so the line follows the
    /// pointer without a transaction and an observation delivery per frame.
    @ObservationIgnored private var dragged: [RoutePoint]?

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

    init(store: LibraryStore = LibraryStore()) {
        self.store = store
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
    /// path. Actions are `newRoute`, `click`, `drag`, `key`, `undo`, `redo`,
    /// `done`, `wait` and `dump`, as JSON objects with an `action` key.
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
            case "click", "drag", "key", "probe":
                pageEvent = MapPageEvent(id: (pageEvent?.id ?? 0) + 1,
                                         kind: step["action"] as! String,
                                         lon: number("lon", step), lat: number("lat", step),
                                         toLon: number("toLon", step), toLat: number("toLat", step),
                                         key: step["key"] as? String ?? "")
            case "dump":
                if let path = step["path"] as? String { dump(to: path) }
            default:
                NSLog("[Swiftcamp] script: unknown step %@", String(describing: step))
            }
        }
    }

    /// The library's routes as JSON, for a script to assert against.
    private func dump(to path: String) {
        let routes = self.routes.map { detail -> [String: Any] in
            ["name": detail.route.name,
             "editing": detail.route.id == editingRouteID,
             "points": detail.points.map { p -> [String: Any] in
                 ["seq": p.seq, "lat": p.lat, "lon": p.lon,
                  "name": p.name ?? "", "geometry": p.geometry?.count ?? 0]
             }]
        }
        let payload: [String: Any] = ["routes": routes,
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
        if let editingRouteID, let dragged,
           let i = routes.firstIndex(where: { $0.route.id == editingRouteID }) {
            routes[i].points = dragged
        }
        let tracks = self.tracks
        let waypoints = self.waypoints
        let selection = self.selection

        // Only the newest rebuild matters. Three observations can land in
        // quick succession on one import, and the first two describe a state
        // nobody will ever see.
        overlayTask?.cancel()
        overlayTask = Task {
            let built = await Task.detached(priority: .userInitiated) {
                MapOverlay.make(routes: routes, tracks: tracks,
                                waypoints: waypoints, selection: selection)
            }.value

            guard !Task.isCancelled else { return }
            if built != overlay { overlay = built }
        }
    }

    /// Row subtitles, recomputed only when the rows themselves change.
    private func rebuildSummaries() {
        var out: [String: String] = [:]
        for detail in routes {
            out[detail.route.id] = "\(detail.viaPoints.count) via points · \(Self.miles(detail.length))"
        }
        for detail in tracks {
            out[detail.track.id] = "\(detail.points.count) points · \(Self.miles(detail.length))"
        }
        summaries = out
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
                          color: ItemColor.default(for: routes.count + tracks.count).name)
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
        dragged = nil
        if let detail = routes.first(where: { $0.route.id == id }), detail.points.isEmpty {
            do { try store.deleteRoute(id: id) } catch { failure = error.localizedDescription }
            selection.remove(id)
        }
    }

    /// How legs get their shape: the road, when a routing graph is loaded,
    /// and a straight line otherwise. Resolved once; the engine is a
    /// process-wide singleton and the choice does not change mid-session.
    @ObservationIgnored private lazy var shape: RouteEditing.LegShaper =
        RoutingEngine.shared?.legShaper ?? RouteEditing.straight

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
            detail.appendVia(click.coordinate, shape: shape)
            commit(detail, actionName: "Add Point")
            return true

        case .waypoint(let id):
            // Routing through a waypoint is how BaseCamp users plan: pins
            // first, then a route that visits them. The via point takes the
            // waypoint's exact position and its name.
            guard let waypoint = waypoints.first(where: { $0.id == id }) else { return false }
            detail.appendVia(waypoint.coordinate, name: waypoint.name, shape: shape)
            commit(detail, actionName: "Add Point")
            return true

        case .routeLine(let routeID) where routeID == detail.route.id:
            guard let leg = detail.nearestLeg(to: click.coordinate) else { return false }
            detail.insertVia(click.coordinate, inLeg: leg, shape: shape)
            commit(detail, actionName: "Insert Point")
            return true

        case .viaPoint(let routeID, _) where routeID == detail.route.id:
            return false    // selects the handle, so Delete knows which

        case .viaPoint, .routeLine, .track:
            return false
        }
    }

    /// A via point being dragged. Moves redraw; the end is the edit.
    func drag(_ drag: MapDrag) {
        guard var detail = editingDetail, drag.routeID == detail.route.id else { return }
        if let dragged { detail.points = dragged }

        switch drag.phase {
        case .move:
            // Straight legs while the mouse is down. Routing runs tens of
            // milliseconds per leg and a drag reports every frame; the road
            // is computed once, on release.
            detail.moveVia(at: drag.seq, to: drag.coordinate)
            dragged = detail.points
            rebuildOverlay()
        case .end:
            dragged = nil
            detail.moveVia(at: drag.seq, to: drag.coordinate, shape: shape)
            commit(detail, actionName: "Move Point")
        }
    }

    /// Removes the selected via point of the route being edited.
    func deleteSelectedViaPoint() {
        guard var detail = editingDetail,
              let seq = selection.compactMap(OverlayGeoJSON.parseHandle).first(where: { $0.routeID == detail.route.id })?.seq
        else { return }
        detail.removeVia(at: seq, shape: shape)
        selection.remove(OverlayGeoJSON.handle(detail.route.id, seq))
        commit(detail, actionName: "Delete Point")
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

    func delete(_ id: String) {
        if id == editingRouteID {
            editingRouteID = nil
            dragged = nil
        }
        do {
            if routes.contains(where: { $0.route.id == id }) {
                try store.deleteRoute(id: id)
            } else if tracks.contains(where: { $0.track.id == id }) {
                try store.deleteTrack(id: id)
            } else {
                try store.deleteWaypoint(id: id)
            }
            selection.remove(id)
        } catch {
            failure = error.localizedDescription
        }
    }
}
