import CoreImage
import Vision

/// Cuts the person out of a camera frame with Vision's on-device person segmentation.
final class PersonSegmenter {
    private let request = VNGeneratePersonSegmentationRequest()
    private let handler = VNSequenceRequestHandler()   // a sequence handler lets Vision smooth the mask over time

    init() {
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    /// A soft mask (white = person) aligned with the output frame, or nil if segmentation failed.
    func mask(for frame: CVPixelBuffer) -> CIImage? {
        guard (try? handler.perform([request], on: frame)) != nil,
              let buffer = request.results?.first?.pixelBuffer else { return nil }
        let toFrame = CGAffineTransform(
            scaleX: CGFloat(CVPixelBufferGetWidth(frame)) / CGFloat(CVPixelBufferGetWidth(buffer)),
            y: CGFloat(CVPixelBufferGetHeight(frame)) / CGFloat(CVPixelBufferGetHeight(buffer)))
        // Clamp first: blurring at the frame edge would otherwise pull in transparent black and fade the mask there,
        // leaving a sliver of background where the person touches the edge.
        return OutputFrame.fit(CIImage(cvPixelBuffer: buffer).transformed(by: toFrame))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 1.5)
            .cropped(to: OutputFrame.rect)
    }
}
