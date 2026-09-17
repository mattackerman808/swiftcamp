import Foundation
import Observation

/// Fetches graph tiles before a route asks for them.
///
/// Valhalla fetches a tile the moment a search needs it, one at a time,
/// and a cold cross-country leg was sixty-one of them in series with the
/// window frozen for the wait. This pulls the highway and arterial levels
/// for the whole graph in the background after launch, about a gigabyte
/// compressed, and the local tiles under the visible map as it moves,
/// twelve at a time over one connection pool. Tiles land in the engine's
/// own cache with the engine's own names, so it never knows the
/// difference, and a launch that finds them on disk costs a listing.
@MainActor
@Observable
final class RoutingPrefetch {
    struct Progress: Equatable {
        var fetchedBytes: Int64
        var totalBytes: Int64
        var done = false
    }

    /// The background fill's progress, for the sidebar. Nil until the
    /// index has been read.
    private(set) var progress: Progress?

    private let base: URL
    private let cache: URL
    private let session: URLSession
    @ObservationIgnored private var viewportTask: Task<Void, Never>?

    /// `index.json` beside the tiles: which tile ids exist per level, and
    /// their bytes, written by the publish step from the gzipped tree.
    private struct Index: Decodable {
        struct Level: Decodable {
            var tiles: [Int]
            var bytes: Int64
        }
        var levels: [String: Level]
    }

    init(base: URL, cache: URL) {
        self.base = base
        self.cache = cache
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 12
        session = URLSession(configuration: configuration)
    }

    /// The highway and arterial levels, whole. Skips tiles already on
    /// disk, whoever put them there.
    func fillBackground() {
        Task { await fill() }
    }

    /// The local tiles under a view, a screenful at most, for the drag
    /// that is about to happen there. A new view cancels the last.
    func warm(_ box: BoundingBox) {
        viewportTask?.cancel()
        let ids = Array(RoutingTiles.ids(in: box, level: RoutingTiles.local).prefix(48))
        viewportTask = Task {
            let started = ContinuousClock.now
            await fetch(ids.map { (RoutingTiles.local, $0) }, priority: .utility, counting: false)
            NSLog("[Swiftcamp] routing prefetch: %d local tiles under the view in %.1f s", ids.count,
                  Double((ContinuousClock.now - started).components.seconds))
        }
    }

    private func fill() async {
        guard let index = await loadIndex() else { return }
        let levels = [RoutingTiles.highways, RoutingTiles.arterials]
        let work = levels.flatMap { level in
            (index.levels["\(level.index)"]?.tiles ?? []).map { (level, $0) }
        }
        let total = levels.reduce(Int64(0)) { $0 + (index.levels["\($1.index)"]?.bytes ?? 0) }
        progress = Progress(fetchedBytes: 0, totalBytes: total)
        let started = ContinuousClock.now
        NSLog("[Swiftcamp] routing prefetch: %d highway and arterial tiles, %lld MB", work.count, total / 1_000_000)
        await fetch(work, priority: .background, counting: true)
        progress?.done = true
        NSLog("[Swiftcamp] routing prefetch done: %lld MB fetched in %.0f s",
              (progress?.fetchedBytes ?? 0) / 1_000_000,
              Double((ContinuousClock.now - started).components.seconds))
    }

    private func loadIndex() async -> Index? {
        do {
            let (data, _) = try await session.data(from: base.appendingPathComponent("index.json"))
            return try JSONDecoder().decode(Index.self, from: data)
        } catch {
            NSLog("[Swiftcamp] routing index unavailable: %@", error.localizedDescription)
            return nil
        }
    }

    /// Twelve in flight at a time. The children run off the main actor;
    /// only the progress tally comes back here.
    private func fetch(_ tiles: [(RoutingTiles.Level, Int)], priority: TaskPriority, counting: Bool) async {
        let base = base, cache = cache, session = session
        await withTaskGroup(of: Int64.self) { group in
            var pending = tiles.makeIterator()
            func enqueue() {
                guard let (level, id) = pending.next() else { return }
                group.addTask(priority: priority) {
                    await Self.download(level: level, id: id, base: base, cache: cache, session: session)
                }
            }
            for _ in 0..<12 { enqueue() }
            for await bytes in group {
                if Task.isCancelled { break }
                if counting { progress?.fetchedBytes += bytes }
                enqueue()
            }
        }
    }

    /// One tile, written as the engine writes its own: gzipped, under the
    /// tile's path, moved into place whole so a half-written file is never
    /// read. Returns the bytes fetched, zero for a tile already present.
    nonisolated private static func download(level: RoutingTiles.Level, id: Int,
                                             base: URL, cache: URL, session: URLSession) async -> Int64 {
        let path = RoutingTiles.path(level: level, id: id) + ".gph.gz"
        let destination = cache.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: destination.path) { return 0 }

        do {
            let (temporary, response) = try await session.download(from: base.appendingPathComponent(path))
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return 0 }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? Int64) ?? 0
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            // The engine may have fetched the same tile meanwhile; either
            // copy is the same bytes, so losing the race is fine.
            try? FileManager.default.moveItem(at: temporary, to: destination)
            return bytes
        } catch {
            return 0
        }
    }
}
