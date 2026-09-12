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

    private let store: LibraryStore
    @ObservationIgnored private var cancellables: [AnyDatabaseCancellable] = []
    @ObservationIgnored private var overlayTask: Task<Void, Never>?

    /// Items an import just created, waiting for their rows to arrive so
    /// they can be framed. The write and the observation that reports it are
    /// separate events, so the ids are known before the geometry is.
    @ObservationIgnored private var pendingFocus: Set<String> = []

    init(store: LibraryStore = LibraryStore()) {
        self.store = store
        observe()
        importAtLaunchIfRequested()
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
            self?.rebuildSummaries()
            self?.rebuildOverlay()
            self?.applyPendingFocus()
        }
        track(ValueObservation.tracking { db in try Self.allTracks(db) }) { [weak self] in
            self?.tracks = $0
            self?.rebuildSummaries()
            self?.rebuildOverlay()
            self?.applyPendingFocus()
        }
        track(store.observeWaypoints()) { [weak self] in
            self?.waypoints = $0
            self?.rebuildOverlay()
            self?.applyPendingFocus()
        }
        track(store.observeLists()) { [weak self] in self?.lists = $0 }
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
        let routes = self.routes
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

    func delete(_ id: String) {
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
