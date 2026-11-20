import Foundation

/// sRGB colour stored as plain numbers so it's easy to save.
struct RGBAColor: Codable, Equatable, Hashable {
    var r: Double, g: Double, b: Double
    /// Opacity, 0...1 (1 = the colour exactly as picked).
    var a: Double = 1
}

extension RGBAColor {
    // Custom decoding so colours saved before `a` existed load fully opaque.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        r = try c.decode(Double.self, forKey: .r)
        g = try c.decode(Double.self, forKey: .g)
        b = try c.decode(Double.self, forKey: .b)
        a = try c.decodeIfPresent(Double.self, forKey: .a) ?? 1
    }
}

/// A saved scene: a name and an ordered list of layers.
struct CamScene: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// SF Symbol shown in the scene list. Chosen by the user.
    var icon = SceneIcon.defaultName
    /// Back (first) to front (last).
    var layers: [Layer] = []
}

extension CamScene {
    private enum CodingKeys: String, CodingKey {
        case id, name, icon, layers
        // Read-only, for files saved by older versions:
        case stickers, partyMode
    }

    // Custom coding so scenes saved by older versions still load (and upgrade to layers).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        let savedIcon = try c.decodeIfPresent(String.self, forKey: .icon)
        if let saved = try c.decodeIfPresent([Layer].self, forKey: .layers) {
            layers = saved
        } else {
            layers = try c.decodeIfPresent([LegacySticker].self, forKey: .stickers)?.map(\.layer) ?? []
        }
        // Party mode used to be a switch for the whole scene. It is a per-layer option now, so a scene that had it
        // on keeps its look: every sticker gets it. (The border lights were dropped.)
        if try c.decodeIfPresent(Bool.self, forKey: .partyMode) == true {
            for i in layers.indices where layers[i].isSticker { layers[i].party = true }
        }
        // Scenes saved before icons were editable showed one picked from their contents; keep that as the starting icon.
        icon = savedIcon ?? (layers.contains { $0.party } ? "sparkles" : SceneIcon.defaultName)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(icon, forKey: .icon)
        try c.encode(layers, forKey: .layers)
    }
}

enum SceneIcon {
    static let defaultName = "photo.on.rectangle"
    /// The symbols offered in the icon picker.
    static let choices = [
        "photo.on.rectangle", "sparkles", "star.fill", "heart.fill", "flame.fill", "bolt.fill",
        "party.popper.fill", "gift.fill", "balloon.2.fill", "snowflake", "sun.max.fill", "moon.stars.fill",
        "cloud.fill", "leaf.fill", "pawprint.fill", "crown.fill", "theatermasks.fill", "camera.fill",
        "video.fill", "mic.fill", "briefcase.fill", "laptopcomputer", "graduationcap.fill", "gamecontroller.fill",
        "music.note", "paintpalette.fill", "face.smiling.fill", "hand.thumbsup.fill", "eyeglasses", "tshirt.fill",
    ]
}

struct CamConfig: Codable, Equatable {
    var scenes: [CamScene] = [CamScene(name: "Clean")]
    var activeSceneID: UUID?
    var stickersEnabled = true

    var activeIndex: Int {
        scenes.firstIndex { $0.id == activeSceneID } ?? 0
    }
    var activeScene: CamScene { scenes[activeIndex] }
}
