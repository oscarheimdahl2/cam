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

/// Tracks one thing in the camera frame (a head or a hand): runs a Vision detector on a small copy of every second
/// frame, maps the reading into the output frame, and smooths it. Detection is the only part that differs between
/// head and hand, so it is passed in as a `Detector`; smoothing runs every frame so motion stays fluid.
final class PoseTracker {
    /// A reading in Vision's terms: centre and `width` as fractions of the frame (origin bottom-left), `roll` in
    /// radians, clockwise positive. Nil when nothing was found.
    struct Reading { var midX, midY, width, roll: Double; var palmFacing: Bool? = nil }
    /// Runs Vision on the handler, given the frame size in pixels.
    typealias Detector = (VNImageRequestHandler, _ frameSize: CGSize) -> Reading?

    /// How hard each value is smoothed: cutoffs in Hz, beta in Hz per (frame-fractions per second).
    struct Tuning {
        var position: Double, width: Double, roll: Double
    }

    private struct Pose { var x, y, width, roll: Double; var palmFacing: Bool? = nil }

    private let detector: Detector
    private var frameCount = 0
    private var target: Pose?
    private var state: Pose?
    private var lastSeen = -Double.infinity
    private var lastTime: Double?
    private var lastDetection: Double?
    private var filterX: OneEuro, filterY: OneEuro, filterWidth: OneEuro, filterRoll: OneEuro

    private let hold = 0.5       // seconds to keep the last position after losing it
    private let fade = 0.33      // seconds to fade out afterwards
    private let smoothing = 0.05 // only fills in between detections (every second frame), seconds

    init(tuning: Tuning, detector: @escaping Detector) {
        self.detector = detector
        filterX = OneEuro(minCutoff: tuning.position, beta: 10)
        filterY = OneEuro(minCutoff: tuning.position, beta: 10)
        filterWidth = OneEuro(minCutoff: tuning.width, beta: 10)
        filterRoll = OneEuro(minCutoff: tuning.roll, beta: 1.5)
    }

    func reset() {
        target = nil; state = nil; lastSeen = -.infinity; lastTime = nil; lastDetection = nil; frameCount = 0
        resetFilters()
    }

    private func resetFilters() {
        filterX.reset(); filterY.reset(); filterWidth.reset(); filterRoll.reset()
    }

    func update(frame: CVPixelBuffer, time: Double) -> TrackedPose? {
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
            s.palmFacing = t.palmFacing
            state = s
        }

        let lost = time - lastSeen
        let alpha = lost <= hold ? 1 : max(0, 1 - (lost - hold) / fade)
        if alpha <= 0 { state = nil; target = nil; return nil }
        return TrackedPose(x: s.x, y: s.y, width: s.width, roll: s.roll, alpha: alpha, palmFacing: s.palmFacing)
    }

    private func detect(_ frame: CVPixelBuffer, time: Double) {
        let fw = Double(CVPixelBufferGetWidth(frame)), fh = Double(CVPixelBufferGetHeight(frame))
        let shrink = 640 / fw
        let small = CIImage(cvPixelBuffer: frame).transformed(by: CGAffineTransform(scaleX: shrink, y: shrink))
        guard let found = detector(VNImageRequestHandler(ciImage: small), CGSize(width: fw, height: fh)) else { return }

        // Vision: normalised, origin bottom-left. Map into the output frame the same way the compositor
        // aspect-fills the camera frame (see Compositor.fit).
        let ow = Double(OutputFrame.size.width), oh = Double(OutputFrame.size.height)
        let (fill, offset) = OutputFrame.aspectFill(CGSize(width: fw, height: fh))
        let s = Double(fill), offX = Double(offset.x), offY = Double(offset.y)
        let pose = Pose(x: (found.midX * fw * s + offX) / ow,
                        y: ((1 - found.midY) * fh * s + offY) / oh,
                        width: found.width * fw * s / ow,
                        roll: found.roll, palmFacing: found.palmFacing)
        // Something new, or back after a gap: start the filters from the fresh reading instead of gliding.
        if state == nil || lastDetection.map({ time - $0 > 0.5 }) ?? true { resetFilters() }
        let dt = lastDetection.map { min(max(time - $0, 0.001), 0.2) } ?? 0.066
        lastDetection = time
        let steady = Pose(x: filterX.filter(pose.x, dt: dt),
                          y: filterY.filter(pose.y, dt: dt),
                          width: filterWidth.filter(pose.width, dt: dt),
                          roll: filterRoll.filter(pose.roll, dt: dt),
                          palmFacing: pose.palmFacing)
        target = steady
        if state == nil { state = steady }
        lastSeen = time
    }
}

// MARK: - Head and hand

extension PoseTracker {
    /// The largest face. Width is filtered hardest: head stickers sit about one face-width away from the face, so
    /// width noise would be magnified into visible shaking.
    static func head() -> PoseTracker {
        let request = VNDetectFaceRectanglesRequest()
        return PoseTracker(tuning: Tuning(position: 0.22, width: 0.12, roll: 0.22)) { handler, _ in
            guard (try? handler.perform([request])) != nil,
                  let face = request.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height
                                                        < $1.boundingBox.width * $1.boundingBox.height }) else { return nil }
            let box = face.boundingBox
            // Measured: Vision's roll is positive counter-clockwise. Ours is clockwise-positive.
            return Reading(midX: box.midX, midY: box.midY, width: box.width, roll: -(face.roll?.doubleValue ?? 0))
        }
    }

    /// One of the two hands: its centre is the middle of the wrist and the four finger knuckles, its width the length of the
    /// palm (wrist to middle knuckle) and its roll the way the palm points. Hands move faster and are detected
    /// less steadily than faces, so the position is filtered a little less.
    static func hand(_ which: Hand) -> PoseTracker {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        let chirality: VNChirality = which == .left ? .left : .right
        let palm: [VNHumanHandPoseObservation.JointName] = [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP]
        return PoseTracker(tuning: Tuning(position: 0.4, width: 0.2, roll: 0.4)) { handler, size in
            guard (try? handler.perform([request])) != nil,
                  let hand = request.results?.first(where: { $0.chirality == chirality }),
                  let points = try? hand.recognizedPoints(.all) else { return nil }
            let known = palm.compactMap { points[$0] }.filter { $0.confidence > 0.3 }
            guard let wrist = points[.wrist], wrist.confidence > 0.3,
                  let middle = points[.middleMCP], middle.confidence > 0.3, !known.isEmpty else { return nil }
            // The angle and length have to be measured in pixels, not in the stretched 0...1 units.
            let vx = (middle.location.x - wrist.location.x) * size.width
            let vy = (middle.location.y - wrist.location.y) * size.height
            let n = Double(known.count)
            return Reading(midX: known.reduce(0) { $0 + Double($1.location.x) } / n,
                           midY: known.reduce(0) { $0 + Double($1.location.y) } / n,
                           width: Double(hypot(vx, vy) / size.width),
                           roll: Double(atan2(vx, vy)),   // clockwise from "up"
                           palmFacing: palmSide(hand, points, size))
        }
    }

    /// Whether the palm (true) or the back of the hand (false) faces the camera, or nil unless that is certain: the
    /// whole palm (wrist and the four finger knuckles) has to be found with confidence and inside the frame, and the
    /// hand has to be clearly turned to one side (not edge-on). Looking at the hand from the front with the fingers
    /// up, a right hand showing its palm has the index knuckle on the image's right, and a left hand the other way
    /// round; the back is the opposite. The camera image is not mirrored, so this is the anatomical hand.
    private static func palmSide(_ hand: VNHumanHandPoseObservation,
                                 _ points: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint],
                                 _ size: CGSize) -> Bool? {
        let joints: [VNHumanHandPoseObservation.JointName] = [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP]
        let palm = joints.compactMap { points[$0] }
        guard hand.chirality != .unknown, palm.count == joints.count,
              palm.allSatisfy({ $0.confidence > 0.5 && (0.02...0.98).contains($0.location.x)
                                && (0.02...0.98).contains($0.location.y) }),
              let wrist = points[.wrist], let index = points[.indexMCP], let little = points[.littleMCP] else { return nil }
        let ax = Double(index.location.x - wrist.location.x) * size.width
        let ay = Double(index.location.y - wrist.location.y) * size.height
        let bx = Double(little.location.x - wrist.location.x) * size.width
        let by = Double(little.location.y - wrist.location.y) * size.height
        let length = hypot(ax, ay) * hypot(bx, by)
        guard length > 0 else { return nil }
        let sine = (ax * by - ay * bx) / length   // positive: index on the image's right
        guard abs(sine) > 0.35 else { return nil }
        return (sine > 0) == (hand.chirality == .right)
    }
}
