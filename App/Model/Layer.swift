import Foundation

/// One item in a scene: *what* it shows (`content`) and *where it is attached* (`anchor`). Scenes are ordered lists
/// of layers, back (first) to front (last).
///
/// Adding a new kind of thing means adding a `Content` case (clock, video…) or an `Anchor` case (shoulder…).
/// They combine freely.
struct Layer: Identifiable, Equatable {
    var id = UUID()
    var content: Content
    var anchor: Anchor
    /// Drawn over the person instead of behind them.
    var inFront = false
    /// "Sticker look": white border, rounded corners and a soft shadow.
    var styled = false
    /// Width divided by height of the content.
    var aspect = 1.0
    /// Party mode, for stickers (image layers) only: a slow rainbow tint and, unless it is on the head, a slow spin
    /// (see `PartyStyle`).
    var party = false
    /// Switched off layers stay in the scene but are not drawn.
    var enabled = true
    /// Spin speed in radians per second: positive turns clockwise, negative counter-clockwise, 0 stands still (and the
    /// layer is back at its own rotation). Not for effects. A head layer that spins still moves and scales with the head but ignores its tilt.
    var spin = 0.0
}

extension Layer {
    static let maxSpin = 1.5

    /// The spin a party layer had before spinning became its own setting: slow, and clockwise or counter-clockwise
    /// depending on the layer's id (so it is stable).
    var legacyPartySpin: Double { 0.25 * (id.uuid.0 % 2 == 0 ? 1 : -1) }
}

extension Layer: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, content, anchor, inFront, styled, aspect, party, enabled, spin
        case motion   // read-only: an older version let a layer spin or tint itself, which is party mode now
    }

    // Custom coding so layers saved by older versions still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        content = try c.decode(Content.self, forKey: .content)
        anchor = try c.decode(Anchor.self, forKey: .anchor)
        inFront = try c.decodeIfPresent(Bool.self, forKey: .inFront) ?? false
        styled = try c.decodeIfPresent(Bool.self, forKey: .styled) ?? false
        aspect = try c.decodeIfPresent(Double.self, forKey: .aspect) ?? 1
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        let hadOwnMotion = !(try c.decodeIfPresent([Motion].self, forKey: .motion) ?? []).isEmpty
        // Party mode only exists for stickers.
        party = (try c.decodeIfPresent(Bool.self, forKey: .party) ?? false || hadOwnMotion) && isSticker
        if let saved = try c.decodeIfPresent(Double.self, forKey: .spin) {
            spin = saved
        } else if party && !followsHead {
            spin = legacyPartySpin   // party mode used to include a slow spin
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(content, forKey: .content)
        try c.encode(anchor, forKey: .anchor)
        try c.encode(inFront, forKey: .inFront)
        try c.encode(styled, forKey: .styled)
        try c.encode(aspect, forKey: .aspect)
        try c.encode(party, forKey: .party)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(spin, forKey: .spin)
    }
}

enum Content: Codable, Equatable {
    /// A file in the stickers folder.
    case image(file: String)
    case text(TextContent)
    /// A live particle effect (snow, fireflies, confetti…). It is drawn as a 16:9 picture the size of the frame.
    case particles(ParticleContent)
}

struct ParticleContent: Codable, Equatable, Hashable {
    var preset: ParticlePreset
    /// Recolours the whole effect like a filter. nil keeps the effect's own colors.
    var tint: RGBAColor?
}

/// The built-in particle effects. They map onto the presets of the Vortex library (see `ParticleHost`).
enum ParticlePreset: String, Codable, CaseIterable, Identifiable {
    case fireflies, snow, confetti, fireworks, magic, spark, fire, smoke, rain, splash

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Effects that only emit when triggered (they fire automatically every few seconds, and on request).
    var isBurstOnly: Bool { self == .confetti }
}

extension Layer {
    /// A particle layer covers the whole frame by default; it is drawn as a 16:9 picture.
    static func effect(_ preset: ParticlePreset) -> Layer {
        Layer(content: .particles(ParticleContent(preset: preset)),
              anchor: .frame(Placement(x: 0.5, y: 0.5, width: 1, rotation: 0)),
              inFront: true, aspect: 16.0 / 9.0)
    }
}

struct TextContent: Codable, Equatable, Hashable {
    var string = "Hello!"
    var color = RGBAColor(r: 1, g: 1, b: 1)
    var bold = true
}

/// Where a layer is attached. The numbers are in the same units as `Placement`.
enum Anchor: Codable, Equatable {
    /// A fixed spot in the video frame.
    case frame(Placement)
    /// Relative to the tracked face: it moves, scales and tilts with your head.
    case head(HeadOffset)
    /// Relative to the tracked hand (its centre, palm length and tilt), same numbers as `head`. Only drawn while the
    /// chosen side of the hand faces the camera.
    case hand(HandTarget, HeadOffset)
}

/// Placement relative to a tracked face or hand: the offset of the layer's centre from its centre in tracked widths
/// (along its own axes), the layer's width in tracked widths, and its tilt relative to the tracked roll.
struct HeadOffset: Codable, Equatable {
    var dx = 0.0
    var dy = -0.85   // above the head
    var scale = 1.0
    var roll = 0.0
}

/// Something a layer does over time. Party mode is made of these (see `PartyStyle`).
enum Motion: Codable, Equatable {
    /// Turns around its own centre, in radians per second (clockwise when positive).
    case spin(speed: Double)
    /// A solid colour wash that drifts round the rainbow: `speed` in trips round the colour wheel per second.
    case hueDrift(speed: Double, opacity: Double)
}

/// A simple on-screen position: `x`/`y` are the centre as fractions of the frame (y from the top), `width` is a
/// fraction of the frame width and `rotation` is radians, clockwise on the unmirrored output.
struct Placement: Codable, Equatable {
    var x: Double, y: Double, width: Double, rotation: Double
}

// MARK: - Duplicating

extension Layer {
    /// A copy to put next to the original. Fixed layers move a little so the copy doesn't hide the original; effects
    /// cover the frame anyway, so they stay put.
    func duplicate() -> Layer {
        var copy = self
        copy.id = UUID()
        guard !isEffect else { return copy }
        switch anchor {
        case .frame(let placement):
            var moved = placement
            moved.x += 0.03
            moved.y += 0.05
            copy.anchor = .frame(moved.keepingVisible(aspect: aspect, minVisiblePixels: 24))
        case .head(var offset):
            offset.dx += 0.2
            copy.anchor = .head(offset)
        case .hand(let target, var offset):
            offset.dx += 0.2
            copy.anchor = .hand(target, offset)
        }
        return copy
    }
}

extension CamScene {
    /// Puts a copy of a layer directly in front of it and returns the copy's id (nil if there is no such layer).
    @discardableResult
    mutating func duplicateLayer(_ id: UUID) -> UUID? {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return nil }
        let copy = layers[index].duplicate()
        layers.insert(copy, at: index + 1)
        return copy.id
    }
}

// MARK: - Reordering

extension CamScene {
    /// Applies a reorder from the layer list. The list shows the front at the top, so `source` and `destination` are
    /// positions in the *reversed* `layers`. `destination` follows SwiftUI's `onMove` convention: the gap the rows are
    /// dropped into, counted before they are taken out (so moving row 0 below row 1 is destination 2).
    mutating func moveLayers(inDisplayOrder source: IndexSet, to destination: Int) {
        var display = Array(layers.reversed())
        let moving = source.map { display[$0] }
        let removedAbove = source.filter { $0 < destination }.count
        for index in source.sorted(by: >) { display.remove(at: index) }
        display.insert(contentsOf: moving, at: destination - removedAbove)
        layers = Array(display.reversed())
    }
}

// MARK: - Keeping layers reachable

extension Placement {
    /// How much of a layer must stay inside the frame while dragging, as a fraction of its size.
    static let minVisibleFraction = 0.10

    /// Moves the placement as little as needed so enough of the layer stays inside the frame to be grabbed again.
    ///
    /// Along each axis at least `minVisibleFraction` of the layer's extent must overlap the frame, but never less than
    /// `minVisiblePixels`, so a tiny layer (where 10% would be a pixel or two) can still be clicked. A layer smaller
    /// than `minVisiblePixels` therefore has to stay fully inside. The layer's extent is that of its rotated box.
    ///
    /// - Parameters:
    ///   - aspect: the layer's width divided by its height.
    ///   - minVisiblePixels: in output-frame pixels (1920 wide), not screen points.
    func keepingVisible(aspect: Double, minVisiblePixels: Double) -> Placement {
        let frameW = Double(CamConstants.width), frameH = Double(CamConstants.height)
        let layerW = width * frameW
        let layerH = layerW / aspect
        let c = abs(cos(rotation)), s = abs(sin(rotation))
        let boundsW = layerW * c + layerH * s
        let boundsH = layerW * s + layerH * c

        func clamp(_ center: Double, extent: Double, frame: Double) -> Double {
            let visible = min(extent, max(extent * Self.minVisibleFraction, minVisiblePixels))
            // The near edge must reach `visible` pixels into the frame, and so must the far edge from the other side.
            let lowest = visible - extent / 2
            let highest = frame - visible + extent / 2
            return min(max(center, lowest), highest)
        }

        var result = self
        result.x = clamp(x * frameW, extent: boundsW, frame: frameW) / frameW
        result.y = clamp(y * frameH, extent: boundsH, frame: frameH) / frameH
        return result
    }
}

// MARK: - Editing helpers

extension Layer {
    /// An image layer. Only stickers have party mode.
    var isSticker: Bool {
        if case .image = content { return true }
        return false
    }

    var isEffect: Bool {
        if case .particles = content { return true }
        return false
    }

    /// What the layer follows, if anything.
    var trackTarget: TrackTarget? {
        switch anchor {
        case .frame: return nil
        case .head: return .head
        case .hand(let target, _): return .hand(target)
        }
    }

    var followsHead: Bool { trackTarget == .head }
    /// The hand the layer follows, if any.
    var followedHand: Hand? {
        if case .hand(let target) = trackTarget { return target.hand } else { return nil }
    }

    /// Changes which side of its hand the layer sits on (no effect on other layers).
    mutating func setHandSide(_ side: HandSide) {
        guard case .hand(var target, let offset) = anchor else { return }
        target.side = side
        anchor = .hand(target, offset)
    }
    var isTracked: Bool { trackTarget != nil }
}
