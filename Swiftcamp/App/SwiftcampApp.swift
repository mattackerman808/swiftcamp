import SwiftUI

@main
struct SwiftcampApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        // A planning app is a big-canvas app; the default macOS window is
        // far too small to lay a route out on.
        .defaultSize(width: 1280, height: 860)
        #endif
    }
}
