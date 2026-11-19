import CoreImage

/// The fixed frame everything is composed into (what the virtual camera sends), and how camera frames map onto it.
enum OutputFrame {
    static let size = CGSize(width: Int(CamConstants.width), height: Int(CamConstants.height))
    static let rect = CGRect(origin: .zero, size: size)

    /// Aspect-fill mapping of a source of `sourceSize` into the frame: a uniform scale, then this offset.
    static func aspectFill(_ sourceSize: CGSize) -> (scale: CGFloat, offset: CGPoint) {
        let scale = max(size.width / sourceSize.width, size.height / sourceSize.height)
        return (scale, CGPoint(x: (size.width - sourceSize.width * scale) / 2,
                               y: (size.height - sourceSize.height * scale) / 2))
    }

    /// Scales and crops any image so it exactly covers the output frame.
    static func fit(_ image: CIImage) -> CIImage {
        let e = image.extent
        let (scale, offset) = aspectFill(e.size)
        return image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: offset.x, y: offset.y)))
            .cropped(to: rect)
    }
}
