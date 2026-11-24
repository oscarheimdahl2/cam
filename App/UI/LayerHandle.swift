import SwiftUI

/// The selection box and the move / resize / rotate handles for one layer on the preview.
/// Works in on-screen placements, so it behaves the same for layers fixed in the frame and layers on the head.
struct LayerHandle: View {
    @ObservedObject var model: AppModel
    let layer: Layer
    let tracking: Tracking
    let canvas: CGSize
    /// Whether the preview is flipped like a mirror. Everything below is in on-screen terms, so it has to know.
    let mirrored: Bool
    @State private var dragStart: (placement: Placement, point: CGPoint)?

    /// However far a layer is dragged, at least this much of it (on screen, in points) stays inside the video, so it
    /// can always be grabbed again.
    private static let minVisiblePoints = 24.0
    /// How far (in points) the pointer has to travel before a drag moves the layer.
    private static let dragDeadZone = 4.0

    private var selected: Bool { model.selectedLayerID == layer.id }

    var body: some View {
        // A tracked layer has no placement while its head or hand is lost, so there's nothing to grab.
        if let place = layer.placement(face: tracking.pose(for: layer)) {
            let boxWidth = CGFloat(place.width) * canvas.width
            let boxHeight = boxWidth / CGFloat(layer.aspect)
            // Centre in canvas space (x runs the other way when the preview is mirrored).
            let center = CGPoint(x: (mirrored ? 1 - place.x : place.x) * canvas.width, y: place.y * canvas.height)
            ZStack {
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .overlay(Rectangle().stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2))
                    .frame(width: boxWidth, height: boxHeight)
                    .gesture(moveGesture(place))
                    .onTapGesture { model.selectedLayerID = layer.id }   // a plain click selects, without moving anything
                if selected {
                    handle(systemImage: "arrow.up.left.and.arrow.down.right")
                        .position(x: boxWidth / 2, y: boxHeight / 2)
                        .gesture(resizeGesture(place, center: center))
                    handle(systemImage: "arrow.clockwise")
                        .position(x: boxWidth / 2, y: -18)
                        .gesture(rotateGesture(place, center: center))
                }
            }
            .frame(width: boxWidth, height: boxHeight)
            .rotationEffect(.radians(mirrored ? -place.rotation : place.rotation))   // a mirror turns clockwise into counter-clockwise
            .position(center)
            // An effect usually covers the whole frame: only let it catch clicks while it is selected,
            // so it doesn't block the layers underneath. (Select it from the list.)
            .allowsHitTesting(!layer.isEffect || selected)
        }
    }

    private func handle(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(Circle().fill(Color.accentColor))
    }

    private func moveGesture(_ place: Placement) -> some Gesture {
        // A small dead zone, so a click or a slightly shaky hand doesn't nudge the layer.
        DragGesture(minimumDistance: Self.dragDeadZone, coordinateSpace: .named("canvas"))
            .onChanged { value in
                model.selectedLayerID = layer.id
                if dragStart == nil { dragStart = (place, value.startLocation) }
                guard let start = dragStart else { return }
                var p = start.placement
                let dx = Double((value.location.x - start.point.x) / canvas.width)
                let dy = Double((value.location.y - start.point.y) / canvas.height)
                p.x = start.placement.x + (mirrored ? -dx : dx)
                p.y = start.placement.y + dy
                // The centre may leave the video, but not so far that the layer can't be grabbed again.
                let minVisiblePixels = Self.minVisiblePoints * Double(CamConstants.width) / Double(max(canvas.width, 1))
                model.setPlacement(layer.id, p.keepingVisible(aspect: layer.aspect, minVisiblePixels: minVisiblePixels))
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(_ place: Placement, center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
            .onChanged { value in
                let dist = hypot(value.location.x - center.x, value.location.y - center.y)
                let halfDiagonalPerWidth = 0.5 * (1 + 1 / layer.aspect / layer.aspect).squareRoot()
                var p = place
                p.width = min(max(Double(dist / canvas.width) / halfDiagonalPerWidth, 0.03), 1.5)
                model.setPlacement(layer.id, p)
            }
    }

    private func rotateGesture(_ place: Placement, center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
            .onChanged { value in
                // Clockwise angle from "up" as seen on screen. Stored rotation is clockwise on the unflipped output,
                // so it is the opposite when the preview is mirrored.
                let shown = atan2(value.location.x - center.x, -(value.location.y - center.y))
                var p = place
                p.rotation = mirrored ? -Double(shown) : Double(shown)
                model.setPlacement(layer.id, p)
            }
    }
}
