import Foundation
import Observation

/// The search field's state: what was typed, what came back.
///
/// Queries are debounced, because the Census geocoder is a public
/// service asked not to be hammered and a result per keystroke would be.
/// A coordinate is answered at once, with no source asked; everything
/// else goes to each source in turn, and a newer query cancels the run.
@MainActor
@Observable
final class SearchModel {
    var query = "" {
        didSet { if query != oldValue { schedule() } }
    }
    private(set) var results: [SearchResult] = []
    private(set) var isSearching = false

    /// A line under the results when the query is an address that says
    /// no town, state or zip. The search was biased to the map, and an
    /// address anywhere else cannot be found without one of those, which
    /// the rider has no other way to learn.
    private(set) var hint: String?

    /// Where the map is looking, for sources that rank by distance.
    var near: Coordinate?

    private let geocoders: [any Geocoder]
    @ObservationIgnored private var task: Task<Void, Never>?

    init(geocoders: [any Geocoder]) {
        self.geocoders = geocoders
    }

    /// The sources in the order they are asked: our index first, the
    /// Census geocoder for house numbers after.
    convenience init() {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Swiftcamp/search/\(BasemapSource.searchArchive)", isDirectory: true)
        let index = PlaceIndex(base: URL(string: BasemapSource.searchURL)!, cache: cache)
        self.init(geocoders: [index, CensusGeocoder()])
        self.index = index
    }

    @ObservationIgnored private var index: PlaceIndex?

    /// The map moved: fetch what a search here would need.
    func prepare(near coordinate: Coordinate) {
        near = coordinate
        Task { await index?.prepare(near: coordinate) }
    }

    private func schedule() {
        task?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            results = []
            hint = nil
            isSearching = false
            return
        }
        task = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await run(text)
        }
    }

    private func run(_ text: String) async {
        var found: [SearchResult] = []
        if let coordinate = CoordinateParser.parse(text) {
            found.append(SearchResult(name: CoordinateParser.format(coordinate), detail: "Coordinates",
                                      coordinate: coordinate, kind: .coordinate))
            results = found
            return
        }

        isSearching = true
        hint = nil
        defer { isSearching = false }

        // An address typed without its town is looked for as typed, then
        // in the town the map is looking at, since that is what a rider
        // means by "1234 Main St", then in its state.
        let isBareAddress = CensusGeocoder.looksLikeAddress(text) && !CensusGeocoder.namesAPlace(text)
        var town: String?
        if isBareAddress, let near { town = await index?.nearestTown(to: near) }
        let attempts = CensusGeocoder.attempts(for: text, near: town)
        let indexQuery = isBareAddress ? PlaceIndex.streetQuery(for: text) : text
        var matchedAt: Int?

        for geocoder in geocoders {
            guard !Task.isCancelled else { return }
            do {
                if geocoder is CensusGeocoder {
                    for (attempt, query) in attempts.enumerated() {
                        let matches = try await geocoder.search(query, near: near)
                        guard !Task.isCancelled else { return }
                        if !matches.isEmpty {
                            found += matches
                            matchedAt = attempt
                            break
                        }
                    }
                } else {
                    found += try await geocoder.search(indexQuery, near: near)
                }
            } catch {
                NSLog("[Swiftcamp] search source failed: %@", error.localizedDescription)
            }
        }
        guard !Task.isCancelled else { return }
        if CensusGeocoder.looksLikeAddress(text) {
            // The house number was the point: the addresses first, then
            // the streets and places that share the name.
            found = found.filter { $0.kind == .address } + found.filter { $0.kind != .address }
        }
        results = found
        if isBareAddress { hint = Self.hint(matchedAt: matchedAt) }
    }

    /// What to say under a bare address: nothing when it was found as
    /// typed or in the map's town, and the way out when it was found only
    /// somewhere in the state, or not at all.
    nonisolated static func hint(matchedAt attempt: Int?) -> String? {
        switch attempt {
        case nil: return "No address found near the map. For one elsewhere, add its town or zip."
        case 2: return "Found in the map's state. For one elsewhere, add its town or zip."
        default: return nil
        }
    }
}
