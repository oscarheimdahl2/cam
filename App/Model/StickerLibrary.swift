import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The folder of sticker images. Imported images are downscaled and stored as PNG (keeping transparency).
struct StickerLibrary {
    let directory: URL
    static let maxPixelSize = 1024

    struct Imported {
        let file: String
        let aspect: Double
    }

    func url(for file: String) -> URL { directory.appendingPathComponent(file) }

    func importImage(from url: URL) -> Imported? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: Self.maxPixelSize,
              ] as CFDictionary) else { return nil }
        let name = UUID().uuidString + ".png"
        guard let destination = CGImageDestinationCreateWithURL(
            self.url(for: name) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Imported(file: name, aspect: Double(image.width) / Double(image.height))
    }
}
