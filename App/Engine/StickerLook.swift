import CoreImage
import CoreImage.CIFilterBuiltins

/// The "sticker look": rounded corners, a white die-cut border that follows the silhouette, and a soft drop shadow.
enum StickerLook {
    static let borderRatio: CGFloat = 0.04        // border thickness as a fraction of the sticker's width
    static let minBorder: CGFloat = 8             // ...but never thinner than this many pixels
    static let cornerRadiusRatio: CGFloat = 0.07  // image corner radius as a fraction of its shorter side

    /// `image` must occupy (0, 0, width, height). The result is larger: it includes the border and the shadow.
    static func apply(to image: CIImage, width: CGFloat, height: CGFloat) -> CIImage {
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let border = max(minBorder, width * borderRatio)
        let radius = min(width, height) * cornerRadiusRatio

        // 1. Round the image's own corners.
        let corners = CIFilter.roundedRectangleGenerator()
        corners.extent = rect
        corners.radius = Float(radius)
        corners.color = .white
        let rounded = image.cropped(to: rect)
            .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: corners.outputImage!])

        // 2. Silhouette grown by exactly `border`. Blurring with a disc and keeping every pixel the disc touches
        //    is a true circular grow (Minkowski sum), so the outer corner radius is `radius + border`
        //    and the border stays concentric with the image corners at any thickness.
        let threshold: CGFloat = 0.004
        let grown = rounded
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0),
            ])
            .applyingFilter("CIDiscBlur", parameters: [kCIInputRadiusKey: border * 1.03])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 250),
                "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: -250 * threshold),
            ])
            .applyingFilter("CIColorClamp")
        let outline = grown.cropped(to: rect.insetBy(dx: -border * 4, dy: -border * 4))

        // 3. Shadow from the outline.
        let shadow = outline
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.35),
            ])
            .transformed(by: CGAffineTransform(translationX: 0, y: -width * 0.012))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: max(3, width * 0.012))
            .cropped(to: rect.insetBy(dx: -border * 8, dy: -border * 8))

        return rounded.composited(over: outline).composited(over: shadow)
    }
}
