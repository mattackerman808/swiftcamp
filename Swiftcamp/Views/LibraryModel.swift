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
        didSet { rebuildOverlay() }
    }

    /// The map's input. A value, `Equatable`, rebuilt only when the content
    /// behind it changes — see `MapWebView` for why that matters.
    private(set) var overlay: MapOverlay = .empty

    /// The last thing that went wrong, for the banner. Import failures are
    /// the common case and the user chose the file, so they are owed a
    /// reason rather than a silent no-op.
    var failure: String?

    private let store: LibraryStore
    @ObservationIgnored private var cancellables: [AnyDatabaseCancellable] = []

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
            self?.rebuildOverlay()
        }
        track(ValueObservation.tracking { db in try Self.allTracks(db) }) { [weak self] in
            self?.tracks = $0
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

    private func rebuildOverlay() {
        overlay = MapOverlay.make(routes: routes,
                                  tracks: tracks,
                                  waypoints: waypoints,
                                  selection: selection)
    }

    // MARK: - Import and export

    func importGPX(from url: URL) {
        do {
            // A file the user picked from outside the app needs its access
            // scope opened. Without this the read fails only once the app is
            // sandboxed, which is a change nobody will connect to this line.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let document = try GPXReader.read(contentsOf: url)
            guard !document.isEmpty else {
                failure = "\(url.lastPathComponent) has no waypoints, routes or tracks in it."
                return
            }
            try store.importGPX(document)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    func exportGPX(to url: URL) {
        do {
            let document = try store.exportGPX(
                waypointIDs: waypoints.map(\.id).filter(isSelectedOrNothingIs),
                routeIDs: routes.map(\.route.id).filter(isSelectedOrNothingIs),
                trackIDs: tracks.map(\.track.id).filter(isSelectedOrNothingIs))
            try GPXWriter.data(document).write(to: url, options: .atomic)
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
