import Foundation

/// Which of the library the map draws.
///
/// Three gates, all of them the user's: the kind switches in the View
/// menu, the selected list, and each item's own hidden flag. A hidden item
/// still draws while it is selected or being edited, because the sidebar
/// just framed it and a flight to an empty patch of map is a bug report.
enum Visibility {
    struct Kinds: Equatable, Sendable {
        var routes = true
        var tracks = true
        var waypoints = true
    }

    /// Whether one item is drawn.
    static func draws(hidden: Bool, kindShown: Bool, inList: Bool,
                      selected: Bool, editing: Bool = false) -> Bool {
        guard inList else { return false }
        if selected || editing { return true }
        return kindShown && !hidden
    }
}
