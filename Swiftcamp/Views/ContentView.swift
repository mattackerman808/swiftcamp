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
        // The search field lives in the toolbar and its results drop from
        // it, which is the Mac's own shape for this. Choosing a result
        // flies there and pins it; the bar over the map then offers to
        // keep it as a waypoint.
        .searchable(text: Binding(get: { model.search.query }, set: { model.search.query = $0 }),
                    placement: .toolbar,
                    prompt: "Place, address, or coordinates")
        .searchSuggestions {
            // Something the moment there is a query: the first search in
            // an area waits on the index for that area arriving, up to
            // 58 MB, and an empty list for that long reads as broken.
            if model.search.results.isEmpty, !model.search.query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(model.search.isSearching ? "Searching…" : (model.search.hint ?? "No matches"))
                    .foregroundStyle(.secondary)
            }
            ForEach(model.search.results) { result in
                Button {
                    model.show(result)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(result.name)
                        Text(result.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !model.search.results.isEmpty, let hint = model.search.hint {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onSubmit(of: .search) {
            if let first = model.search.results.first { model.show(first) }
        }
        .fileImporter(isPresented: $model.isImporting, allowedContentTypes: [.gpx, .gdb], allowsMultipleSelection: true) { result in
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
              VStack(spacing: 0) {
                if let pin = model.searchPin {
                    searchPinBar(pin)
                }
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

    /// The pinned search result: what it is, and the two things to do
    /// with it. A pin is a look, not a library item, until it is saved.
    private func searchPinBar(_ pin: SearchResult) -> some View {
        HStack(spacing: 12) {
            Label {
                Text(pin.name).bold() + Text("  ") + Text(pin.detail).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "mappin.circle.fill").foregroundStyle(.red)
            }
            .font(.callout)
            Button("Save as Waypoint") { model.saveSearchPin() }
            Button("Dismiss") { model.dismissSearchPin() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(12)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Named, not just pictured. Five glyphs in a row read as a puzzle,
        // and the tooltip that would solve it arrives after macOS's own
        // second of hover, which nobody waits for. The words are the
        // affordance; the help text is only the longer explanation.
        ToolbarItemGroup {
            Button { model.newRoute() } label: {
                Label("Route", systemImage: "plus")
            }
            .labelStyle(.titleAndIcon)
            .help("New route: start one and place its points by clicking the map (⌘N)")
            Button { model.newWaypoint() } label: {
                Label("Waypoint", systemImage: "mappin.and.ellipse")
            }
            .labelStyle(.titleAndIcon)
            .help("New waypoint at the middle of the map; drag it into place (⇧⌘N)")
        }
        ToolbarItemGroup {
            Button { model.isImporting = true } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .labelStyle(.titleAndIcon)
            .help("Import a GPX or Garmin GDB file into the library (⌘O)")
            Button { model.isExporting = true } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .labelStyle(.titleAndIcon)
            .help("Export the selection, or the whole library, as a GPX file (⌘E)")
            .disabled(model.routes.isEmpty && model.waypoints.isEmpty && model.tracks.isEmpty)
            Button { openWindow(id: TransferWindow.id) } label: {
                Label("Device", systemImage: "arrow.left.arrow.right")
            }
            .labelStyle(.titleAndIcon)
            .help("Send routes to a Garmin over USB, or bring its rides in (⇧⌘T)")
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
    /// Garmin's GDB. macOS knows no owner for the extension, so the type
    /// is whatever the system makes of `.gdb`; the importer decides by the
    /// file's own signature, not by this.
    static let gdb = UTType(filenameExtension: "gdb") ?? .data
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
