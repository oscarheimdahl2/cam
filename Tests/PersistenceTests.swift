import XCTest

/// Saved files from older versions must keep loading, and saving must be debounced but never lose the last change.
final class LegacyDecodingTests: XCTestCase {
    private func decodeScene(_ json: String) throws -> CamScene {
        try JSONDecoder().decode(CamScene.self, from: Data(json.utf8))
    }

    func testStickersFromTheOldFormatBecomeImageLayers() throws {
        let json = #"""
        {"id":"7B1E2C1A-5D0B-4C58-9A57-3E9B1E0C6A10","name":"Old","stickers":[
          {"id":"7B1E2C1A-5D0B-4C58-9A57-3E9B1E0C6A11","file":"a.png","x":0.3,"y":0.4,"width":0.25,"rotation":0.5,"aspect":2,"styled":true,"inFront":true},
          {"id":"7B1E2C1A-5D0B-4C58-9A57-3E9B1E0C6A12","file":"b.png","followsHead":true,"headDX":0.1,"headDY":-1,"headScale":1.5,"headRoll":0.2,"inFront":true}
        ]}
        """#
        let scene = try decodeScene(json)
        XCTAssertEqual(scene.layers.count, 2)

        let fixed = scene.layers[0]
        XCTAssertEqual(fixed.id, UUID(uuidString: "7B1E2C1A-5D0B-4C58-9A57-3E9B1E0C6A11"))   // id kept
        XCTAssertEqual(fixed.content, .image(file: "a.png"))
        XCTAssertEqual(fixed.anchor, .frame(Placement(x: 0.3, y: 0.4, width: 0.25, rotation: 0.5)))
        XCTAssertEqual(fixed.aspect, 2)
        XCTAssertTrue(fixed.styled)
        XCTAssertTrue(fixed.inFront)

        let head = scene.layers[1]
        XCTAssertEqual(head.anchor, .head(HeadOffset(dx: 0.1, dy: -1, scale: 1.5, roll: 0.2)))
        XCTAssertFalse(head.styled)   // old files without the flag meant "no sticker look"
    }

    func testSceneSavedBeforeEffectsDecodes() throws {
        let json = #"{"id":"7B1E2C1A-5D0B-4C58-9A57-3E9B1E0C6A02","name":"Old","blurEnabled":true,"blurRadius":20,"stickers":[]}"#
        let scene = try JSONDecoder().decode(CamScene.self, from: Data(json.utf8))
        XCTAssertTrue(scene.blurEnabled)
    }

    func testASceneThatHadPartyModeOnTurnsItOnForItsStickers() throws {
        let json = #"""
        {"id":"7B1E2C1A-5D0B-4C58-9A57-3E9B1E0C6A03","name":"Party","partyMode":true,"lightsEnabled":true,
         "lightColorA":{"r":1,"g":0,"b":0},"stickers":[
           {"id":"7B1E2C1A-5D0B-4C58-9A57-3E9B1E0C6A21","file":"a.png"},
           {"id":"7B1E2C1A-5D0B-4C58-9A57-3E9B1E0C6A22","file":"b.png","followsHead":true}]}
        """#
        let scene = try JSONDecoder().decode(CamScene.self, from: Data(json.utf8))
        XCTAssertEqual(scene.layers.map(\.party), [true, true])
    }

    func testASceneWithoutPartyModeLeavesLayersAlone() throws {
        let json = #"{"id":"7B1E2C1A-5D0B-4C58-9A57-3E9B1E0C6A06","name":"Plain","stickers":[{"id":"7B1E2C1A-5D0B-4C58-9A57-3E9B1E0C6A23","file":"a.png"}]}"#
        let scene = try JSONDecoder().decode(CamScene.self, from: Data(json.utf8))
        XCTAssertEqual(scene.layers.map(\.party), [false])
    }

    func testALayerSavedBeforePartyExistedDecodes() throws {
        let json = #"{"id":"7B1E2C1A-5D0B-4C58-9A57-3E9B1E0C6A24","content":{"image":{"file":"a.png"}},"anchor":{"frame":{"_0":{"x":0.5,"y":0.5,"width":0.2,"rotation":0}}},"inFront":true}"#
        let layer = try JSONDecoder().decode(Layer.self, from: Data(json.utf8))
        XCTAssertFalse(layer.party)
        XCTAssertTrue(layer.inFront)
    }

    func testConfigWithObsoleteKeysDecodes() throws {
        let json = #"{"scenes":[{"id":"7B1E2C1A-5D0B-4C58-9A57-3E9B1E0C6A04","name":"A","stickers":[]}],"stickersEnabled":false,"partyMode":true}"#
        let config = try JSONDecoder().decode(CamConfig.self, from: Data(json.utf8))
        XCTAssertFalse(config.stickersEnabled)
        XCTAssertEqual(config.scenes.count, 1)
    }
}

final class LayerFormatTests: XCTestCase {
    func testASceneWithEveryKindOfLayerSurvivesSavingAndLoading() throws {
        var scene = CamScene(name: "Mixed")
        scene.layers = [
            Layer(content: .image(file: "tree.png"),
                  anchor: .frame(Placement(x: 0.2, y: 0.4, width: 0.18, rotation: 0.1)),
                  styled: true, aspect: 0.8, party: true),
            Layer(content: .text(TextContent(string: "Friday!", color: RGBAColor(r: 1, g: 0, b: 0.5, a: 0.9), bold: false)),
                  anchor: .head(HeadOffset(dx: 0, dy: 1.2, scale: 2, roll: 0)),
                  inFront: true, aspect: 3),
            .effect(.confetti),
            Layer(content: .particles(ParticleContent(preset: .snow, tint: RGBAColor(r: 0.2, g: 0.4, b: 1))),
                  anchor: .frame(Placement(x: 0.5, y: 0.5, width: 1, rotation: 0)), inFront: true, aspect: 16.0 / 9.0),
        ]
        let data = try JSONEncoder().encode(scene)
        XCTAssertEqual(try JSONDecoder().decode(CamScene.self, from: data), scene)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"stickers\""), "new files use layers only")
    }

    func testAnEffectSavedBeforeTintExistedHasNoTint() throws {
        let json = #"{"id":"7B1E2C1A-5D0B-4C58-9A57-3E9B1E0C6A40","content":{"particles":{"_0":{"preset":"snow"}}},"anchor":{"frame":{"_0":{"x":0.5,"y":0.5,"width":1,"rotation":0}}},"aspect":1.7777777777777777}"#
        let layer = try JSONDecoder().decode(Layer.self, from: Data(json.utf8))
        XCTAssertEqual(layer.content, .particles(ParticleContent(preset: .snow, tint: nil)))
    }

    func testPartyModeIsOnlyForStickers() throws {
        // A scene that had party mode on: the image layer gets it, the text layer and the effect do not.
        let json = #"""
        {"id":"7B1E2C1A-5D0B-4C58-9A57-3E9B1E0C6A30","name":"P","partyMode":true,"layers":[
          {"id":"7B1E2C1A-5D0B-4C58-9A57-3E9B1E0C6A31","content":{"image":{"file":"a.png"}},"anchor":{"frame":{"_0":{"x":0.5,"y":0.5,"width":0.2,"rotation":0}}}},
          {"id":"7B1E2C1A-5D0B-4C58-9A57-3E9B1E0C6A32","content":{"text":{"_0":{"string":"Hi","color":{"r":1,"g":1,"b":1,"a":1},"bold":true}}},"anchor":{"frame":{"_0":{"x":0.5,"y":0.5,"width":0.2,"rotation":0}}},"party":true}]}
        """#
        let scene = try JSONDecoder().decode(CamScene.self, from: Data(json.utf8))
        XCTAssertEqual(scene.layers.map(\.party), [true, false])
        XCTAssertEqual(Layer.effect(.snow).party, false)
    }

    func testALayerThatSpunOrTintedItselfBecomesPartyMode() throws {
        let json = #"{"id":"7B1E2C1A-5D0B-4C58-9A57-3E9B1E0C6A33","content":{"image":{"file":"a.png"}},"anchor":{"frame":{"_0":{"x":0.5,"y":0.5,"width":0.2,"rotation":0}}},"motion":[{"spin":{"speed":0.4}}]}"#
        let layer = try JSONDecoder().decode(Layer.self, from: Data(json.utf8))
        XCTAssertTrue(layer.party)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(layer), as: UTF8.self).contains("motion"), "the old key is not written back")
    }
}

@MainActor
final class ConfigStoreTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("cam-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    func testFreshFolderGivesADefaultConfigWithAnActiveScene() {
        let config = ConfigStore(folder: folder).load()
        XCTAssertEqual(config.scenes.count, 1)
        XCTAssertEqual(config.activeSceneID, config.scenes[0].id)
    }

    func testFlushWritesTheLatestConfigAndLoadReadsItBack() {
        let store = ConfigStore(folder: folder, saveDelay: .seconds(60))
        var config = store.load()
        config.scenes[0].name = "Renamed"
        config.scenes[0].blurEnabled = true
        store.save(config)
        store.flush()
        let loaded = ConfigStore(folder: folder).load()
        XCTAssertEqual(loaded.scenes[0].name, "Renamed")
        XCTAssertTrue(loaded.scenes[0].blurEnabled)
    }

    func testRapidSavesAreDebouncedToTheLastOne() async throws {
        let store = ConfigStore(folder: folder, saveDelay: .milliseconds(40))
        var config = store.load()
        for i in 1...20 {
            config.scenes[0].name = "Drag \(i)"
            store.save(config)
        }
        // Nothing has been written yet: the delay hasn't passed.
        XCTAssertEqual(ConfigStore(folder: folder).load().scenes[0].name, CamConfig().scenes[0].name)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(ConfigStore(folder: folder).load().scenes[0].name, "Drag 20")
    }

    func testALoadedConfigNeverPointsAtAMissingScene() throws {
        let store = ConfigStore(folder: folder)
        var config = store.load()
        config.activeSceneID = UUID()   // stale id
        store.save(config)
        store.flush()
        let loaded = ConfigStore(folder: folder).load()
        XCTAssertTrue(loaded.scenes.contains { $0.id == loaded.activeSceneID })
    }
}
