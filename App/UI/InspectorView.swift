import SwiftUI

/// The inspector: the layers in a list (a real `List`, so rows reorder by dragging with the system's own insertion
/// line) above the options of the selected layer. The divider between them can be dragged.
struct InspectorView: View {
    @ObservedObject var model: AppModel

    private var selectedLayer: Layer? {
        model.scene.layers.first { $0.id == model.selectedLayerID }
    }

    var body: some View {
        VSplitView {
            LayersPanel(model: model)
                .frame(minHeight: 170, idealHeight: 260)

            Form {
                if let layer = selectedLayer {
                    SelectedLayerSections(model: model, layer: layer)
                } else {
                    Section {
                        Text("Select a layer to change its options.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 150)
        }
    }
}

/// The layer list. The top of the list is the front.
private struct LayersPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Layers").font(.headline)
                Spacer()
                Toggle("Show", isOn: model.stickersEnabledBinding)
                    .toggleStyle(.checkbox)
                    .help("Show or hide all layers")
                Menu("Add") {
                    Button("Images…", systemImage: "photo") { model.pickImages() }
                    Button("Text", systemImage: "textformat") { model.addTextLayer() }
                    Menu("Effect", systemImage: "sparkles") {
                        ForEach(ParticlePreset.allCases) { preset in
                            Button(preset.title) { model.addEffectLayer(preset) }
                        }
                    }
                }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            List(selection: Binding(get: { model.selectedLayerID }, set: { model.selectedLayerID = $0 })) {
                ForEach(Array(model.scene.layers.enumerated().reversed()), id: \.element.id) { index, layer in
                    LayerRow(model: model, layer: layer, number: index + 1)
                        .tag(layer.id)
                        .contextMenu {
                            Button("Duplicate") { model.duplicateLayer(layer.id) }
                            Divider()
                            Button("Bring Forward") { model.moveLayer(layer.id, by: 1) }
                            Button("Send Backward") { model.moveLayer(layer.id, by: -1) }
                            Divider()
                            Button("Delete", role: .destructive) { model.deleteLayer(layer.id) }
                        }
                }
                .onMove { source, destination in
                    model.moveLayers(fromOffsets: source, toOffset: destination)
                }
            }
            .listStyle(.inset)
            .overlay {
                if model.scene.layers.isEmpty { EmptyLayers() }
            }
            .onDeleteCommand {
                if let id = model.selectedLayerID { model.deleteLayer(id) }
            }

            if !model.scene.layers.isEmpty {
                Text("Drag a row to reorder. Layers sit behind you unless they are set to be in front.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct EmptyLayers: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo.on.rectangle.angled").font(.title2).foregroundStyle(.secondary)
            Text("No layers yet").font(.headline)
            Text("Drop images onto the preview, or use Add").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

/// One row of the layer list: preview, name and what it does. Selection, highlight and drag-to-reorder come from the
/// `List` it sits in.
private struct LayerRow: View {
    @ObservedObject var model: AppModel
    let layer: Layer
    let number: Int

    private var title: String {
        switch layer.content {
        case .text(let text): return "“\(text.string)”"
        case .particles(let effect): return "\(effect.preset.title) effect"
        case .image: return "Sticker \(number)"
        }
    }

    private var summary: String {
        if layer.followsHead { return "Follows your head" }
        return layer.inFront ? "In front of you" : "Behind you"
    }

    var body: some View {
        HStack(spacing: 10) {
            LayerThumbnail(layer: layer, library: model.library)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if layer.party { Image(systemName: "sparkles").foregroundStyle(.secondary).help("Party mode") }
        }
        .padding(.vertical, 2)
    }
}

/// The options of the selected layer.
private struct SelectedLayerSections: View {
    @ObservedObject var model: AppModel
    let layer: Layer

    var body: some View {
        Section {
            switch layer.content {
            case .text:
                TextField("Text", text: model.textBinding(layer.id, \.string, fallback: ""))
                Toggle("Bold", isOn: model.textBinding(layer.id, \.bold, fallback: true))
                ColorPicker("Color", selection: model.textColorBinding(layer.id), supportsOpacity: false)
            case .particles(let effect):
                Picker("Effect", selection: model.particlePresetBinding(layer.id)) {
                    ForEach(ParticlePreset.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Custom color", isOn: model.effectTintEnabledBinding(layer.id))
                    .help("Recolors the whole effect, like a color filter")
                if effect.tint != nil {
                    ColorPicker("Color", selection: model.effectTintColorBinding(layer.id), supportsOpacity: false)
                }
                if effect.preset.isBurstOnly {
                    Button("Pop now", systemImage: "sparkles") { model.particles.burst(layer: layer.id) }
                        .help("Fires a burst right away (it also fires on its own every few seconds)")
                }
            case .image:
                EmptyView()
            }
            if !layer.isEffect {
                Toggle("Sticker look", isOn: model.layerBinding(layer.id, \.styled, fallback: false))
                    .help("White border, rounded corners and a soft shadow")
            }
            if layer.isSticker {
                Toggle("Party mode", isOn: model.layerBinding(layer.id, \.party, fallback: false))
                    .help("A slow rainbow tint, and a slow spin in a random direction unless it follows your head")
            }
            Toggle("Follow head", isOn: model.followHeadBinding(layer.id))
                .help("Moves, scales and tilts with your face. Position it by eye, then tick the box.")
            Toggle("In front of me", isOn: model.layerBinding(layer.id, \.inFront, fallback: false))
                .help("Draw over you instead of behind you")
        } header: {
            Text("Selected layer")
        } footer: {
            if layer.party { Text("Party mode adds a rainbow tint and, unless it follows your head, a slow spin. Turn it off to edit placement.") }
        }

        Section {
            Button("Delete Layer", role: .destructive) { model.deleteLayer(layer.id) }
        }
    }
}

struct LayerThumbnail: View {
    let layer: Layer
    let library: StickerLibrary

    var body: some View {
        Group {
            switch layer.content {
            case .image(let file):
                if let image = NSImage(contentsOf: library.url(for: file)) {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            case .text(let text):
                Text("Aa").font(.system(size: 16, weight: text.bold ? .heavy : .medium))
                    .foregroundStyle(text.color.color)
                    .padding(4)
                    .background(Color.gray.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            case .particles:
                Image(systemName: "sparkles").font(.system(size: 16))
                    .foregroundStyle(.yellow)
                    .padding(6)
                    .background(Color.gray.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .frame(width: 34, height: 34)
    }
}
