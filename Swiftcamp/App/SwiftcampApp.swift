import SwiftUI

@main
struct SwiftcampApp: App {
    /// One library per process, owned here rather than by a view, so the
    /// File menu can reach it. A menu command lives in the `App` and cannot
    /// see a view's `@State`.
    @State private var model = LibraryModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        #if os(macOS)
        // A planning app is a big-canvas app; the default macOS window is
        // far too small to lay a route out on.
        .defaultSize(width: 1280, height: 860)
        .commands {
            // GPX belongs in the File menu with a keyboard shortcut, not
            // only in the toolbar. Command-O is what someone reaches for
            // first, and a Mac app that answers it with nothing feels
            // broken before anything has been tried.
            CommandGroup(replacing: .importExport) {
                Button("Import GPX…") { model.isImporting = true }
                    .keyboardShortcut("o")
                Button("Export GPX…") { model.isExporting = true }
                    .keyboardShortcut("e")
                    .disabled(model.routes.isEmpty
                              && model.waypoints.isEmpty
                              && model.tracks.isEmpty)
            }
        }
        #endif
    }
}
