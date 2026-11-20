import CoreGraphics
import CoreText
import CoreVideo
import Foundation

/// The card the virtual camera shows while the Cam app isn't feeding it.
///
/// The message is drawn twice: once normally, and once flipped left to right. Many apps (Photo Booth, and the
/// self-view in most meeting apps) show your own camera mirrored, while everybody else sees it the right way
/// round. With both copies, one of them is always readable, whichever way the picture is being shown.
enum PlaceholderCard {
    static let message = "Cam isn't running. Open the Cam app."
    static let fontSize: CGFloat = 56

    /// Distance between the two lines, in pixels.
    static let lineSpacing: CGFloat = 110

    /// Vertical centre of each line, measured from the top of the picture: normal first, mirrored second.
    static func lineCentersFromTop(height: Int) -> (normal: CGFloat, mirrored: CGFloat) {
        let middle = CGFloat(height) / 2
        return (middle - lineSpacing / 2, middle + lineSpacing / 2)
    }

    static func makePixelBuffer(width: Int = Int(CamConstants.width), height: Int = Int(CamConstants.height)) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        // IOSurface-backed: frames sent to other apps have to live in shared memory.
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true,
                     kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                     kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                      width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributes = [kCTFontAttributeName: font,
                          kCTForegroundColorAttributeName: CGColor(gray: 0.85, alpha: 1)] as CFDictionary
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, message as CFString, attributes))
        // The bounds of the visible letters, not of the line's typographic advance (which includes the space left
        // after the last letter). The flipped copy only matches exactly if the line is centred by its ink.
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        // Centre the visible letters (the ink), not the line's origin: the first letter starts a little after it.
        let x = (CGFloat(width) - bounds.width) / 2 - bounds.minX
        // Core Graphics measures from the bottom; the line's centre is half its height above the baseline.
        func baseline(centerFromTop: CGFloat) -> CGFloat { CGFloat(height) - centerFromTop - bounds.height / 2 - bounds.minY }
        let centers = lineCentersFromTop(height: height)

        context.textPosition = CGPoint(x: x, y: baseline(centerFromTop: centers.normal))
        CTLineDraw(line, context)

        // The second copy: flip the whole canvas left to right around its centre, then draw the same line.
        // The line is centred, so it stays in the same horizontal place; only the letters turn round.
        context.saveGState()
        context.translateBy(x: CGFloat(width), y: 0)
        context.scaleBy(x: -1, y: 1)
        context.textPosition = CGPoint(x: x, y: baseline(centerFromTop: centers.mirrored))
        CTLineDraw(line, context)
        context.restoreGState()
        return buffer
    }
}
