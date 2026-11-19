import XCTest

/// Head layers store their placement relative to the face. These check the math both ways.
final class FaceGeometryTests: XCTestCase {
    private func randomFace() -> FaceState {
        FaceState(x: .random(in: 0.2...0.8), y: .random(in: 0.2...0.8), width: .random(in: 0.08...0.4),
                  roll: .random(in: -0.9...0.9), alpha: 1)
    }

    private func headLayer() -> Layer {
        Layer(content: .image(file: "a.png"), anchor: .head(HeadOffset()))
    }

    func testSettingAPlacementAndReadingItBackIsLossless() {
        for _ in 0..<500 {
            let face = randomFace()
            let want = Placement(x: .random(in: 0...1), y: .random(in: 0...1),
                                 width: .random(in: 0.05...0.6), rotation: .random(in: -3...3))
            var layer = headLayer()
            layer.setPlacement(want, face: face)
            let got = layer.placement(face: face)!
            XCTAssertEqual(got.x, want.x, accuracy: 1e-9)
            XCTAssertEqual(got.y, want.y, accuracy: 1e-9)
            XCTAssertEqual(got.width, want.width, accuracy: 1e-9)
            XCTAssertEqual(got.rotation, want.rotation, accuracy: 1e-9)
        }
    }

    func testLayerKeepsItsSizeRelativeToTheFace() {
        let face = randomFace()
        var layer = headLayer()
        layer.setPlacement(Placement(x: 0.5, y: 0.3, width: 0.2, rotation: 0), face: face)
        var closer = face
        closer.width *= 1.5
        XCTAssertEqual(layer.placement(face: closer)!.width / closer.width,
                       layer.placement(face: face)!.width / face.width, accuracy: 1e-9)
    }

    func testLayerAboveTheHeadMovesRightWhenTheHeadTiltsClockwise() {
        let hat = headLayer()   // default offset is above the head
        let upright = hat.placement(face: FaceState(x: 0.5, y: 0.5, width: 0.2, roll: 0, alpha: 1))!
        XCTAssertLessThan(upright.y, 0.5)
        XCTAssertEqual(upright.x, 0.5, accuracy: 1e-9)

        let tilted = hat.placement(face: FaceState(x: 0.5, y: 0.5, width: 0.2, roll: .pi / 2, alpha: 1))!
        XCTAssertGreaterThan(tilted.x, 0.5)
        XCTAssertEqual(tilted.y, 0.5, accuracy: 1e-9)
        XCTAssertEqual(tilted.rotation, .pi / 2, accuracy: 1e-9)
    }

    func testHeadLayerHasNoPlacementWithoutAFaceButAFrameLayerAlwaysDoes() {
        XCTAssertNil(headLayer().placement(face: nil))
        let fixed = Layer(content: .image(file: "a.png"), anchor: .frame(Placement(x: 0.3, y: 0.4, width: 0.2, rotation: 0)))
        XCTAssertEqual(fixed.placement(face: nil)?.x, 0.3)
    }

    func testSettingAPlacementOnAFrameLayerMovesIt() {
        var fixed = Layer(content: .image(file: "a.png"), anchor: .frame(Placement(x: 0.3, y: 0.4, width: 0.2, rotation: 0)))
        fixed.setPlacement(Placement(x: 0.7, y: 0.1, width: 0.3, rotation: 1), face: nil)
        XCTAssertEqual(fixed.placement(face: nil), Placement(x: 0.7, y: 0.1, width: 0.3, rotation: 1))
    }

    // MARK: Keeping layers reachable

    private let frameW = Double(CamConstants.width), frameH = Double(CamConstants.height)

    /// How many pixels of a layer's box overlap the frame along x.
    private func overlapX(_ p: Placement, aspect: Double) -> Double {
        let layerW = p.width * frameW
        let left = p.x * frameW - layerW / 2, right = p.x * frameW + layerW / 2
        return min(right, frameW) - max(left, 0)
    }

    func testALayerCanBeDraggedMostOfTheWayOffTheFrameButTenPercentStays() {
        let wide = Placement(x: -3, y: 0.5, width: 0.3, rotation: 0)   // far off to the left
        let clamped = wide.keepingVisible(aspect: 1, minVisiblePixels: 10)
        let layerW = 0.3 * frameW
        XCTAssertEqual(overlapX(clamped, aspect: 1), layerW * 0.10, accuracy: 1e-6)
        XCTAssertLessThan(clamped.x, 0, "the centre is allowed outside the frame")
    }

    func testTheSameHoldsOnTheOtherSideAndVertically() {
        let right = Placement(x: 4, y: 0.5, width: 0.3, rotation: 0).keepingVisible(aspect: 1, minVisiblePixels: 10)
        XCTAssertEqual(overlapX(right, aspect: 1), 0.3 * frameW * 0.10, accuracy: 1e-6)

        let layerH = 0.3 * frameW   // aspect 1
        let below = Placement(x: 0.5, y: 5, width: 0.3, rotation: 0).keepingVisible(aspect: 1, minVisiblePixels: 10)
        XCTAssertEqual(frameH - (below.y * frameH - layerH / 2), layerH * 0.10, accuracy: 1e-6)
    }

    func testATinyLayerKeepsAtLeastTheMinimumPixelsVisibleSoItStaysClickable() {
        // 40 px wide: 10% would be 4 px, which is too little to grab. The 24 px floor applies instead.
        let tiny = Placement(x: -3, y: 0.5, width: 40 / frameW, rotation: 0).keepingVisible(aspect: 1, minVisiblePixels: 24)
        XCTAssertEqual(overlapX(tiny, aspect: 1), 24, accuracy: 1e-6)
    }

    func testALayerSmallerThanTheMinimumHasToStayFullyInside() {
        let speck = Placement(x: -3, y: 0.5, width: 10 / frameW, rotation: 0).keepingVisible(aspect: 1, minVisiblePixels: 24)
        XCTAssertEqual(overlapX(speck, aspect: 1), 10, accuracy: 1e-6)   // all of it
    }

    func testALayerThatIsAlreadyReachableIsLeftAlone() {
        let ok = Placement(x: 0.4, y: 0.6, width: 0.2, rotation: 0.3)
        XCTAssertEqual(ok.keepingVisible(aspect: 1.5, minVisiblePixels: 24), ok)
    }

    func testARotatedLayerIsMeasuredByItsRotatedBox() {
        // A tall thin layer turned a quarter turn is wide and short: 10% of its on-screen width must stay visible.
        let aspect = 0.25                                  // 100 px wide, 400 px tall unrotated
        let turned = Placement(x: -3, y: 0.5, width: 100 / frameW, rotation: .pi / 2).keepingVisible(aspect: aspect, minVisiblePixels: 1)
        let boundsW = 400.0                                // after the quarter turn
        XCTAssertEqual(turned.x * frameW + boundsW / 2, boundsW * 0.10, accuracy: 1e-6)
    }

    func testAFullFrameEffectCanBeSlidAwayButNotCompletelyOff() {
        let effect = Placement(x: 0.5, y: 0.5, width: 1, rotation: 0)
        let moved = Placement(x: 5, y: 0.5, width: effect.width, rotation: 0).keepingVisible(aspect: 16.0 / 9.0, minVisiblePixels: 24)
        XCTAssertEqual(frameW - (moved.x * frameW - frameW / 2), frameW * 0.10, accuracy: 1e-6)
    }

    // MARK: Reordering

    private func scene(_ names: [String]) -> CamScene {
        var scene = CamScene(name: "t")
        scene.layers = names.map { Layer(content: .image(file: $0), anchor: .frame(Placement(x: 0.5, y: 0.5, width: 0.2, rotation: 0))) }
        return scene
    }

    private func files(_ scene: CamScene) -> [String] {
        scene.layers.compactMap { if case .image(let file) = $0.content { return file } else { return nil } }
    }

    // The list shows the front at the top, so for layers [a, b, c, d] (back to front) the rows read d, c, b, a.

    func testMovingTheBottomRowToTheTopBringsThatLayerToTheFront() {
        var s = scene(["a", "b", "c", "d"])
        s.moveLayers(inDisplayOrder: IndexSet(integer: 3), to: 0)   // row "a" to the top
        XCTAssertEqual(files(s), ["b", "c", "d", "a"])
    }

    func testMovingTheTopRowToTheBottomSendsThatLayerToTheBack() {
        var s = scene(["a", "b", "c", "d"])
        s.moveLayers(inDisplayOrder: IndexSet(integer: 0), to: 4)   // row "d" past the end
        XCTAssertEqual(files(s), ["d", "a", "b", "c"])
    }

    func testDestinationCountsGapsBeforeTheRowIsTakenOut() {
        var s = scene(["a", "b", "c", "d"])                         // rows: d c b a
        s.moveLayers(inDisplayOrder: IndexSet(integer: 0), to: 2)   // d goes below c: c d b a
        XCTAssertEqual(files(s), ["a", "b", "d", "c"])
    }

    func testDroppingARowWhereItAlreadyIsChangesNothing() {
        var s = scene(["a", "b", "c", "d"])
        s.moveLayers(inDisplayOrder: IndexSet(integer: 1), to: 1)
        s.moveLayers(inDisplayOrder: IndexSet(integer: 1), to: 2)
        XCTAssertEqual(files(s), ["a", "b", "c", "d"])
    }

    // MARK: Duplicating

    func testADuplicateSitsDirectlyInFrontOfTheOriginalWithANewIdAndASmallOffset() {
        var s = scene(["a", "b", "c"])
        let original = s.layers[1]
        let copyID = s.duplicateLayer(original.id)
        XCTAssertEqual(files(s), ["a", "b", "b", "c"])
        XCTAssertNotNil(copyID)
        XCTAssertNotEqual(copyID, original.id)
        XCTAssertEqual(s.layers[2].id, copyID)
        guard case .frame(let from) = original.anchor, case .frame(let to) = s.layers[2].anchor else { return XCTFail() }
        XCTAssertGreaterThan(to.x, from.x)   // nudged, so it doesn't hide the original
        XCTAssertGreaterThan(to.y, from.y)
        XCTAssertEqual(to.width, from.width)
    }

    func testDuplicatingAnEffectKeepsItInPlaceAndKeepsItsTint() {
        var s = CamScene(name: "t")
        var effect = Layer.effect(.snow)
        effect.content = .particles(ParticleContent(preset: .snow, tint: RGBAColor(r: 1, g: 0, b: 0)))
        s.layers = [effect]
        s.duplicateLayer(effect.id)
        XCTAssertEqual(s.layers.count, 2)
        XCTAssertEqual(s.layers[1].anchor, effect.anchor)
        XCTAssertEqual(s.layers[1].content, effect.content)
    }

    func testDuplicatingAHeadLayerMovesTheCopyAlongTheHead() {
        var s = CamScene(name: "t")
        let hat = Layer(content: .image(file: "hat.png"), anchor: .head(HeadOffset()))
        s.layers = [hat]
        s.duplicateLayer(hat.id)
        guard case .head(let offset) = s.layers[1].anchor else { return XCTFail() }
        XCTAssertGreaterThan(offset.dx, 0)
        XCTAssertEqual(offset.dy, HeadOffset().dy)
    }

    func testDuplicatingAnUnknownLayerDoesNothing() {
        var s = scene(["a"])
        XCTAssertNil(s.duplicateLayer(UUID()))
        XCTAssertEqual(files(s), ["a"])
    }
}
