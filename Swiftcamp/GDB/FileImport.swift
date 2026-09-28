import Foundation

/// One door for every file the library can take in: GPX from anywhere,
/// GDB from MapSource and BaseCamp, and BaseCamp's Backup files. Decided
/// by the bytes, not the extension, because a BaseCamp export keeps its
/// `.gdb` name and a file mailed around may have lost it.
enum FileImport {
    /// Reads the file, and for a GDB also the folder file BaseCamp keeps
    /// beside its autosave, so the lists come with the library.
    static func read(contentsOf url: URL) throws -> GPXDocument {
        // Mapped, because a backup can carry photos and maps of which
        // only the library is read.
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if ZipArchive.looksLikeZip(data) { return try readBackup(data: data) }
        var document = try read(data: data)
        if !document.isEmpty, let folders = folderFile(beside: url),
           let lists = try? GFIReader.read(contentsOf: folders) {
            document.lists = lists
        }
        return document
    }

    static func read(data: Data) throws -> GPXDocument {
        if ZipArchive.looksLikeZip(data) { return try readBackup(data: data) }
        if GDBReader.looksLikeGDB(data) { return try GDBReader.read(data: data) }
        return try GPXReader.read(data: data)
    }

    enum BackupFailure: LocalizedError {
        case noLibrary

        var errorDescription: String? {
            "The archive has no BaseCamp library in it. A BaseCamp backup keeps one at Database/<version>/AllData.gdb."
        }
    }

    /// A BaseCamp Backup: a zip of BaseCamp's Application Support folder,
    /// the same on the Mac and on Windows, so the library inside is the
    /// autosave the Import BaseCamp Library command reads in place, with
    /// its folder file beside it. Found by path rather than assumed at the
    /// root, since a backup zipped up by hand may sit a folder deeper.
    static func readBackup(data: Data) throws -> GPXDocument {
        let archive = try ZipArchive(data: data)
        let libraries = archive.entries.filter {
            let parts = $0.path.split(separator: "/")
            return parts.count >= 3
                && parts[parts.count - 1].caseInsensitiveCompare("AllData.gdb") == .orderedSame
                && parts[parts.count - 3].caseInsensitiveCompare("Database") == .orderedSame
                && !parts.contains("__MACOSX")
        }
        guard let library = newestVersion(of: libraries, folder: { URL(fileURLWithPath: $0.path).deletingLastPathComponent() })
        else { throw BackupFailure.noLibrary }

        var document = try GDBReader.read(data: archive.contents(of: library))
        let folderPath = library.path.dropLast("AllData.gdb".count) + "FolderData.gfi"
        if !document.isEmpty,
           let folders = archive.entries.first(where: { $0.path.caseInsensitiveCompare(folderPath) == .orderedSame }),
           let lists = try? GFIReader.read(data: archive.contents(of: folders)) {
            document.lists = lists
        }
        return document
    }

    /// Of several libraries in version folders, the newest: 4.10 is newer
    /// than 4.8, so the folders sort numerically, not as text.
    private static func newestVersion<T>(of candidates: [T], folder: (T) -> URL) -> T? {
        candidates.max {
            folder($0).lastPathComponent.localizedStandardCompare(folder($1).lastPathComponent) == .orderedAscending
        }
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
        let candidates = versions
            .map { $0.appendingPathComponent("AllData.gdb") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return newestVersion(of: candidates) { $0.deletingLastPathComponent() }
    }
}
