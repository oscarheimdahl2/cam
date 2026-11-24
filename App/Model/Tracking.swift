import Foundation

/// A tracked face or hand in output-frame units: `x`/`y` (centre) and `width` are fractions of the frame (y measured
/// from the top), `roll` is radians clockwise, `alpha` fades layers in and out when it is lost. For a face `width`
/// is the face width, for a hand it is the length of the palm.
struct TrackedPose: Equatable {
    var x: Double, y: Double, width: Double, roll: Double, alpha: Double
    /// Hands only: whether the palm (true) or the back of the hand (false) faces the camera. Nil unless the whole
    /// palm is in view and clearly turned one way or the other.
    var palmFacing: Bool? = nil
}

enum Hand: String, Codable, Hashable {
    case left, right
}

/// Which side of the hand a layer sits on. `either` follows the whole hand whichever way it faces; `palm` and `back`
/// are only drawn while that side faces the camera and the whole palm is in view.
enum HandSide: String, Codable, Hashable {
    case either, palm, back
}

/// One side of one hand, as a layer's target.
struct HandTarget: Codable, Hashable {
    var hand: Hand
    var side: HandSide

    private enum CodingKeys: String, CodingKey { case hand, side }

    init(hand: Hand, side: HandSide) { self.hand = hand; self.side = side }

    init(from decoder: Decoder) throws {
        // Early dev builds saved just a side ("either", "palm", "back"), for whichever hand was found first.
        if let legacy = try? decoder.singleValueContainer().decode(String.self) {
            self.init(hand: .right, side: HandSide(rawValue: legacy) ?? .either)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(hand: try c.decode(Hand.self, forKey: .hand), side: try c.decode(HandSide.self, forKey: .side))
    }
}

/// What can be followed.
enum TrackTarget: Hashable {
    case head
    case hand(HandTarget)
}

/// Everything currently tracked in the frame.
struct Tracking: Equatable {
    var head: TrackedPose?
    var leftHand: TrackedPose?
    var rightHand: TrackedPose?

    /// The pose of a target. A hand with a side only counts while that side faces the camera.
    func pose(for target: TrackTarget) -> TrackedPose? {
        switch target {
        case .head: return head
        case .hand(let t):
            let hand = rawHand(t.hand)
            switch t.side {
            case .either: return hand
            case .palm: return hand?.palmFacing == true ? hand : nil
            case .back: return hand?.palmFacing == false ? hand : nil
            }
        }
    }

    /// The pose a target is measured from, whichever side is showing (for working out a new layer's offset).
    func source(for target: TrackTarget) -> TrackedPose? {
        switch target {
        case .head: return head
        case .hand(let t): return rawHand(t.hand)
        }
    }

    private func rawHand(_ hand: Hand) -> TrackedPose? { hand == .left ? leftHand : rightHand }

    /// The pose a layer follows: nil for fixed layers (and while their target is lost).
    func pose(for layer: Layer) -> TrackedPose? { layer.trackTarget.flatMap(pose(for:)) }
}

extension HeadOffset {
    /// Where a layer with this offset sits on screen for the given tracked pose.
    func placement(for face: TrackedPose) -> Placement {
        let w = Double(CamConstants.width), h = Double(CamConstants.height)
        let faceWidth = face.width * w
        let c = cos(face.roll), s = sin(face.roll)
        // The stored offset is in the face's own axes, so rotate it by the head roll.
        let ox = (dx * c - dy * s) * faceWidth
        let oy = (dx * s + dy * c) * faceWidth
        return Placement(x: (face.x * w + ox) / w, y: (face.y * h + oy) / h,
                         width: scale * face.width, rotation: face.roll + roll)
    }

    /// The offset that puts a layer at the given on-screen placement for the given face (the inverse of `placement`).
    init(placement p: Placement, relativeTo face: TrackedPose) {
        let w = Double(CamConstants.width), h = Double(CamConstants.height)
        let faceWidth = face.width * w
        let ox = (p.x - face.x) * w / faceWidth
        let oy = (p.y - face.y) * h / faceWidth
        let c = cos(face.roll), s = sin(face.roll)
        self.init(dx: ox * c + oy * s, dy: -ox * s + oy * c, scale: p.width / face.width, roll: p.rotation - face.roll)
    }
}

extension Layer {
    /// Where the layer is drawn right now. `face` is the pose of whatever the layer follows (see `Tracking.pose(for:)`);
    /// a tracked layer has no placement while that is lost.
    func placement(face: TrackedPose?) -> Placement? {
        switch anchor {
        case .frame(let placement): return placement
        case .head(let offset), .hand(_, let offset): return face.map(offset.placement(for:))
        }
    }

    /// Stores a new on-screen placement. For a head layer this becomes the offset relative to the face.
    mutating func setPlacement(_ p: Placement, face: TrackedPose?) {
        switch anchor {
        case .frame: anchor = .frame(p)
        case .head:
            guard let face else { return }
            anchor = .head(HeadOffset(placement: p, relativeTo: face))
        case .hand(let target, _):
            guard let face else { return }
            anchor = .hand(target, HeadOffset(placement: p, relativeTo: face))
        }
    }
}
