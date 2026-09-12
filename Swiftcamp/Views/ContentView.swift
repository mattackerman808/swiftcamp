import SwiftUI
import UniformTypeIdentifiers

/// The window: library on the left, map on the right.
struct ContentView: View {
    @State private var model = LibraryModel()
    @State private var isImporting = false
    @State private var isExporting = false

    var body: some View {
        #if os(macOS)
        NavigationSplitView {
            LibrarySidebar(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            map
        }
        .toolbar { toolbar }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.gpx], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): urls.forEach(model.importGPX(from:))
            case .failure(let error): model.failure = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $isExporting,
                      document: GPXFile(),
                      contentType: .gpx,
                      defaultFilename: "Swiftcamp") { result in
            // The exporter writes its own placeholder first; we overwrite it
            // with the real document, because building the file needs the
            // database and `FileDocument` cannot reach it.
            if case .success(let url) = result { model.exportGPX(to: url) }
        }
        #else
        map
        #endif
    }

    private var map: some View {
        MapContainer(overlay: model.overlay, onClick: model.select)
            #if os(iOS)
            // Edge to edge under the status bar and home indicator.
            //
            // Deliberately NOT applied on macOS. There, SwiftUI would
            // stretch the web view under the title bar while WebKit keeps
            // insetting its own viewport by that same safe area, so the
            // view ends up 32pt taller than the page it is showing and the
            // difference renders as an unpainted strip. Letting AppKit lay
            // the web view out inside the safe area keeps bounds and
            // viewport identical.
            .ignoresSafeArea()
            #endif
            .overlay(alignment: .bottomLeading) {
                // OSM attribution is an ODbL obligation, not decoration.
                // See docs/data-architecture.md.
                Text(BasemapSource.attribution)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
            }
            .overlay(alignment: .top) {
                if let failure = model.failure {
                    // The user picked the file, so they are owed a reason
                    // rather than an import that appears to do nothing.
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(12)
                        .onTapGesture { model.failure = nil }
                }
            }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { isImporting = true } label: {
                Label("Import GPX", systemImage: "square.and.arrow.down")
            }
            Button { isExporting = true } label: {
                Label("Export GPX", systemImage: "square.and.arrow.up")
            }
            .disabled(model.routes.isEmpty && model.waypoints.isEmpty && model.tracks.isEmpty)
        }
    }
}

/// The GPX content type.
///
/// Imported rather than exported: GPX is Topografix's format, not ours, and
/// declaring ourselves its owner would make Swiftcamp the system's default
/// handler for every `.gpx` on the machine on the strength of having been
/// launched once.
extension UTType {
    static let gpx = UTType(importedAs: "com.topografix.gpx", conformingTo: .xml)
}

/// A placeholder for `fileExporter`, which insists on a document.
///
/// The real bytes are written by `LibraryModel.exportGPX(to:)` once the
/// destination is known, because assembling them needs the database and a
/// `FileDocument` is constructed without access to it.
private struct GPXFile: FileDocument {
    static var readableContentTypes: [UTType] { [.gpx] }

    init() {}
    init(configuration: ReadConfiguration) throws {}

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data())
    }
}
