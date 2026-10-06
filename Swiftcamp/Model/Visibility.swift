import Foundation

/// Which of the library the map draws.
///
/// Three gates, all of them the user's: the kind switches in the View
/// menu, the selected list, and each item's own checkbox. Nothing else:
/// the first cut drew a hidden item while it was selected, and a route
/// on the map with its box unticked read as the box being broken.
enum Visibility {
    struct Kinds: Equatable, Sendable {
        var routes = true
        var tracks = true
        var waypoints = true
    }

    /// Whether one item is drawn.
    static func draws(hidden: Bool, kindShown: Bool, inList: Bool) -> Bool {
        inList && kindShown && !hidden
    }
}
