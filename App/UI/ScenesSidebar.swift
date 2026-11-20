import SwiftUI

/// The scene list: click to switch, double-click or use the context menu to rename.
struct ScenesSidebar: View {
    @ObservedObject var model: AppModel
    @State private var renamingID: UUID?
    @FocusState private var renameFocused: Bool
    @State private var iconPickerID: UUID?

    var body: some View {
        List(selection: Binding(get: { model.scene.id as UUID? }, set: { if let id = $0 { model.selectScene(id) } })) {
            ForEach(model.config.scenes) { scene in
                row(scene)
                    .tag(scene.id)
                    .contextMenu {
                        Button("Rename") { startRenaming(scene.id) }
                        Button("Change Icon…") { iconPickerID = scene.id }
                        Button("Duplicate") { model.duplicateScene(scene.id) }
                        Divider()
                        Button("Delete", role: .destructive) { model.deleteScene(scene.id) }
                            .disabled(model.config.scenes.count < 2)
                    }
            }
            .onMove { model.moveScenes(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Button { model.addScene() } label: { Label("New Scene", systemImage: "plus") }
                Button { model.chooseDataFolder() } label: { Label("Data Folder…", systemImage: "folder") }
                    .help(model.dataFolder.path)
                if model.dataFolder.standardizedFileURL != AppModel.standardFolder.standardizedFileURL {
                    Button("Use Default Data Folder") { model.resetDataFolder() }
                        .font(.caption)
                }
            }
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
    }

    @ViewBuilder
    private func row(_ scene: CamScene) -> some View {
        if renamingID == scene.id {
            TextField("Name", text: Binding(get: { scene.name }, set: { model.renameScene(scene.id, to: $0) }))
                .focused($renameFocused)
                .onSubmit { renamingID = nil }
                .onExitCommand { renamingID = nil }
        } else {
            Label(scene.name, systemImage: scene.icon)
                .simultaneousGesture(TapGesture(count: 2).onEnded { startRenaming(scene.id) })
                .popover(isPresented: Binding(get: { iconPickerID == scene.id }, set: { if !$0 { iconPickerID = nil } }),
                         arrowEdge: .trailing) {
                    IconPicker(selected: scene.icon) { model.setSceneIcon(scene.id, to: $0); iconPickerID = nil }
                }
        }
    }

    private func startRenaming(_ id: UUID) {
        renamingID = id
        DispatchQueue.main.async { renameFocused = true }
    }
}

/// A grid of symbols to pick a scene's icon from.
private struct IconPicker: View {
    let selected: String
    let onPick: (String) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 6), spacing: 6) {
            ForEach(SceneIcon.choices, id: \.self) { name in
                Button { onPick(name) } label: {
                    Image(systemName: name)
                        .font(.system(size: 16))
                        .frame(width: 34, height: 34)
                        .background(name == selected ? Color.accentColor.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(name)
            }
        }
        .padding(12)
    }
}
