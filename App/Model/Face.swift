import Foundation

/// The tracked face in output-frame units: `x`/`y` (centre) and `width` are fractions of the frame (y measured from
/// the top), `roll` is radians clockwise, `alpha` fades head layers in and out when the face is lost.
struct FaceState: Equatable {
    var x: Double, y: Double, width: Double, roll: Double, alpha: Double
}

extension HeadOffset {
    /// Where a layer with this offset sits on screen for the given face.
    func placement(for face: FaceState) -> Placement {
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
    init(placement p: Placement, relativeTo face: FaceState) {
        let w = Double(CamConstants.width), h = Double(CamConstants.height)
        let faceWidth = face.width * w
        let ox = (p.x - face.x) * w / faceWidth
        let oy = (p.y - face.y) * h / faceWidth
        let c = cos(face.roll), s = sin(face.roll)
        self.init(dx: ox * c + oy * s, dy: -ox * s + oy * c, scale: p.width / face.width, roll: p.rotation - face.roll)
    }
}

extension Layer {
    /// Where the layer is drawn right now. A head layer has no placement while no face is tracked.
    func placement(face: FaceState?) -> Placement? {
        switch anchor {
        case .frame(let placement): return placement
        case .head(let offset): return face.map(offset.placement(for:))
        }
    }

    /// Stores a new on-screen placement. For a head layer this becomes the offset relative to the face.
    mutating func setPlacement(_ p: Placement, face: FaceState?) {
        switch anchor {
        case .frame: anchor = .frame(p)
        case .head:
            guard let face else { return }
            anchor = .head(HeadOffset(placement: p, relativeTo: face))
        }
    }
}
