import SwiftUI

/// The editor window: scenes in the sidebar, the live preview in the middle, settings in the inspector.
struct EditorView: View {
    @ObservedObject var model: AppModel
    @State private var showInspector = true
    /// Flip the preview like a mirror. Off by default: what you see is what other people see. The output is never flipped.
    @AppStorage("mirrorPreview") private var mirrorPreview = false

    var body: some View {
        NavigationSplitView {
            ScenesSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 260)
        } detail: {
            PreviewCanvas(model: model, preview: model.preview)
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .bottom, spacing: 0) { StatusFooter(model: model) }
                .inspector(isPresented: $showInspector) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
                }
        }
        .navigationTitle(model.scene.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Add Images", systemImage: "photo.badge.plus") { model.pickImages() }
                    .help("Add image layers (or drop images onto the preview)")
                Button("Add Text", systemImage: "textformat") { model.addTextLayer() }
                    .help("Add a text layer")
                Menu("Add Effect", systemImage: "sparkles") {
                    ForEach(ParticlePreset.allCases) { preset in
                        Button(preset.title) { model.addEffectLayer(preset) }
                    }
                }
                .help("Add a particle effect: snow, fireflies, confetti…")
                Toggle(isOn: $mirrorPreview) {
                    Label("Mirror Preview", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .help("Flip the preview like a mirror. Text reads backwards while it's on. What other people see is never flipped.")
                Button("Inspector", systemImage: "sidebar.right") { showInspector.toggle() }
                    .help("Show or hide the inspector")
            }
        }
        .onAppear { model.setEditorOpen(true) }
        .onDisappear { model.setEditorOpen(false) }
    }
}

/// One line under the preview: is the virtual camera installed, and is a meeting app using it.
struct StatusFooter: View {
    @ObservedObject var model: AppModel

    private var color: Color {
        if !model.virtualCameraInstalled { return .orange }
        return model.consumers > 0 ? .green : .secondary
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(model.statusLine)
            Spacer()
            if !model.virtualCameraInstalled {
                Button("Install…") { model.installer.install() }
                    .controlSize(.small)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
