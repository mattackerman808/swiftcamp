import Foundation

/// How the sidebar orders its rows, and which rows a typed filter keeps.
///
/// Pure functions over the records, so the order the user sees is decided
/// once here rather than by whichever query happened to fetch the rows.
/// The store reads in name order and the model sorts, because sorting by
/// length needs the points and the observation that carries them.
enum LibrarySort: String, CaseIterable, Codable, Sendable {
    case name
    case created
    case updated
    case length

    var title: String {
        switch self {
        case .name: "Name"
        case .created: "Date Created"
        case .updated: "Date Modified"
        case .length: "Length"
        }
    }

    /// The `UserDefaults` keys the choice lives under.
    static let key = "librarySort"
    static let descendingKey = "librarySortDescending"
}

enum LibraryOrder {
    /// `items` in the order asked, `length` in metres where an item has
    /// one. Waypoints have no length and sort by name among themselves.
    ///
    /// Ties break on name so the order is stable between two rebuilds of
    /// the same rows; a list that shuffles as you watch reads as broken.
    static func sorted<T>(_ items: [T], by sort: LibrarySort, descending: Bool,
                          name: (T) -> String,
                          created: (T) -> Date,
                          updated: (T) -> Date,
                          length: (T) -> Double?) -> [T] {
        func byName(_ a: T, _ b: T) -> Bool {
            name(a).localizedStandardCompare(name(b)) == .orderedAscending
        }
        func ordered(_ a: T, _ b: T) -> Bool {
            switch sort {
            case .name:
                return byName(a, b)
            case .created:
                let x = created(a), y = created(b)
                return x != y ? x < y : byName(a, b)
            case .updated:
                let x = updated(a), y = updated(b)
                return x != y ? x < y : byName(a, b)
            case .length:
                // Unmeasured after measured, whichever way the sort runs
                // is read; comparing a length against a name would not be
                // an ordering at all, and `sort` would answer at random.
                switch (length(a), length(b)) {
                case (let x?, let y?): return x != y ? x < y : byName(a, b)
                case (nil, nil): return byName(a, b)
                case (nil, _?): return false
                case (_?, nil): return true
                }
            }
        }
        let ascending = items.sorted(by: ordered)
        return descending ? ascending.reversed() : ascending
    }

    /// Whether an item's text matches what was typed: every word of the
    /// query somewhere in the name, comment or description, in any order,
    /// ignoring case and diacritics. "trail ridge" finds "Trail Ridge Road"
    /// and "Ridge Trail" both, which is what a filter box is for.
    static func matches(_ query: String, _ fields: String?...) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = fields.compactMap { $0 }.joined(separator: "\n")
        return words.allSatisfy {
            haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
