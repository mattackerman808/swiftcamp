import SwiftUI
import UniformTypeIdentifiers

/// The window: library on the left, map on the right.
struct ContentView: View {
    @Bindable var model: LibraryModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        #if os(macOS)
        NavigationSplitView {
            LibrarySidebar(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            map
        }
        .toolbar { toolbar }
        .fileImporter(isPresented: $model.isImporting, allowedContentTypes: [.gpx], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): urls.forEach(model.importGPX(from:))
            case .failure(let error): model.failure = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $model.isExporting,
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
        MapContainer(overlay: model.overlay, camera: model.camera,
                     editingRouteID: model.editingRouteID, pageEvent: model.pageEvent,
                     onClick: model.select, onDrag: model.drag, onKey: model.key,
                     onContextMenu: model.contextMenu, onView: model.viewChanged)
            #if os(macOS)
            // A scripted run floats its window. WebKit stops rendering a
            // view its window does not show, and a second copy of the app
            // opens exactly under the first, fully covered: the map never
            // draws a frame, never fires `load`, and every scripted click
            // lands on nothing. Two runs were lost to a developer's own copy
            // sitting on top before the cause was found by sampling.
            .onAppear {
                guard UserDefaults.standard.string(forKey: "SwiftcampScript") != nil
                        || UserDefaults.standard.string(forKey: "SwiftcampSnapshot") != nil else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NSApp.windows.first { $0.isVisible }?.level = .floating
                }
            }
            #endif
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
                if model.editingRouteID != nil {
                    editBar
                } else if model.isBusy {
                    Label("Reading…", systemImage: "clock")
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(12)
                } else if let failure = model.failure {
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

    /// What editing means, said once, where the cursor is. The map gives
    /// no other hint that clicking it now does something.
    private var editBar: some View {
        HStack(spacing: 12) {
            Label("Click the map to add a point. Drag a point to move it. Click the line to insert one.",
                  systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.callout)
            Button("Done") { model.finishEditing() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(12)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { model.newRoute() } label: {
                Label("New Route", systemImage: "plus")
            }
            .help("Start a route and place its points by clicking the map")
            Button { openWindow(id: TransferWindow.id) } label: {
                Label("Transfer", systemImage: "arrow.left.arrow.right")
            }
            .help("Move routes and tracks between the library and a device")
            Button { model.isImporting = true } label: {
                Label("Import GPX", systemImage: "square.and.arrow.down")
            }
            Button { model.isExporting = true } label: {
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
