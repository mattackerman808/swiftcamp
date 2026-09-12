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

    /// The last thing that went wrong, for the banner. Import failures are
    /// the common case and the user chose the file, so they are owed a
    /// reason rather than a silent no-op.
    var failure: String?

    private let store: LibraryStore
    @ObservationIgnored private var cancellables: [AnyDatabaseCancellable] = []
    @ObservationIgnored private var overlayTask: Task<Void, Never>?

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
        }
        track(ValueObservation.tracking { db in try Self.allTracks(db) }) { [weak self] in
            self?.tracks = $0
            self?.rebuildSummaries()
            self?.rebuildOverlay()
        }
        track(store.observeWaypoints()) { [weak self] in
            self?.waypoints = $0
            self?.rebuildOverlay()
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
            case .success(let count) where count.isEmpty:
                failure = "\(url.lastPathComponent) has no waypoints, routes or tracks in it."
            case .success:
                failure = nil
            case .failure(let error):
                failure = error.localizedDescription
            }
        }
    }

    private static func read(_ url: URL, into store: LibraryStore) async -> Result<GPXImportCount, Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                // A file the user picked from outside the app needs its
                // access scope opened. Without this the read fails only once
                // the app is sandboxed, which is a change nobody will connect
                // to this line.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }

                let document = try GPXReader.read(contentsOf: url)
                guard !document.isEmpty else { return .success(GPXImportCount()) }
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
