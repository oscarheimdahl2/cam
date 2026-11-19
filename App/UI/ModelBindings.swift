import SwiftUI

/// Bindings the views use to read and write the model. Each one sets the value it is given (never "toggles"),
/// so a binding is always safe to call twice.
extension AppModel {
    func sceneBinding<Value>(_ keyPath: WritableKeyPath<CamScene, Value>) -> Binding<Value> {
        Binding(get: { self.scene[keyPath: keyPath] },
                set: { value in self.mutateScene { $0[keyPath: keyPath] = value } })
    }

    var stickersEnabledBinding: Binding<Bool> {
        Binding(get: { self.config.stickersEnabled }, set: { self.config.stickersEnabled = $0 })
    }

    var activeSceneBinding: Binding<UUID> {
        Binding(get: { self.scene.id }, set: { self.selectScene($0) })
    }

    func layerBinding<Value>(_ id: UUID, _ keyPath: WritableKeyPath<Layer, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { self.scene.layers.first { $0.id == id }?[keyPath: keyPath] ?? fallback },
                set: { value in self.updateLayer(id) { $0[keyPath: keyPath] = value } })
    }

    func followHeadBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { self.scene.layers.first { $0.id == id }?.followsHead ?? false },
                set: { self.setFollowHead(id, $0) })
    }

    func particlePresetBinding(_ id: UUID) -> Binding<ParticlePreset> {
        Binding(
            get: {
                if case .particles(let content)? = self.scene.layers.first(where: { $0.id == id })?.content { return content.preset }
                return .fireflies
            },
            set: { preset in
                self.updateLayer(id) {
                    if case .particles(var content) = $0.content {
                        content.preset = preset          // keeps the tint
                        $0.content = .particles(content)
                    }
                }
            })
    }

    /// "Custom color" on/off for an effect.
    func effectTintEnabledBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: {
                if case .particles(let content)? = self.scene.layers.first(where: { $0.id == id })?.content { return content.tint != nil }
                return false
            },
            set: { on in
                self.updateLayer(id) {
                    if case .particles(var content) = $0.content {
                        content.tint = on ? (content.tint ?? RGBAColor(r: 0.35, g: 0.7, b: 1)) : nil
                        $0.content = .particles(content)
                    }
                }
            })
    }

    func effectTintColorBinding(_ id: UUID) -> Binding<Color> {
        Binding(
            get: {
                if case .particles(let content)? = self.scene.layers.first(where: { $0.id == id })?.content, let tint = content.tint {
                    return tint.color
                }
                return .white
            },
            set: { color in
                self.updateLayer(id) {
                    if case .particles(var content) = $0.content,
                       let rgba = RGBAColor(color: color, keeping: content.tint ?? RGBAColor(r: 1, g: 1, b: 1)) {
                        content.tint = rgba
                        $0.content = .particles(content)
                    }
                }
            })
    }

    // Text layers: each field edits one property of the text and lets the model re-measure it.
    func textBinding<Value>(_ id: UUID, _ keyPath: WritableKeyPath<TextContent, Value>, fallback: Value) -> Binding<Value> {
        Binding(
            get: {
                if case .text(let text)? = self.scene.layers.first(where: { $0.id == id })?.content { return text[keyPath: keyPath] }
                return fallback
            },
            set: { value in
                if case .text(var text)? = self.scene.layers.first(where: { $0.id == id })?.content {
                    text[keyPath: keyPath] = value
                    self.setText(id, text)
                }
            })
    }

    func textColorBinding(_ id: UUID) -> Binding<Color> {
        let color = textBinding(id, \.color, fallback: RGBAColor(r: 1, g: 1, b: 1))
        return Binding(get: { color.wrappedValue.color },
                       set: { if let rgba = RGBAColor(color: $0, keeping: color.wrappedValue) { color.wrappedValue = rgba } })
    }
}

extension RGBAColor {
    /// The colour as SwiftUI shows it (opacity is edited separately, so it's not included).
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }

    /// A colour picked in a ColorPicker, keeping `other`'s opacity.
    init?(color: Color, keeping other: RGBAColor) {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent), a: other.a)
    }
}
