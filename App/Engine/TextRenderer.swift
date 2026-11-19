import AppKit
import CoreImage

/// Draws a text layer's content into an image. It is drawn large and then scaled like any other image, so the
/// layer's width alone decides how big the text appears.
enum TextRenderer {
    private static let fontSize: CGFloat = 120
    private static let padding: CGFloat = 18

    private static func attributed(_ text: TextContent) -> NSAttributedString {
        NSAttributedString(string: text.string.isEmpty ? " " : text.string, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: text.bold ? .heavy : .medium),
            .foregroundColor: NSColor(srgbRed: text.color.r, green: text.color.g, blue: text.color.b, alpha: text.color.a),
        ])
    }

    private static func imageSize(_ text: NSAttributedString) -> CGSize {
        let size = text.size()
        return CGSize(width: ceil(size.width) + 2 * padding, height: ceil(size.height) + 2 * padding)
    }

    /// Width divided by height of the drawn image (the layer needs it to draw its selection box).
    static func aspect(of text: TextContent) -> Double {
        let size = imageSize(attributed(text))
        return Double(size.width / size.height)
    }

    static func image(for content: TextContent) -> CIImage? {
        let text = attributed(content)
        let size = imageSize(text)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        text.draw(at: NSPoint(x: padding, y: padding))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage().map { CIImage(cgImage: $0) }
    }
}
