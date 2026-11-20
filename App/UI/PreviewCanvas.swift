import SwiftUI
import UniformTypeIdentifiers

/// The live preview with the layer handles on top. It can be shown mirrored (like a mirror) or as other people see it;
/// the picture sent to apps is never mirrored.
struct PreviewCanvas: View {
    @ObservedObject var model: AppModel
    /// Observed separately so only the canvas redraws for each camera frame.
    @ObservedObject var preview: PreviewState
    @State private var dropTargeted = false
    @AppStorage("mirrorPreview") private var mirrorPreview = false
    private let aspect = CGFloat(CamConstants.width) / CGFloat(CamConstants.height)

    /// Room kept around the video for the handles of layers dragged to the edge (the rotate handle sits 28 pt
    /// above its layer). The whole pane is the interactive canvas, not just the video.
    private let handleMargin: CGFloat = 30

    var body: some View {
        GeometryReader { proxy in
            let size = fitted(CGSize(width: proxy.size.width - 2 * handleMargin,
                                     height: proxy.size.height - 2 * handleMargin))
            ZStack {
                // The video, clipped to its own frame.
                ZStack {
                    Rectangle().fill(Color.black)
                    if let image = preview.image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .scaleEffect(x: mirrorPreview ? -1 : 1, y: 1)
                    } else {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("Waiting for the camera…").foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipped()

                // The handles are NOT clipped, so they stay usable when a layer sits on the edge of the video.
                ZStack {
                    ForEach(model.scene.layers) { layer in
                        LayerHandle(model: model, layer: layer, face: preview.face, canvas: size, mirrored: mirrorPreview)
                    }
                }
                .frame(width: size.width, height: size.height)

                if dropTargeted {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                        .background(Color.accentColor.opacity(0.12))
                        .overlay(Label("Drop to add stickers", systemImage: "photo.badge.plus").font(.title3))
                        .frame(width: size.width, height: size.height)
                }
            }
            .frame(width: size.width, height: size.height)
            .coordinateSpace(name: "canvas")   // origin = the video's top-left corner
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { model.selectedLayerID = nil }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in model.importImage(from: url) } }
                    }
                }
                return true
            }
        }
    }

    private func fitted(_ available: CGSize) -> CGSize {
        let w = max(0, min(available.width, available.height * aspect))
        return CGSize(width: w, height: w / aspect)
    }
}
