import Foundation

/// Coordinates are normalized to the camera frame: x/y are the sticker centre (0...1, y measured from the top),
/// `width` is a fraction of the frame width, `rotation` is radians (clockwise on the unmirrored output).
struct Sticker: Codable, Identifiable, Equatable {
    var id = UUID()
    var file: String          // file name inside the stickers folder
    var x = 0.5
    var y = 0.5
    var width = 0.2
    var rotation = 0.0
    var aspect = 1.0          // image width / height
    var styled = false        // "sticker look": white border, rounded corners, drop shadow
}

extension Sticker {
    // Custom decoding so configs saved before `styled` existed still load.
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
    }
}

/// A saved sticker layout. `stickers` are ordered back (first) to front (last).
struct CamScene: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var blurEnabled = false
    var blurRadius = 20.0
    var stickers: [Sticker] = []
}

struct CamConfig: Codable, Equatable {
    var scenes: [CamScene] = [CamScene(name: "Clean")]
    var activeSceneID: UUID?
    var stickersEnabled = true
    var partyMode = false

    var activeIndex: Int {
        scenes.firstIndex { $0.id == activeSceneID } ?? 0
    }
    var activeScene: CamScene { scenes[activeIndex] }
}

extension CamConfig {
    // Custom decoding so configs saved before `partyMode` existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scenes = try c.decodeIfPresent([CamScene].self, forKey: .scenes) ?? [CamScene(name: "Clean")]
        activeSceneID = try c.decodeIfPresent(UUID.self, forKey: .activeSceneID)
        stickersEnabled = try c.decodeIfPresent(Bool.self, forKey: .stickersEnabled) ?? true
        partyMode = try c.decodeIfPresent(Bool.self, forKey: .partyMode) ?? false
    }
}
