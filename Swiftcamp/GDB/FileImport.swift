import Foundation

/// One door for every file the library can take in: GPX from anywhere,
/// and GDB from MapSource and BaseCamp. Decided by the bytes, not the
/// extension, because a BaseCamp export keeps its `.gdb` name and a file
/// mailed around may have lost it.
enum FileImport {
    /// Reads the file, and for a GDB also the folder file BaseCamp keeps
    /// beside its autosave, so the lists come with the library.
    static func read(contentsOf url: URL) throws -> GPXDocument {
        var document = try read(data: Data(contentsOf: url))
        if !document.isEmpty, let folders = folderFile(beside: url),
           let lists = try? GFIReader.read(contentsOf: folders) {
            document.lists = lists
        }
        return document
    }

    static func read(data: Data) throws -> GPXDocument {
        if GDBReader.looksLikeGDB(data) { return try GDBReader.read(data: data) }
        return try GPXReader.read(data: data)
    }

    /// `FolderData.gfi` next to an `AllData.gdb`, or a `.gfi` with the
    /// file's own name; nil when neither exists. Only a library has one.
    static func folderFile(beside url: URL) -> URL? {
        guard url.pathExtension.lowercased() == "gdb" else { return nil }
        let candidates = [url.deletingLastPathComponent().appendingPathComponent("FolderData.gfi"),
                          url.deletingPathExtension().appendingPathExtension("gfi")]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// BaseCamp's own library on this Mac: the autosave under the newest
    /// version folder in its Application Support directory, or nil when
    /// BaseCamp was never run here. Reading it in place is how a user
    /// leaves BaseCamp without opening it, which matters on the day it
    /// stops opening.
    static func baseCampLibrary() -> URL? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let database = support?.appendingPathComponent("Garmin/BaseCamp/Database", isDirectory: true),
              let versions = try? FileManager.default.contentsOfDirectory(at: database, includingPropertiesForKeys: nil)
        else { return nil }
        // Version folders sort numerically: 4.10 is newer than 4.8.
        let candidates = versions
            .map { $0.appendingPathComponent("AllData.gdb") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.deletingLastPathComponent().lastPathComponent
                .localizedStandardCompare($1.deletingLastPathComponent().lastPathComponent) == .orderedAscending }
        return candidates.last
    }
}
