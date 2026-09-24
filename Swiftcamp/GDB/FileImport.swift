import Foundation

/// One door for every file the library can take in: GPX from anywhere,
/// and GDB from MapSource and BaseCamp. Decided by the bytes, not the
/// extension, because a BaseCamp export keeps its `.gdb` name and a file
/// mailed around may have lost it.
enum FileImport {
    static func read(contentsOf url: URL) throws -> GPXDocument {
        try read(data: Data(contentsOf: url))
    }

    static func read(data: Data) throws -> GPXDocument {
        if GDBReader.looksLikeGDB(data) { return try GDBReader.read(data: data) }
        return try GPXReader.read(data: data)
    }
}
