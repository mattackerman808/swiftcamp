import Foundation

/// Google's encoded polyline, at the precision Valhalla uses.
///
/// Valhalla encodes route shapes with six decimal places, not the five in
/// Google's original, so a decoder that assumes 1e5 puts every route ten
/// times too far from the origin — off the map, rather than subtly wrong.
enum Polyline {
    static func decode(_ encoded: String, precision: Double = 1e6) -> [Coordinate] {
        var out: [Coordinate] = []
        var lat = 0, lon = 0
        var index = encoded.utf8.startIndex
        let bytes = encoded.utf8

        func next() -> Int? {
            var result = 0, shift = 0
            var byte: Int
            repeat {
                guard index < bytes.endIndex else { return nil }
                byte = Int(bytes[index]) - 63
                index = bytes.index(after: index)
                result |= (byte & 0x1f) << shift
                shift += 5
            } while byte >= 0x20
            return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
        }

        while index < bytes.endIndex {
            guard let dLat = next(), let dLon = next() else { break }
            lat += dLat
            lon += dLon
            out.append(Coordinate(lat: Double(lat) / precision, lon: Double(lon) / precision))
        }
        return out
    }
}
