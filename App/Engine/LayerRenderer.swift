import CoreImage

/// Draws one layer: gets its content as an image (loaded from disk or drawn from text, then cached), resizes it,
/// applies its party motions and the sticker look, then rotates and positions it in the output frame.
final class LayerRenderer {
    private let directory: URL
    private var imageCache: [String: CIImage] = [:]
    private var textCache: [TextContent: CIImage] = [:]
    private let particleFrames: ParticleFrames

    init(directory: URL, particleFrames: ParticleFrames) {
        self.directory = directory
        self.particleFrames = particleFrames
    }

    func forgetCachedImages() {
        imageCache.removeAll()
        textCache.removeAll()
    }

    /// `index` is the layer's position in the scene (it offsets the rainbow hue). Returns nil if the layer
    /// shouldn't be drawn right now (a head layer while no face is tracked, or fully faded out).
    func image(for layer: Layer, index: Int, time: Double, face: FaceState?) -> CIImage? {
        guard let place = layer.placement(face: face) else { return nil }
        let opacity = layer.followsHead ? (face?.alpha ?? 0) : 1
        guard opacity > 0, let source = sourceImage(for: layer) else { return nil }

        let size = OutputFrame.size
        let width = place.width * size.width
        let height = width / layer.aspect

        // Local space: the content occupies (0, 0, width, height).
        // Lanczos for the resize (a plain affine scale + rotate in one go samples a big image too coarsely and
        // shimmers while it turns), leaving only a small rotation for the bilinear sampler.
        var local = source
            .transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: width / source.extent.width, kCIInputAspectRatioKey: 1.0])
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))

        // What party mode does, if the layer has it.
        var spin = 0.0
        var wash: (hue: Double, opacity: Double)?
        for motion in layer.party ? PartyStyle.motions(for: layer) : [] {
            switch motion {
            case .spin(let speed):
                spin += speed * time
            case .hueDrift(let speed, let washOpacity):
                let hue = (time * speed + Double(index) * PartyStyle.huePerLayer).truncatingRemainder(dividingBy: 1)
                wash = (hue, washOpacity)
            }
        }
        if let wash {
            // Rainbow: a solid colour wash. Source-atop keeps it on the layer's own pixels, and it goes on before
            // the sticker look so the white border stays white.
            let tint = CIImage(color: PartyStyle.rainbowColor(hue: wash.hue, alpha: CGFloat(wash.opacity)))
                .cropped(to: local.extent)
            local = tint.applyingFilter("CISourceAtopCompositing", parameters: [kCIInputBackgroundImageKey: local])
        }
        if layer.styled { local = StickerLook.apply(to: local, width: width, height: height) }

        let transform = CGAffineTransform(translationX: -width / 2, y: -height / 2)
            .concatenating(CGAffineTransform(rotationAngle: -(place.rotation + spin)))
            .concatenating(CGAffineTransform(translationX: place.x * size.width, y: (1 - place.y) * size.height))

        // A transparent margin lets the rotation anti-alias the edges instead of leaving them jagged.
        let margin = CIImage(color: .clear).cropped(to: local.extent.insetBy(dx: -3, dy: -3))
        var placed = local.composited(over: margin).transformed(by: transform)
        if opacity < 1 {
            placed = placed.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
        }
        return placed
    }

    private func sourceImage(for layer: Layer) -> CIImage? {
        switch layer.content {
        case .image(let file):
            if let cached = imageCache[file] { return cached }
            guard let loaded = CIImage(contentsOf: directory.appendingPathComponent(file),
                                       options: [.applyOrientationProperty: true]) else { return nil }
            imageCache[file] = loaded
            return loaded
        case .text(let text):
            if let cached = textCache[text] { return cached }
            guard let drawn = TextRenderer.image(for: text) else { return nil }
            textCache[text] = drawn
            return drawn
        case .particles(let effect):
            guard let frame = particleFrames.frame(for: layer.id) else { return nil }   // nil until the first frame
            guard let tint = effect.tint else { return frame }
            // Recolour: every particle becomes its own brightness times the chosen colour. (Plain "monochrome" keeps
            // highlights white, so white snow or a fire's hot core would not change.)
            func row(_ channel: Double) -> CIVector { CIVector(x: channel * 0.299, y: channel * 0.587, z: channel * 0.114, w: 0) }
            return frame.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": row(tint.r),
                "inputGVector": row(tint.g),
                "inputBVector": row(tint.b),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: tint.a),
            ])
        }
    }
}
