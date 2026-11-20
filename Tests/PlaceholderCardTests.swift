import CoreVideo
import XCTest

/// The "Cam isn't running" card shows its message twice: once normal, once flipped left to right, so one of them can
/// be read whether or not the app showing the camera mirrors it.
final class PlaceholderCardTests: XCTestCase {
    private let width = 1920, height = 1080

    /// Brightness (0...255) of every pixel in a band of rows, row by row from the top.
    private func band(of buffer: CVPixelBuffer, centeredAt centerFromTop: CGFloat, rows: Int = 90) -> [[UInt8]] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let first = Int(centerFromTop) - rows / 2
        return (first..<first + rows).map { y in (0..<width).map { x in base[y * stride + x * 4 + 1] } }   // green channel of BGRA
    }

    func testTheCardHasTheMessageTwiceAndTheSecondCopyIsTheLeftToRightMirrorOfTheFirst() throws {
        let buffer = try XCTUnwrap(PlaceholderCard.makePixelBuffer(width: width, height: height))
        let centers = PlaceholderCard.lineCentersFromTop(height: height)
        let normal = band(of: buffer, centeredAt: centers.normal)
        let mirrored = band(of: buffer, centeredAt: centers.mirrored)

        // Both bands contain text (bright pixels on the dark card).
        let bright = { (b: [[UInt8]]) in b.joined().filter { $0 > 150 }.count }
        XCTAssertGreaterThan(bright(normal), 500)
        XCTAssertGreaterThan(bright(mirrored), 500)
        XCTAssertEqual(bright(normal), bright(mirrored), accuracy: bright(normal) / 50, "same text, same amount of ink")

        // The second band is the first one flipped left to right: not flipped upside down, not moved. It may sit one
        // pixel to the side of a perfect mirror: the text is an odd number of pixels wide and the picture's centre
        // falls between two pixels, so an exactly centred mirror cannot land on the same pixel grid.
        func mismatches(shift: Int) -> Int {
            var count = 0
            for (a, b) in zip(normal, mirrored) {
                for x in 8..<(width - 8) where abs(Int(a[width - 1 - x + shift]) - Int(b[x])) > 40 { count += 1 }
            }
            return count
        }
        XCTAssertLessThan((-1...1).map(mismatches).min()!, bright(normal) / 50,
                          "the second line must be the mirror image of the first")

        // And the two copies really are different pictures (otherwise "mirrored" would mean nothing).
        var unflippedDifferent = 0
        for (a, b) in zip(normal, mirrored) { for (p, q) in zip(a, b) where abs(Int(p) - Int(q)) > 40 { unflippedDifferent += 1 } }
        XCTAssertGreaterThan(unflippedDifferent, bright(normal) / 2, "the mirrored copy must not be identical to the first")
    }

    func testTheCardMakesAnIOSurfaceBackedBufferOfTheRequestedSize() throws {
        let buffer = try XCTUnwrap(PlaceholderCard.makePixelBuffer(width: 640, height: 360))
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 640)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), 360)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(buffer), "frames shared with other apps must live in shared memory")
    }
}
