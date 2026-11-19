import CoreImage
import CoreVideo
import Vision

/// "One Euro" filter: heavy smoothing while the value is nearly still (kills the detector's jitter) and lighter
/// smoothing the faster it moves (so quick head movements aren't laggy). Tune `minCutoff` (lower = steadier when
/// still) and `beta` (higher = catches up faster when moving).
private struct OneEuro {
    var minCutoff: Double
    var beta: Double
    var dCutoff = 1.0
    private var x: Double?
    private var dx = 0.0

    init(minCutoff: Double, beta: Double) { self.minCutoff = minCutoff; self.beta = beta }

    mutating func reset() { x = nil; dx = 0 }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    mutating func filter(_ value: Double, dt: Double) -> Double {
        guard let previous = x else { x = value; return value }
        let rawSpeed = (value - previous) / dt
        dx += Self.alpha(cutoff: dCutoff, dt: dt) * (rawSpeed - dx)
        let cutoff = minCutoff + beta * abs(dx)
        let filtered = previous + Self.alpha(cutoff: cutoff, dt: dt) * (value - previous)
        x = filtered
        return filtered
    }
}

/// Finds the largest face with Vision, maps it into the output frame, and smooths it.
/// Detection runs on a small copy of every second frame; smoothing runs every frame so motion stays fluid.
final class FaceTracker {
    private struct Pose { var x, y, width, roll: Double }

    private let request = VNDetectFaceRectanglesRequest()
    private var frameCount = 0
    private var target: Pose?
    private var state: Pose?
    private var lastSeen = -Double.infinity
    private var lastTime: Double?
    private var lastDetection: Double?
    // Cutoffs in Hz, beta in Hz per (frame-fractions per second). Width is filtered hardest: head stickers sit about
    // one face-width away from the face, so width noise would be magnified into visible shaking.
    private var filterX = OneEuro(minCutoff: 0.22, beta: 10)
    private var filterY = OneEuro(minCutoff: 0.22, beta: 10)
    private var filterWidth = OneEuro(minCutoff: 0.12, beta: 10)
    private var filterRoll = OneEuro(minCutoff: 0.22, beta: 1.5)

    private let hold = 0.5       // seconds to keep the last position after losing the face
    private let fade = 0.33      // seconds to fade out afterwards
    private let smoothing = 0.05 // only fills in between detections (every second frame), seconds

    func reset() {
        target = nil; state = nil; lastSeen = -.infinity; lastTime = nil; lastDetection = nil; frameCount = 0
        resetFilters()
    }

    private func resetFilters() {
        filterX.reset(); filterY.reset(); filterWidth.reset(); filterRoll.reset()
    }

    func update(frame: CVPixelBuffer, time: Double) -> FaceState? {
        frameCount += 1
        if frameCount % 2 == 1 { detect(frame, time: time) }

        guard var s = state else { return nil }
        let dt = lastTime.map { min(max(time - $0, 0), 0.2) } ?? 0
        lastTime = time
        if let t = target, dt > 0 {
            let a = 1 - exp(-dt / smoothing)
            s.x += (t.x - s.x) * a
            s.y += (t.y - s.y) * a
            s.width += (t.width - s.width) * a
            let d = t.roll - s.roll
            s.roll += atan2(sin(d), cos(d)) * a
            state = s
        }

        let lost = time - lastSeen
        let alpha = lost <= hold ? 1 : max(0, 1 - (lost - hold) / fade)
        if alpha <= 0 { state = nil; target = nil; return nil }
        return FaceState(x: s.x, y: s.y, width: s.width, roll: s.roll, alpha: alpha)
    }

    private func detect(_ frame: CVPixelBuffer, time: Double) {
        let fw = Double(CVPixelBufferGetWidth(frame)), fh = Double(CVPixelBufferGetHeight(frame))
        let shrink = 640 / fw
        let small = CIImage(cvPixelBuffer: frame).transformed(by: CGAffineTransform(scaleX: shrink, y: shrink))
        guard (try? VNImageRequestHandler(ciImage: small).perform([request])) != nil,
              let face = request.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height
                                                    < $1.boundingBox.width * $1.boundingBox.height }) else { return }

        // Vision: normalised, origin bottom-left. Map into the output frame the same way the compositor
        // aspect-fills the camera frame (see Compositor.fit).
        let ow = Double(OutputFrame.size.width), oh = Double(OutputFrame.size.height)
        let (fill, offset) = OutputFrame.aspectFill(CGSize(width: fw, height: fh))
        let s = Double(fill), offX = Double(offset.x), offY = Double(offset.y)
        let box = face.boundingBox
        let pose = Pose(x: (box.midX * fw * s + offX) / ow,
                        y: ((1 - box.midY) * fh * s + offY) / oh,
                        width: box.width * fw * s / ow,
                        // Measured: Vision's roll is positive counter-clockwise. Ours is clockwise-positive.
                        roll: -(face.roll?.doubleValue ?? 0))
        // A new face, or one back after a gap: start the filters from the fresh reading instead of gliding.
        if state == nil || lastDetection.map({ time - $0 > 0.5 }) ?? true { resetFilters() }
        let dt = lastDetection.map { min(max(time - $0, 0.001), 0.2) } ?? 0.066
        lastDetection = time
        let steady = Pose(x: filterX.filter(pose.x, dt: dt),
                          y: filterY.filter(pose.y, dt: dt),
                          width: filterWidth.filter(pose.width, dt: dt),
                          roll: filterRoll.filter(pose.roll, dt: dt))
        target = steady
        if state == nil { state = steady }
        lastSeen = time
    }
}
