import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Turns a raw camera frame into the final frame: the real picture, with layers behind
/// the person, and "in front" layers over them.
///
/// The pieces live in their own types: `PersonSegmenter`, `LayerRenderer` (+ `TextRenderer`, `StickerLook`, `PartyStyle`)
/// This class only decides what goes in which layer.
final class Compositor {
    let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let segmenter = PersonSegmenter()
    private let layers: LayerRenderer

    init(stickersDir: URL, particleFrames: ParticleFrames) {
        layers = LayerRenderer(directory: stickersDir, particleFrames: particleFrames)
    }

    func forgetCachedImages() { layers.forgetCachedImages() }

    // MARK: Composing

    /// `time` (seconds) drives the layers' motion. `tracking` holds the head and hand for layers that follow them.
    func render(frame: CVPixelBuffer, scene: CamScene, stickersEnabled: Bool,
                time: Double = 0, tracking: Tracking = Tracking()) -> CIImage {
        composite(frame: frame, scene: scene, stickersEnabled: stickersEnabled, time: time, tracking: tracking)
    }

    private func composite(frame: CVPixelBuffer, scene: CamScene, stickersEnabled: Bool,
                           time: Double, tracking: Tracking) -> CIImage {
        let base = OutputFrame.fit(CIImage(cvPixelBuffer: frame))
        let all = stickersEnabled ? Array(scene.layers.enumerated()).filter { $0.element.enabled } : []
        let behind = all.filter { !$0.element.inFront }
        let front = all.filter { $0.element.inFront }
        func draw(_ layer: Layer, _ index: Int) -> CIImage? {
            layers.image(for: layer, index: index, time: time, tracking: tracking)
        }

        var result = base
        // The person cut-out is only needed to put layers behind them. (Background blur isn't done here: macOS's own
        // Portrait effect is applied to the camera picture before Cam receives it.)
        if !behind.isEmpty, let mask = segmenter.mask(for: frame) {
            var background = base
            for (index, layer) in behind {
                if let image = draw(layer, index) { background = image.composited(over: background) }
            }
            let blend = CIFilter.blendWithMask()
            blend.inputImage = base
            blend.backgroundImage = background
            blend.maskImage = mask
            result = blend.outputImage?.cropped(to: OutputFrame.rect) ?? base
        }
        // "In front of me" layers (hats, glasses…) go over the person.
        for (index, layer) in front {
            if let image = draw(layer, index) { result = image.composited(over: result) }
        }
        // Layers can hang off the edge of the frame; without this the image grows beyond it.
        return result.cropped(to: OutputFrame.rect)
    }

    // MARK: Output

    func render(_ image: CIImage, to buffer: CVPixelBuffer) {
        ciContext.render(image, to: buffer, bounds: OutputFrame.rect, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// A downscaled copy for the editor preview. Always exactly the output frame, whatever the image's extent.
    func cgImage(_ image: CIImage, maxWidth: CGFloat) -> CGImage? {
        let scale = maxWidth / OutputFrame.size.width
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let frame = CGRect(x: 0, y: 0, width: OutputFrame.size.width * scale, height: OutputFrame.size.height * scale)
        return ciContext.createCGImage(scaled, from: frame)
    }
}
