import Foundation

/// Reads a coordinate typed into the search field.
///
/// Riders arrive with coordinates in whatever form the last tool handed
/// them: `40.3772, -105.5217`, `40.3772 N 105.5217 W`, `N40 22.632
/// W105 31.302`, or `40°22'38"N 105°31'18"W`. All of those are two
/// groups of one to three numbers, each group optionally owning a
/// hemisphere letter before or after it, and that is what this parses.
/// Without letters the order is latitude then longitude, the GPS
/// convention. Anything else is not a coordinate and the other sources
/// get the query.
enum CoordinateParser {
    static func parse(_ text: String) -> Coordinate? {
        // Anything but numbers, hemisphere letters, degree marks and
        // separators means this is not a coordinate.
        let allowed = CharacterSet(charactersIn: "0123456789.+-NSEWnsew°'\"′″ ,;/\t")
        guard !text.isEmpty, text.unicodeScalars.allSatisfy(allowed.contains) else { return nil }

        let pattern = try! NSRegularExpression(pattern: #"[-+]?\d+(?:\.\d+)?|[NSEWnsew]"#)
        let tokens = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .map { String(text[Range($0.range, in: text)!]) }

        // A letter before its numbers owns what follows it, up to the next
        // letter; a letter after its numbers closes them. Both styles are
        // common and a rider does not choose.
        var groups: [(numbers: [Double], hemisphere: Character?)] = []
        var numbers: [Double] = []
        var prefix: Character?
        for token in tokens {
            if let value = Double(token) {
                numbers.append(value)
                continue
            }
            let letter = Character(token.uppercased())
            if numbers.isEmpty {
                prefix = letter
            } else if let owner = prefix {
                groups.append((numbers, owner))
                numbers = []
                prefix = letter
            } else {
                groups.append((numbers, letter))
                numbers = []
            }
        }
        if !numbers.isEmpty {
            if groups.isEmpty, prefix == nil {
                // No letters at all: half and half, latitude first.
                guard numbers.count % 2 == 0, (1...3).contains(numbers.count / 2) else { return nil }
                let half = numbers.count / 2
                groups = [(Array(numbers[..<half]), nil), (Array(numbers[half...]), nil)]
            } else {
                groups.append((numbers, prefix))
            }
        }
        return coordinate(from: groups)
    }

    private static func coordinate(from groups: [(numbers: [Double], hemisphere: Character?)]) -> Coordinate? {
        guard groups.count == 2 else { return nil }
        var lat: Double?, lon: Double?
        var unlabelled: [Double] = []
        for group in groups {
            guard let value = degrees(group.numbers) else { return nil }
            switch group.hemisphere {
            case "N": lat = value
            case "S": lat = -value
            case "E": lon = value
            case "W": lon = -value
            default: unlabelled.append(value)
            }
        }
        if lat == nil, let first = unlabelled.first { lat = first; unlabelled.removeFirst() }
        if lon == nil, let first = unlabelled.first { lon = first }
        guard let lat, let lon, abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return Coordinate(lat: lat, lon: lon)
    }

    /// Degrees, or degrees and minutes, or degrees, minutes and seconds.
    /// The sign of the degrees is the sign of the whole.
    private static func degrees(_ numbers: [Double]) -> Double? {
        guard (1...3).contains(numbers.count), numbers.dropFirst().allSatisfy({ $0 >= 0 && $0 < 60 }) else { return nil }
        let sign: Double = numbers[0] < 0 ? -1 : 1
        var value = abs(numbers[0])
        if numbers.count > 1 { value += numbers[1] / 60 }
        if numbers.count > 2 { value += numbers[2] / 3600 }
        return sign * value
    }

    /// The form the app shows a coordinate in: decimal degrees to five
    /// places, about a metre.
    static func format(_ c: Coordinate) -> String {
        String(format: "%.5f, %.5f", c.lat, c.lon)
    }
}
