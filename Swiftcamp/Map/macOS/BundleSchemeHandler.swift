#if os(macOS)
import Foundation
import WebKit
import UniformTypeIdentifiers

/// Serves the app bundle to the web view over a private URL scheme, with
/// HTTP range support.
///
/// This exists because of one hard constraint: PMTiles is *built* on range
/// requests. The archive is a single file and the reader fetches byte
/// ranges out of it. In a web view that means `fetch()` with a `Range`
/// header, and `file://` URLs cannot be fetched at all — WebKit blocks
/// them. So the bundle has to be served through something that speaks
/// enough HTTP to answer a range, and a `WKURLSchemeHandler` is that
/// something without running an actual local HTTP server.
///
/// Everything — HTML, JS, CSS, and the `.pmtiles` archive — is served from
/// this one scheme so the page and its fetches share an origin and no CORS
/// question ever arises.
///
/// URLs look like `sc-tiles://app/basemap/world-z6.pmtiles`; the path maps
/// directly onto the bundle's resource directory.
final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "sc-tiles"
    static let host = "app"

    /// Base URL of the page, used as the web view's entry point.
    static var indexURL: URL {
        URL(string: "\(scheme)://\(host)/web/index.html")!
    }

    /// The style source URL handed to MapLibre GL JS.
    ///
    /// PMTiles' MapLibre protocol captures everything between `pmtiles://`
    /// and the trailing `/z/x/y`, so nesting our scheme inside it is fine
    /// and resolves back to this handler.
    static var pmtilesSourceURL: String {
        "pmtiles://\(scheme)://\(host)/basemap/\(BasemapSource.bundledName).pmtiles"
    }

    private let root: URL

    override init() {
        self.root = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        super.init()
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let file = resolve(url) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }

            let total = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?
                .int64Value ?? 0

            if let header = task.request.value(forHTTPHeaderField: "Range"),
               let range = ByteRange(header: header, total: total) {
                try handle.seek(toOffset: UInt64(range.start))
                let data = handle.readData(ofLength: range.length)
                task.didReceive(partialResponse(url: url, range: range, total: total, file: file))
                task.didReceive(data)
            } else {
                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                task.didReceive(fullResponse(url: url, length: data.count, file: file))
                task.didReceive(data)
            }
            task.didFinish()
        } catch {
            task.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    // MARK: - Path resolution

    /// Maps a request URL onto a file inside the bundle.
    ///
    /// Rejects anything that escapes the resource directory. The inputs
    /// here are our own HTML and the PMTiles library rather than user
    /// content, but a scheme handler that will read any path it is handed
    /// is the kind of thing that becomes a problem later.
    private func resolve(_ url: URL) -> URL? {
        let relative = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        guard !relative.isEmpty else { return nil }

        let candidate = root.appendingPathComponent(relative).standardizedFileURL
        guard candidate.path.hasPrefix(root.standardizedFileURL.path) else { return nil }
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    // MARK: - Responses

    private func mimeType(for file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "html": return "text/html"
        case "js":   return "text/javascript"
        case "css":  return "text/css"
        case "json": return "application/json"
        // No registered type for PMTiles; the reader does not inspect it.
        case "pmtiles": return "application/octet-stream"
        default:
            return UTType(filenameExtension: file.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
        }
    }

    private func fullResponse(url: URL, length: Int, file: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": mimeType(for: file),
            "Content-Length": "\(length)",
            // Without this the PMTiles reader will not attempt ranges and
            // tries to pull the whole archive into memory instead.
            "Accept-Ranges": "bytes",
        ])!
    }

    private func partialResponse(url: URL, range: ByteRange, total: Int64, file: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": mimeType(for: file),
            "Content-Length": "\(range.length)",
            "Content-Range": "bytes \(range.start)-\(range.end)/\(total)",
            "Accept-Ranges": "bytes",
        ])!
    }
}

/// A resolved `bytes=start-end` request, clamped to the file.
struct ByteRange {
    let start: Int64
    let end: Int64

    var length: Int { Int(end - start + 1) }

    /// Parses the subset of RFC 7233 that the PMTiles reader actually
    /// emits: a single `bytes=start-end`, and the open-ended `bytes=start-`.
    /// Suffix ranges (`bytes=-500`) are not produced by it and are refused
    /// rather than guessed at.
    init?(header: String, total: Int64) {
        guard total > 0 else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("bytes=") else { return nil }

        let spec = String(trimmed.dropFirst("bytes=".count))
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return nil }

        let startText = String(spec[spec.startIndex..<dash])
        let endText = String(spec[spec.index(after: dash)...])

        guard let start = Int64(startText), start >= 0, start < total else { return nil }
        let end = Int64(endText).map { min($0, total - 1) } ?? (total - 1)
        guard end >= start else { return nil }

        self.start = start
        self.end = end
    }
}
#endif
