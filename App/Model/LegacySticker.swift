import Foundation

/// The old saved format: a scene held `stickers`, not `layers`. Only used to read old files; each one becomes an
/// image layer with the same id, so anything derived from the id (like a party-mode spin direction) is unchanged.
struct LegacySticker: Decodable {
    var id: UUID
    var file: String
    var x = 0.5, y = 0.5, width = 0.2, rotation = 0.0, aspect = 1.0
    var styled = false
    var inFront = false
    var followsHead = false
    var headDX = 0.0, headDY = -0.85, headScale = 1.0, headRoll = 0.0

    private enum CodingKeys: String, CodingKey {
        case id, file, x, y, width, rotation, aspect, styled, inFront, followsHead, headDX, headDY, headScale, headRoll
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        file = try c.decode(String.self, forKey: .file)
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0.5
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0.5
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 0.2
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        aspect = try c.decodeIfPresent(Double.self, forKey: .aspect) ?? 1
        styled = try c.decodeIfPresent(Bool.self, forKey: .styled) ?? false
        inFront = try c.decodeIfPresent(Bool.self, forKey: .inFront) ?? false
        followsHead = try c.decodeIfPresent(Bool.self, forKey: .followsHead) ?? false
        headDX = try c.decodeIfPresent(Double.self, forKey: .headDX) ?? 0
        headDY = try c.decodeIfPresent(Double.self, forKey: .headDY) ?? -0.85
        headScale = try c.decodeIfPresent(Double.self, forKey: .headScale) ?? 1
        headRoll = try c.decodeIfPresent(Double.self, forKey: .headRoll) ?? 0
    }

    var layer: Layer {
        Layer(id: id,
              content: .image(file: file),
              anchor: followsHead
                  ? .head(HeadOffset(dx: headDX, dy: headDY, scale: headScale, roll: headRoll))
                  : .frame(Placement(x: x, y: y, width: width, rotation: rotation)),
              inFront: inFront, styled: styled, aspect: aspect)
    }
}
