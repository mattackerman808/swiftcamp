import SwiftUI

@main
struct SwiftcampApp: App {
    /// One library per process, owned here rather than by a view, so the
    /// File menu can reach it. A menu command lives in the `App` and cannot
    /// see a view's `@State`.
    @State private var model = LibraryModel()

    // Each scene is its own property. A `#if` cannot hold both a modifier
    // continuing the scene above it and a new scene after it, which is what
    // trying to add the transfer window inline ran into.
    var body: some Scene {
        mainWindow
        #if os(macOS)
        transferWindow
        settings
        #endif
    }

    #if os(macOS)
    /// One preference so far: the routing mode a new route starts in. A
    /// route's own mode is on the route, in its context menu; this is only
    /// the default, so a rider who plans mostly adventure routes need not
    /// change every new one.
    private var settings: some Scene {
        Settings { SettingsView() }
    }
    #endif

    /// The map and the library.
    static let mapWindowID = "map"

    private var mainWindow: some Scene {
        WindowGroup(id: Self.mapWindowID) {
            ContentView(model: model)
        }
        #if os(macOS)
        // A planning app is a big-canvas app; the default macOS window is
        // far too small to lay a route out on.
        .defaultSize(width: 1280, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Route") { model.newRoute() }
                    .keyboardShortcut("n")
                // At the middle of the map, since a menu command has no
                // click to place it at; the right-click menu has the click.
                Button("New Waypoint") { model.newWaypoint() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New List") { model.newList() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
            }
            // Undo and redo go to the model's own manager rather than the
            // responder chain's. The web view is first responder whenever
            // the mouse is over the map, and its undo manager is for text
            // fields in the page, of which there are none — so the stock
            // items would undo nothing while looking enabled.
            //
            // Always enabled, on purpose. Disabling on `canUndo` would read
            // observable state from a `Scene`, which rebuilds the app graph
            // on every edit; see `hasContent`.
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undoManager.undo() }
                    .keyboardShortcut("z")
                Button("Redo") { model.undoManager.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(after: .pasteboard) {
                Button("Duplicate") { model.duplicateSelection() }
                    .keyboardShortcut("d")
            }
            // Whole kinds on or off the map. Three flags that flip only
            // when chosen, so binding them here does not tie the scene to
            // the library; see `hasContent`.
            CommandGroup(after: .toolbar) {
                Toggle("Show Routes", isOn: Binding(get: { model.shownKinds.routes },
                                                    set: { model.shownKinds.routes = $0 }))
                Toggle("Show Tracks", isOn: Binding(get: { model.shownKinds.tracks },
                                                    set: { model.shownKinds.tracks = $0 }))
                Toggle("Show Waypoints", isOn: Binding(get: { model.shownKinds.waypoints },
                                                       set: { model.shownKinds.waypoints = $0 }))
                // The way back after unticking too much.
                Button("Show Everything on Map") { model.showEverything() }
                Divider()
                Toggle("Show Dirt Bike Trails", isOn: Binding(get: { model.showsTrails },
                                                              set: { model.showsTrails = $0 }))
                // The map's own 2D/3D button, as a menu item for the key.
                Button("Toggle 2D / 3D") { model.showsTerrain.toggle() }
                    .keyboardShortcut("3")
                Button("Measure Distance") { model.toggleMeasuring() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
            }
            // A way back to the map. ⌘N makes a route here rather than a
            // window, so once the map window is closed while the Transfer
            // window is open nothing else reopens it, the Dock included.
            CommandGroup(before: .windowList) {
                MapWindowCommand()
            }
            // GPX belongs in the File menu with a keyboard shortcut, not
            // only in the toolbar. Command-O is what someone reaches for
            // first, and a Mac app that answers it with nothing feels
            // broken before anything has been tried.
            CommandGroup(replacing: .importExport) {
                Button("Import GPX or GDB…") { model.isImporting = true }
                    .keyboardShortcut("o")
                // The whole of BaseCamp's library, from where BaseCamp
                // keeps it, with its lists. The migration in one click.
                Button("Import BaseCamp Library") { model.importBaseCampLibrary() }
                Button("Export GPX…") { model.isExporting = true }
                    .keyboardShortcut("e")
                    // One flag, not three collections. See `hasContent`:
                    // reading the collections here re-evaluates the whole
                    // scene graph on every library change.
                    .disabled(!model.hasContent)
                Divider()
                // The library file itself, consistent as of the moment,
                // and the way back. BaseCamp's Back Up and Restore.
                Button("Back Up Library…") { model.backupLibrary() }
                Button("Restore Library from Backup…") { model.restoreLibrary() }
            }
        }
        #endif
    }

    #if os(macOS)
    /// Opens, or brings forward, the map window. A view rather than a
    /// button in the `App`, because `openWindow` is an environment action
    /// and a scene has no environment to read it from.
    private struct MapWindowCommand: View {
        @Environment(\.openWindow) private var openWindow

        var body: some View {
            Button("Map") { openWindow(id: SwiftcampApp.mapWindowID) }
                .keyboardShortcut("1", modifiers: [.command, .shift])
        }
    }

    /// A window, not a sheet.
    ///
    /// Moving routes onto a device is the work, not a question the app asks.
    /// It was a modal sheet with an Export button inside it, which put the
    /// point of the feature behind a dialog and a verb.
    private var transferWindow: some Scene {
        Window("Transfer", id: TransferWindow.id) {
            TransferWindow(library: model)
        }
        .defaultSize(width: 900, height: 560)
        .keyboardShortcut("t", modifiers: [.command, .shift])
    }
    #endif
}
