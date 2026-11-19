import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// Turns a raw camera frame into the final frame: real background (optionally blurred),
/// stickers behind the person, and the person on top.
final class Compositor {
    static let outputSize = CGSize(width: Int(CamConstants.width), height: Int(CamConstants.height))
    static let outputRect = CGRect(origin: .zero, size: outputSize)

    let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let stickersDir: URL
    private let segmentation = VNGeneratePersonSegmentationRequest()
    private let sequenceHandler = VNSequenceRequestHandler()
    private var imageCache: [String: CIImage] = [:]

    init(stickersDir: URL) {
        self.stickersDir = stickersDir
        segmentation.qualityLevel = .balanced
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    /// `time` (seconds) only matters in party mode: it drives the spin, hue cycle and twinkling lights.
    func render(frame: CVPixelBuffer, scene: CamScene, stickersEnabled: Bool,
                partyMode: Bool = false, time: Double = 0) -> CIImage {
        let image = composite(frame: frame, scene: scene, stickersEnabled: stickersEnabled,
                              partyMode: partyMode, time: time)
        guard partyMode else { return image }
        return Self.partyLights(time: time)
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: image])
            .cropped(to: Self.outputRect)
    }

    private func composite(frame: CVPixelBuffer, scene: CamScene, stickersEnabled: Bool,
                           partyMode: Bool, time: Double) -> CIImage {
        let base = Self.fit(CIImage(cvPixelBuffer: frame))
        let wantsStickers = stickersEnabled && !scene.stickers.isEmpty
        guard wantsStickers || scene.blurEnabled else { return base }
        guard let mask = personMask(frame: frame) else { return base }

        var background = base
        if scene.blurEnabled {
            let sigma = scene.blurRadius * Self.outputSize.width / 1920
            background = base.clampedToExtent()
                .applyingGaussianBlur(sigma: sigma)
                .cropped(to: Self.outputRect)
        }
        if wantsStickers {
            for (index, sticker) in scene.stickers.enumerated() {
                if let image = stickerImage(sticker, index: index, partyMode: partyMode, time: time) {
                    background = image.composited(over: background)
                }
            }
        }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = base
        blend.backgroundImage = background
        blend.maskImage = mask
        return blend.outputImage?.cropped(to: Self.outputRect) ?? base
    }

    func render(_ image: CIImage, to buffer: CVPixelBuffer) {
        ciContext.render(image, to: buffer, bounds: Self.outputRect, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    func cgImage(_ image: CIImage, maxWidth: CGFloat) -> CGImage? {
        let scale = maxWidth / Self.outputSize.width
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return ciContext.createCGImage(scaled, from: scaled.extent)
    }

    func forgetCachedImages() { imageCache.removeAll() }

    // MARK: - Private

    /// Aspect-fill the camera frame into the fixed output rect.
    private static func fit(_ image: CIImage) -> CIImage {
        let e = image.extent
        let s = max(outputSize.width / e.width, outputSize.height / e.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let dx = (outputSize.width - scaled.extent.width) / 2 - scaled.extent.minX
        let dy = (outputSize.height - scaled.extent.height) / 2 - scaled.extent.minY
        return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy)).cropped(to: outputRect)
    }

    private func personMask(frame: CVPixelBuffer) -> CIImage? {
        do {
            try sequenceHandler.perform([segmentation], on: frame)
        } catch {
            return nil
        }
        guard let buffer = segmentation.results?.first?.pixelBuffer else { return nil }
        return Self.fit(CIImage(cvPixelBuffer: buffer).transformed(by: scaleToFrame(mask: buffer, frame: frame)))
            .applyingGaussianBlur(sigma: 1.5).cropped(to: Self.outputRect)
    }

    private func scaleToFrame(mask: CVPixelBuffer, frame: CVPixelBuffer) -> CGAffineTransform {
        CGAffineTransform(
            scaleX: CGFloat(CVPixelBufferGetWidth(frame)) / CGFloat(CVPixelBufferGetWidth(mask)),
            y: CGFloat(CVPixelBufferGetHeight(frame)) / CGFloat(CVPixelBufferGetHeight(mask)))
    }

    private func stickerImage(_ sticker: Sticker, index: Int, partyMode: Bool, time: Double) -> CIImage? {
        let source: CIImage
        if let cached = imageCache[sticker.file] {
            source = cached
        } else if let loaded = CIImage(contentsOf: stickersDir.appendingPathComponent(sticker.file),
                                       options: [.applyOrientationProperty: true]) {
            imageCache[sticker.file] = loaded
            source = loaded
        } else {
            return nil
        }
        let size = Self.outputSize
        let width = sticker.width * size.width
        let height = width / sticker.aspect
        let scale = width / source.extent.width
        // Local space: the sticker's image occupies (0, 0, width, height).
        var local = source
            .transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if partyMode {
            // Rainbow: a solid colour wash at low opacity whose hue drifts over time, offset per sticker.
            // Source-atop keeps it on the sticker's own pixels, and it's applied before the sticker look so
            // the white border stays white.
            let hue = (time * 0.055 + Double(index) * 0.17).truncatingRemainder(dividingBy: 1)
            let wash = CIImage(color: Self.rainbowColor(hue: hue, alpha: 0.38)).cropped(to: local.extent)
            local = wash.applyingFilter("CISourceAtopCompositing", parameters: [kCIInputBackgroundImageKey: local])
        }
        if sticker.styled { local = Self.applyStickerLook(to: local, width: width, height: height) }
        let transform = CGAffineTransform(translationX: -width / 2, y: -height / 2)
            .concatenating(CGAffineTransform(rotationAngle: -(sticker.rotation + (partyMode ? time * 0.25 : 0))))
            .concatenating(CGAffineTransform(translationX: sticker.x * size.width, y: (1 - sticker.y) * size.height))
        return local.transformed(by: transform)
    }

    /// White die-cut border that follows the sticker's silhouette, rounded corners, soft drop shadow.
    private static func applyStickerLook(to image: CIImage, width: CGFloat, height: CGFloat) -> CIImage {
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let border = max(8, width * 0.04)
        let radius = min(width, height) * 0.07

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

    // MARK: - Party mode

    /// Fully saturated colour for a hue in 0...1 (HSV with s = v = 1).
    private static func rainbowColor(hue: Double, alpha: CGFloat) -> CIColor {
        let h = hue * 6
        let f = h - floor(h)
        let (r, g, b): (Double, Double, Double)
        switch Int(floor(h)) % 6 {
        case 0: (r, g, b) = (1, f, 0)
        case 1: (r, g, b) = (1 - f, 1, 0)
        case 2: (r, g, b) = (0, 1, f)
        case 3: (r, g, b) = (0, 1 - f, 1)
        case 4: (r, g, b) = (f, 0, 1)
        default: (r, g, b) = (1, 0, 1 - f)
        }
        return CIColor(red: r, green: g, blue: b, alpha: alpha)
    }


    /// Twinkling golden bulbs around the frame edge, plus a faint inward glow from each edge.
    private static func partyLights(time: Double) -> CIImage {
        let w = outputSize.width, h = outputSize.height
        let r: CGFloat = 255, g: CGFloat = 199, b: CGFloat = 71   // gold
        func gold(_ alpha: CGFloat) -> CIColor { CIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: alpha) }

        // Inward glow, gently breathing.
        let depth: CGFloat = 190
        let glow = CGFloat(0.16 + 0.04 * sin(time * 0.4))
        func edge(_ p0: CGPoint, _ p1: CGPoint, _ rect: CGRect) -> CIImage {
            let gradient = CIFilter.linearGradient()
            gradient.point0 = p0; gradient.point1 = p1
            gradient.color0 = gold(glow); gradient.color1 = gold(0)
            return gradient.outputImage!.cropped(to: rect)
        }
        var layers = [
            edge(CGPoint(x: 0, y: 0), CGPoint(x: depth, y: 0), CGRect(x: 0, y: 0, width: depth, height: h)),
            edge(CGPoint(x: w, y: 0), CGPoint(x: w - depth, y: 0), CGRect(x: w - depth, y: 0, width: depth, height: h)),
            edge(CGPoint(x: 0, y: 0), CGPoint(x: 0, y: depth), CGRect(x: 0, y: 0, width: w, height: depth)),
            edge(CGPoint(x: 0, y: h), CGPoint(x: 0, y: h - depth), CGRect(x: 0, y: h - depth, width: w, height: depth)),
        ]

        // Bulbs along the border.
        let inset: CGFloat = 28, spacing: CGFloat = 150, glowRadius: CGFloat = 95
        var points: [CGPoint] = []
        var x = spacing / 2
        while x < w { points.append(CGPoint(x: x, y: inset)); points.append(CGPoint(x: x, y: h - inset)); x += spacing }
        var y = spacing / 2
        while y < h { points.append(CGPoint(x: inset, y: y)); points.append(CGPoint(x: w - inset, y: y)); y += spacing }

        for (k, point) in points.enumerated() {
            let twinkle = 0.55 + 0.45 * sin(time * 1.0 + Double(k) * 1.9)
            let bulb = CIFilter.radialGradient()
            bulb.center = point
            bulb.radius0 = 0; bulb.radius1 = Float(glowRadius)
            bulb.color0 = CIColor(red: 1, green: 0.93, blue: 0.68, alpha: CGFloat(twinkle))
            bulb.color1 = gold(0)
            layers.append(bulb.outputImage!.cropped(to: CGRect(x: point.x - glowRadius, y: point.y - glowRadius,
                                                              width: glowRadius * 2, height: glowRadius * 2)))
        }
        return layers.dropFirst().reduce(layers[0]) { $1.composited(over: $0) }
    }
}
