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
        defer { isSearching = false }
        for geocoder in geocoders {
            guard !Task.isCancelled else { return }
            do {
                found += try await geocoder.search(text, near: near)
            } catch {
                NSLog("[Swiftcamp] search source failed: %@", error.localizedDescription)
            }
        }
        guard !Task.isCancelled else { return }
        results = found
    }
}
