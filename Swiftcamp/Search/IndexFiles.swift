import Foundation
import GRDB

/// The SQLite files of an index on the CDN, fetched on first use and kept
/// under Caches, opened read-only, one download at a time per file
/// whoever asks. Shared by the place index and the address index, which
/// differ only in what their files hold.
actor IndexFiles {
    private let base: URL
    private let cache: URL
    private var databases: [String: DatabaseQueue] = [:]
    /// Files the CDN has none of: ocean, or beyond the extract.
    private var missing: Set<String> = []
    private var downloads: [String: Task<DatabaseQueue?, Never>] = [:]

    init(base: URL, cache: URL) {
        self.base = base
        self.cache = cache
    }

    /// Every file already open, for a search that should look beyond the
    /// one under the map.
    var open: [(name: String, database: DatabaseQueue)] {
        databases.map { ($0.key, $0.value) }
    }

    /// The files under a directory of the cache that earlier sessions
    /// fetched, newest first, for a search that should look wherever the
    /// map has ever been. Opening one costs nothing until it is read.
    func onDisk(under directory: String) -> [String] {
        let url = cache.appendingPathComponent(directory)
        guard let names = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return names.filter { $0.pathExtension == "sqlite" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
            .map { "\(directory)/\($0.lastPathComponent)" }
    }

    func database(_ name: String) async -> DatabaseQueue? {
        if let open = databases[name] { return open }
        if missing.contains(name) { return nil }
        if let inFlight = downloads[name] { return await inFlight.value }

        let task = Task { () -> DatabaseQueue? in
            let local = cache.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: local.path) {
                do {
                    let (temporary, response) = try await URLSession.shared.download(from: base.appendingPathComponent(name))
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                    try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: temporary, to: local)
                } catch {
                    NSLog("[Swiftcamp] search index %@ unavailable: %@", name, error.localizedDescription)
                    return nil
                }
            }
            var configuration = Configuration()
            configuration.readonly = true
            return try? DatabaseQueue(path: local.path, configuration: configuration)
        }
        downloads[name] = task
        let opened = await task.value
        downloads[name] = nil
        if let opened { databases[name] = opened } else { missing.insert(name) }
        return opened
    }
}
