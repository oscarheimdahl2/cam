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
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 150)
        }
    }
}

private func addLabel(_ title: String, _ systemImage: String) -> some View {
    VStack(spacing: 4) {
        Image(systemName: systemImage).font(.system(size: 17, weight: .semibold))
        Text(title).font(.system(size: 11, weight: .semibold, design: .rounded))
    }
    .frame(maxWidth: .infinity)
}

/// A colourful rounded tile that lifts on hover and squishes when pressed.
private struct AddTileStyle: ButtonStyle {
    let colors: [Color]
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 46)   // fixed, so the Effect menu comes out the same size as the two buttons
            .background(
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(hovering ? 1 : 0.88),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: colors[0].opacity(hovering ? 0.5 : 0.25), radius: hovering ? 8 : 3, y: 2)
            .scaleEffect(configuration.isPressed ? 0.93 : (hovering ? 1.05 : 1))
            .rotationEffect(.degrees(hovering && !configuration.isPressed ? -2 : 0))
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hovering)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
            .onHover { hovering = $0 }
            .contentShape(Rectangle())
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
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            // The three ways to add a layer, side by side with equal weight.
            HStack(spacing: 6) {
                Button { model.pickImages() } label: { addLabel("Image", "photo.fill.on.rectangle.fill") }
                    .buttonStyle(AddTileStyle(colors: [.pink, .orange]))
                    .help("Add image layers (or drop images onto the preview)")
                Button { model.addTextLayer() } label: { addLabel("Text", "textformat") }
                    .buttonStyle(AddTileStyle(colors: [.blue, .cyan]))
                    .help("Add a text layer")
                Menu {
                    ForEach(ParticlePreset.allCases) { preset in
                        Button(preset.title) { model.addEffectLayer(preset) }
                    }
                } label: { addLabel("Effect", "sparkles") }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(AddTileStyle(colors: [.purple, .indigo]))
                    .help("Add a particle effect: snow, fireflies, confetti…")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            List(selection: Binding(get: { model.selectedLayerID }, set: { model.selectedLayerID = $0 })) {
                ForEach(Array(model.scene.layers.enumerated().reversed()), id: \.element.id) { index, layer in
                    LayerRow(model: model, layer: layer, number: index + 1)
                        .tag(layer.id)
                        .contextMenu {
                            Button(layer.enabled ? "Disable" : "Enable") { model.updateLayer(layer.id) { $0.enabled.toggle() } }
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
        if case .hand(let target) = layer.trackTarget {
            switch target.side {
            case .either: return "Follows your \(target.hand) hand"
            case .palm: return "On the palm of your \(target.hand) hand"
            case .back: return "On the back of your \(target.hand) hand"
            }
        }
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
            Button {
                model.updateLayer(layer.id) { $0.enabled.toggle() }
            } label: {
                Image(systemName: layer.enabled ? "eye" : "eye.slash")
                    .foregroundStyle(layer.enabled ? Color.secondary : Color.primary)
            }
            .buttonStyle(.borderless)
            .help(layer.enabled ? "Hide this layer" : "Show this layer")
            if layer.party { Image(systemName: "sparkles").foregroundStyle(.secondary).help("Party mode") }
        }
        .padding(.vertical, 2)
        .opacity(layer.enabled ? 1 : 0.45)
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
                    ColorPicker("Color", selection: model.effectTintColorBinding(layer.id), supportsOpacity: true)
                }
                if effect.preset.isBurstOnly {
                    Button("Pop now", systemImage: "sparkles") { model.particles.burst(layer: layer.id) }
                        .help("Fires a burst right away (it also fires on its own every few seconds)")
                }
            case .image:
                EmptyView()
            }
            if !layer.isEffect {
                Toggle("Border", isOn: model.layerBinding(layer.id, \.styled, fallback: false))
                    .help("White border, rounded corners and a soft shadow")
            }
            if layer.isSticker {
                Toggle("Party mode", isOn: model.layerBinding(layer.id, \.party, fallback: false))
                    .help("A slow rainbow tint")
            }
            if !layer.isEffect {
                SpinSlider(value: model.layerBinding(layer.id, \.spin, fallback: 0))
            }
            Picker("Follow", selection: model.followBinding(layer.id)) {
                ForEach(FollowChoice.allCases, id: \.self) { Text($0.title) }
            }
            .help("Moves, scales and tilts with your head or hand. Position it by eye, then pick one.")
            if case .hand = layer.trackTarget {
                Picker("Side", selection: model.handSideBinding(layer.id)) {
                    Text("Whole hand").tag(HandSide.either)
                    Text("Palm").tag(HandSide.palm)
                    Text("Back of hand").tag(HandSide.back)
                }
                .help("Palm and Back of hand are only drawn while that whole side is in view and facing the camera")
            }
            Toggle("In front of me", isOn: model.layerBinding(layer.id, \.inFront, fallback: false))
                .help("Draw over you instead of behind you")
        } header: {
            Text("Selected layer")
        } footer: {
            if layer.party { Text("Party mode adds a rainbow tint. Turn it off to edit placement.") }
        }

        Section {
            Button("Delete Layer", role: .destructive) { model.deleteLayer(layer.id) }
        }
    }
}

/// Spin speed: drag right for clockwise, left for counter-clockwise. It snaps to the middle, which stops the spin.
private struct SpinSlider: View {
    @Binding var value: Double

    var body: some View {
        let snapped = Binding(get: { value },
                              set: { value = abs($0) < Layer.maxSpin * 0.06 ? 0 : $0 })
        LabeledContent("Spin") {
            HStack(spacing: 6) {
                Image(systemName: "arrow.counterclockwise").foregroundStyle(.secondary)
                Slider(value: snapped, in: -Layer.maxSpin...Layer.maxSpin)
                Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
            }
        }
        .help("Drag left or right to spin in either direction. The middle stops it.")
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

/// The choices in the "Follow" menu: nothing, or exactly one of the head, the right hand and the left hand.
enum FollowChoice: CaseIterable {
    case none, head, rightHand, leftHand

    init(_ target: TrackTarget?) {
        switch target {
        case nil: self = .none
        case .head?: self = .head
        case .hand(let t)?: self = t.hand == .right ? .rightHand : .leftHand
        }
    }

    var title: String {
        switch self {
        case .none: return "Nothing"
        case .head: return "Head"
        case .rightHand: return "Right hand"
        case .leftHand: return "Left hand"
        }
    }

    func target(side: HandSide) -> TrackTarget? {
        switch self {
        case .none: return nil
        case .head: return .head
        case .rightHand: return .hand(HandTarget(hand: .right, side: side))
        case .leftHand: return .hand(HandTarget(hand: .left, side: side))
        }
    }
}
