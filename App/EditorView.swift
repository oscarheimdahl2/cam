import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            ScenesSidebar(model: model)
                .frame(width: 190)
            Divider()
            VStack(spacing: 0) {
                PreviewCanvas(model: model)
                    .padding(16)
                Text(model.installer.status)
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            Inspector(model: model)
                .frame(width: 270)
        }
        .background(WindowFloater())
        .onAppear { model.setEditorOpen(true) }
        .onDisappear { model.setEditorOpen(false) }
    }
}

/// Keeps the editor window above other apps' windows. (`.windowLevel` needs macOS 15, we target 14.)
struct WindowFloater: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.level = .floating }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { view.window?.level = .floating }
    }
}

// MARK: - Scenes

struct ScenesSidebar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Scenes").font(.headline)
                Spacer()
                Button { model.addScene() } label: { Image(systemName: "plus") }.buttonStyle(.borderless)
            }
            List {
                ForEach(model.config.scenes) { scene in
                    HStack {
                        if model.scene.id == scene.id {
                            TextField("Name", text: Binding(
                                get: { scene.name },
                                set: { name in model.mutateScene { $0.name = name } }))
                                .textFieldStyle(.plain)
                        } else {
                            Text(scene.name)
                        }
                        Spacer()
                        if model.scene.id == scene.id && model.config.scenes.count > 1 {
                            Button { model.deleteScene(scene.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectScene(scene.id) }
                    .listRowBackground(model.scene.id == scene.id ? Color.accentColor.opacity(0.2) : Color.clear)
                }
            }
            .listStyle(.plain)
        }
        .padding(12)
    }
}

// MARK: - Preview with editing overlay

struct PreviewCanvas: View {
    @ObservedObject var model: AppModel
    private let aspect = CGFloat(CamConstants.width) / CGFloat(CamConstants.height)

    var body: some View {
        GeometryReader { proxy in
            let size = fitted(proxy.size)
            ZStack {
                Rectangle().fill(Color.black)
                if let image = model.previewImage {
                    // Mirrored like a mirror; the output sent to Teams is not mirrored.
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaleEffect(x: -1, y: 1)
                } else {
                    Text("Waiting for camera…").foregroundStyle(.secondary)
                }
                ForEach(model.scene.stickers) { sticker in
                    StickerHandle(model: model, sticker: sticker, canvas: size)
                }
            }
            .frame(width: size.width, height: size.height)
            .coordinateSpace(name: "canvas")
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { model.selectedStickerID = nil }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in model.importSticker(from: url) } }
                    }
                }
                return true
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func fitted(_ available: CGSize) -> CGSize {
        let w = min(available.width, available.height * aspect)
        return CGSize(width: w, height: w / aspect)
    }
}

struct StickerHandle: View {
    @ObservedObject var model: AppModel
    let sticker: Sticker
    let canvas: CGSize
    @State private var dragStart: (x: Double, y: Double, point: CGPoint)?

    private var selected: Bool { model.selectedStickerID == sticker.id }
    private var boxWidth: CGFloat { CGFloat(sticker.width) * canvas.width }
    private var boxHeight: CGFloat { boxWidth / CGFloat(sticker.aspect) }
    /// Centre in canvas space (x is mirrored on screen).
    private var center: CGPoint {
        CGPoint(x: (1 - sticker.x) * canvas.width, y: sticker.y * canvas.height)
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .overlay(Rectangle().stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2))
                .frame(width: boxWidth, height: boxHeight)
                .gesture(moveGesture)
            if selected {
                handle(systemImage: "arrow.up.left.and.arrow.down.right")
                    .position(x: boxWidth / 2 + 0, y: boxHeight / 2)
                    .gesture(resizeGesture)
                handle(systemImage: "arrow.clockwise")
                    .position(x: boxWidth / 2, y: -18)
                    .gesture(rotateGesture)
            }
        }
        .frame(width: boxWidth, height: boxHeight)
        .rotationEffect(.radians(-sticker.rotation))
        .position(center)
    }

    private func handle(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(Circle().fill(Color.accentColor))
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
            .onChanged { value in
                model.selectedStickerID = sticker.id
                if dragStart == nil { dragStart = (sticker.x, sticker.y, value.location) }
                guard let start = dragStart else { return }
                let dx = Double((value.location.x - start.point.x) / canvas.width)
                let dy = Double((value.location.y - start.point.y) / canvas.height)
                model.updateSticker(sticker.id) {
                    $0.x = min(max(start.x - dx, 0), 1)
                    $0.y = min(max(start.y + dy, 0), 1)
                }
            }
            .onEnded { _ in dragStart = nil }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
            .onChanged { value in
                let dist = hypot(value.location.x - center.x, value.location.y - center.y)
                let halfDiagonalPerWidth = 0.5 * (1 + 1 / sticker.aspect / sticker.aspect).squareRoot()
                let width = Double(dist / canvas.width) / halfDiagonalPerWidth
                model.updateSticker(sticker.id) { $0.width = min(max(width, 0.03), 1.5) }
            }
    }

    private var rotateGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
            .onChanged { value in
                // Clockwise angle from "up" as seen on the (mirrored) preview; stored rotation is the opposite.
                let shown = atan2(value.location.x - center.x, -(value.location.y - center.y))
                model.updateSticker(sticker.id) { $0.rotation = -Double(shown) }
            }
    }
}

// MARK: - Inspector

struct Inspector: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Background").font(.headline)
            Toggle("Blur", isOn: Binding(get: { model.scene.blurEnabled }, set: { _ in model.toggleBlur() }))
            Slider(value: Binding(get: { model.scene.blurRadius },
                                  set: { v in model.mutateScene { $0.blurRadius = v } }), in: 5...60)
                .disabled(!model.scene.blurEnabled)
            Toggle("Stickers visible", isOn: Binding(get: { model.config.stickersEnabled },
                                                    set: { model.config.stickersEnabled = $0 }))
            Toggle("Party mode", isOn: Binding(get: { model.config.partyMode }, set: { model.config.partyMode = $0 }))
            Text("Spinning, rainbow stickers and golden lights. Turn it off to edit placement.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("Stickers").font(.headline)
                Spacer()
                Button("Add…") { model.pickStickers() }
            }
            Text("Front of the list is the top. Stickers sit behind you.")
                .font(.caption).foregroundStyle(.secondary)
            List(selection: Binding(get: { model.selectedStickerID }, set: { model.selectedStickerID = $0 })) {
                ForEach(Array(model.scene.stickers.reversed())) { sticker in
                    StickerRow(model: model, sticker: sticker)
                        .tag(sticker.id)
                }
            }
            .listStyle(.plain)
            .onDeleteCommand {
                if let id = model.selectedStickerID { model.deleteSticker(id) }
            }
        }
        .padding(12)
    }
}

struct StickerRow: View {
    @ObservedObject var model: AppModel
    let sticker: Sticker

    private var styledBinding: Binding<Bool> {
        Binding(
            get: { sticker.styled },
            set: { on in model.updateSticker(sticker.id) { $0.styled = on } })
    }

    var body: some View {
        HStack {
            AsyncStickerThumb(url: model.stickersDir.appendingPathComponent(sticker.file))
            Spacer()
            Toggle("Sticker look", isOn: styledBinding)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("Sticker look: white border, rounded corners, soft shadow")
            Button { model.moveSticker(sticker.id, by: 1) } label: { Image(systemName: "arrow.up") }
            Button { model.moveSticker(sticker.id, by: -1) } label: { Image(systemName: "arrow.down") }
            Button { model.deleteSticker(sticker.id) } label: { Image(systemName: "trash") }
        }
        .buttonStyle(.borderless)
    }
}

struct AsyncStickerThumb: View {
    let url: URL
    var body: some View {
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFit().frame(width: 44, height: 44)
        } else {
            Image(systemName: "photo").frame(width: 44, height: 44)
        }
    }
}
