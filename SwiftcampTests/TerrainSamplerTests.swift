import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Swiftcamp

/// Pixels to metres, and places to pixels, with no network.
final class TerrainSamplerTests: XCTestCase {
    func testTerrariumMetres() {
        XCTAssertEqual(TerrainSampler.metres(r: 128, g: 0, b: 0), 0)
        XCTAssertEqual(TerrainSampler.metres(r: 139, g: 161, b: 128), 2977.5)
        XCTAssertEqual(TerrainSampler.metres(r: 144, g: 248, b: 0), 4344, "Longs Peak's pixel")
    }

    /// Checked against the Python walk: Longs Peak lands in tile 846,1546
    /// at zoom 12, column 171, row 443, and the archive's highest pixel
    /// there is the summit.
    func testTheProjectionLandsLongsPeakOnItsPixel() {
        let pixel = TerrainSampler.pixel(of: Coordinate(lat: 40.2550, lon: -105.6151), zoom: 12)
        XCTAssertEqual(Int(pixel.x) / 512, 846)
        XCTAssertEqual(Int(pixel.y) / 512, 1546)
        XCTAssertEqual(Int(pixel.x) % 512, 171)
        XCTAssertEqual(Int(pixel.y) % 512, 443)
    }

    /// A tile drawn by hand with one known pixel, encoded by ImageIO and
    /// decoded by the sampler: the buffer is top row first.
    func testDecodingReadsTheTopRowFirst() throws {
        let size = 512
        var rgb = [UInt8](repeating: 0, count: size * size * 4)
        for i in stride(from: 0, to: rgb.count, by: 4) { rgb[i] = 128; rgb[i + 3] = 255 }   // sea level
        let (col, row) = (171, 443)
        let o = (row * size + col) * 4
        rgb[o] = 144; rgb[o + 1] = 248; rgb[o + 2] = 0                                   // 4,344 m
        let context = try XCTUnwrap(rgb.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        })
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let tile = try XCTUnwrap(TerrainSampler.decode(data as Data))
        XCTAssertEqual(tile.metres(col, row), 4344)
        XCTAssertEqual(tile.metres(0, 0), 0)
        XCTAssertEqual(tile.metres(col, size - 1 - row), 0, "not flipped")
    }

    func testADifferentSizeIsRefused() {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        XCTAssertNil(TerrainSampler.decode(data as Data))
    }
}
