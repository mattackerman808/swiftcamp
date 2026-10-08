import AppKit
import XCTest
@testable import Swiftcamp

/// The model's edits against a real store, through the observation that
/// delivers rows back, and their undo.
@MainActor
final class LibraryModelTests: XCTestCase {
    private var store: LibraryStore!
    private var model: LibraryModel!

    override func setUp() async throws {
        store = LibraryStore(try AppDatabase.inMemory())
        model = LibraryModel(store: store, launching: false)
    }

    /// Waits for the observation to catch up with a write.
    private func settle(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    private func sampleRoute(listID: String? = nil) -> RouteDetail {
        let route = Route(listID: listID, name: "Peak to Peak", color: "Magenta")
        let points = [
            RoutePoint(routeID: route.id, seq: 0, lat: 40.37, lon: -105.52, name: "Estes Park",
                       geometry: [Coordinate(lat: 40.37, lon: -105.52), Coordinate(lat: 40.0, lon: -105.5)]),
            RoutePoint(routeID: route.id, seq: 1, lat: 40.0, lon: -105.5, name: "Nederland"),
        ]
        return RouteDetail(route: route, points: points)
    }

    private func sampleTrack() -> TrackDetail {
        let track = Track(name: "Saturday", color: "Blue")
        let points = (0..<50).map { i in
            TrackPoint(trackID: track.id, seq: i, segment: 0, lat: 40 + Double(i) * 0.001, lon: -105,
                       elevation: 2000 + Double(i), time: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)))
        }
        return TrackDetail(track: track, points: points)
    }

    func testDeletingARouteUndoesWithItsPointsAndRedoes() async throws {
        let detail = sampleRoute()
        try store.save(detail)
        await settle { self.model.routes.count == 1 }

        model.delete(detail.route.id)
        await settle { self.model.routes.isEmpty }
        XCTAssertTrue(model.undoManager.canUndo)

        model.undoManager.undo()
        await settle { self.model.routes.count == 1 }
        let back = try XCTUnwrap(model.routes.first)
        XCTAssertEqual(back.route.id, detail.route.id)
        XCTAssertEqual(back.route.name, "Peak to Peak")
        XCTAssertEqual(back.points.map(\.name), ["Estes Park", "Nederland"])
        XCTAssertEqual(back.points.first?.geometry?.count, 2)

        model.undoManager.redo()
        await settle { self.model.routes.isEmpty }
    }

    func testDeletingATrackUndoesWithEveryPoint() async throws {
        let detail = sampleTrack()
        try store.save(detail.track, points: detail.points)
        await settle { self.model.tracks.count == 1 }

        model.delete(detail.track.id)
        await settle { self.model.tracks.isEmpty }
        model.undoManager.undo()
        await settle { self.model.tracks.count == 1 }
        XCTAssertEqual(model.tracks.first?.points.count, 50)
        XCTAssertEqual(model.tracks.first?.track.id, detail.track.id)
    }

    /// A list deleted after the route was is gone when the route comes
    /// back; the route returns unfiled rather than failing its foreign key.
    func testARouteWhoseListWentComesBackUnfiled() async throws {
        let list = LibraryList(name: "2026 Rockies")
        try store.save(list)
        let detail = sampleRoute(listID: list.id)
        try store.save(detail)
        await settle { self.model.routes.count == 1 && self.model.lists.count == 1 }

        model.delete(detail.route.id)
        await settle { self.model.routes.isEmpty }
        try store.deleteList(id: list.id)
        await settle { self.model.lists.isEmpty }

        model.undoManager.undo()
        await settle { self.model.routes.count == 1 }
        XCTAssertNil(model.routes.first?.route.listID)
        XCTAssertNil(model.failure)
    }

    // MARK: - Clipboard

    private func privatePasteboard() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("swiftcamp-tests-\(UUID().uuidString)"))
        board.clearContents()
        return board
    }

    /// A copy pasted into another list is a copy: new ids, a name of its
    /// own, filed where it landed, and a stop linked to the copy of its
    /// waypoint when both came together. The pasteboard holds the GPX.
    func testCopyPastesCopiesIntoTheList() async throws {
        model.pasteboard = privatePasteboard()
        let list = LibraryList(name: "Shared")
        try store.save(list)
        let camp = Waypoint(name: "Camp", lat: 40.0, lon: -105.5)
        try store.save(camp)
        var detail = sampleRoute()
        detail.points[1].waypointID = camp.id
        try store.save(detail)
        await settle { self.model.routes.count == 1 && self.model.waypoints.count == 1 && self.model.lists.count == 1 }

        model.selection = [detail.route.id, camp.id]
        model.copySelection()
        let gpx = try XCTUnwrap(model.pasteboard.string(forType: .string))
        XCTAssertTrue(gpx.contains("Peak to Peak"))

        model.paste(into: list.id)
        await settle { self.model.routes.count == 2 && self.model.waypoints.count == 2 }
        let copy = try XCTUnwrap(model.routes.first { $0.route.id != detail.route.id })
        let campCopy = try XCTUnwrap(model.waypoints.first { $0.id != camp.id })
        XCTAssertEqual(copy.route.name, "Peak to Peak 2")
        XCTAssertEqual(copy.route.listID, list.id)
        XCTAssertEqual(campCopy.listID, list.id)
        XCTAssertEqual(copy.points[1].waypointID, campCopy.id)
        XCTAssertEqual(copy.points.first?.geometry?.count, 2)
        XCTAssertEqual(model.selection, [copy.route.id, campCopy.id])

        model.undoManager.undo()
        await settle { self.model.routes.count == 1 && self.model.waypoints.count == 1 }
    }

    /// A cut takes the items away at once and the paste puts the same
    /// items back, ids and all, in the list it lands in; a second paste
    /// of the same cut makes copies.
    func testCutAndPasteMovesTheItemsOnce() async throws {
        model.pasteboard = privatePasteboard()
        let list = LibraryList(name: "Elsewhere")
        try store.save(list)
        let detail = sampleTrack()
        try store.save(detail.track, points: detail.points)
        await settle { self.model.tracks.count == 1 && self.model.lists.count == 1 }

        model.selection = [detail.track.id]
        model.cutSelection()
        await settle { self.model.tracks.isEmpty }

        model.paste(into: list.id)
        await settle { self.model.tracks.count == 1 }
        XCTAssertEqual(model.tracks.first?.track.id, detail.track.id)
        XCTAssertEqual(model.tracks.first?.track.listID, list.id)
        XCTAssertEqual(model.tracks.first?.points.count, 50)

        model.paste(into: list.id)
        await settle { self.model.tracks.count == 2 }
        XCTAssertEqual(Set(model.tracks.map(\.track.name)), ["Saturday", "Saturday 2"])
    }

    /// GPX put on the pasteboard by another app is imported, into the
    /// list asked for, and undo takes it out again.
    func testPastingGPXFromElsewhereImportsIt() async throws {
        model.pasteboard = privatePasteboard()
        let list = LibraryList(name: "From the forum")
        try store.save(list)
        await settle { self.model.lists.count == 1 }
        model.pasteboard.setString("""
            <?xml version="1.0" encoding="UTF-8"?>
            <gpx version="1.1" creator="elsewhere" xmlns="http://www.topografix.com/GPX/1/1">
              <wpt lat="39.5" lon="-106.0"><name>Trailhead</name></wpt>
            </gpx>
            """, forType: .string)

        model.paste(into: list.id)
        await settle { self.model.waypoints.count == 1 }
        XCTAssertEqual(model.waypoints.first?.name, "Trailhead")
        XCTAssertEqual(model.waypoints.first?.listID, list.id)

        model.undoManager.undo()
        await settle { self.model.waypoints.isEmpty }
    }

    // MARK: - Track points

    /// Moving, adding and erasing fixes edit the track in place, each one
    /// undo, and undo walks back through them to the recording as it was.
    func testTrackPointEditsUndoInOrder() async throws {
        let detail = sampleTrack()
        try store.save(detail.track, points: detail.points)
        await settle { self.model.tracks.count == 1 }
        let id = detail.track.id

        model.editTrack(id)
        XCTAssertEqual(model.editingTrackID, id)
        model.moveTrackPoint(id, index: 10, to: Coordinate(lat: 40.5, lon: -105.1))
        model.insertTrackPoint(id, at: Coordinate(lat: 40.0205, lon: -105))
        XCTAssertEqual(model.tracks.first?.points.count, 51)
        model.deleteTrackPoints(id, 0..<5, actionName: "Delete Track Points")
        XCTAssertEqual(model.tracks.first?.points.count, 46)
        XCTAssertEqual(model.tracks.first?.track.id, id, "edited in place, not as a new track")

        let stored = try store.trackPoints(trackID: id)
        XCTAssertEqual(stored.count, 46)
        XCTAssertEqual(stored.map(\.seq), Array(0..<46))

        model.undoManager.undo()
        model.undoManager.undo()
        model.undoManager.undo()
        let back = try store.trackPoints(trackID: id)
        XCTAssertEqual(back.map(\.lat), detail.points.map(\.lat))
        XCTAssertEqual(back.map(\.time), detail.points.map(\.time))
    }

    /// A track is never erased down to fewer than two fixes.
    func testATrackKeepsTwoFixes() async throws {
        let detail = sampleTrack()
        try store.save(detail.track, points: detail.points)
        await settle { self.model.tracks.count == 1 }
        model.deleteTrackPoints(detail.track.id, 0..<49, actionName: "Delete Track Points")
        XCTAssertEqual(model.tracks.first?.points.count, 50)
        model.deleteTrackPoints(detail.track.id, 0..<48, actionName: "Delete Track Points")
        XCTAssertEqual(model.tracks.first?.points.count, 2)
    }

    func testDeletingTheSelectionIsOneUndo() async throws {
        let route = sampleRoute()
        let track = sampleTrack()
        let waypoint = Waypoint(name: "Camp", lat: 40.1, lon: -105.6)
        try store.save(route)
        try store.save(track.track, points: track.points)
        try store.save(waypoint)
        await settle { self.model.routes.count == 1 && self.model.tracks.count == 1 && self.model.waypoints.count == 1 }

        model.selection = [route.route.id, track.track.id, waypoint.id]
        model.deleteSelection()
        await settle { self.model.routes.isEmpty && self.model.tracks.isEmpty && self.model.waypoints.isEmpty }

        model.undoManager.undo()
        await settle { self.model.routes.count == 1 && self.model.tracks.count == 1 && self.model.waypoints.count == 1 }
        XCTAssertFalse(model.undoManager.canUndo)
    }
}
