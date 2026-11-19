import SwiftUI

/// The scene list: click to switch, double-click or use the context menu to rename.
struct ScenesSidebar: View {
    @ObservedObject var model: AppModel
    @State private var renamingID: UUID?
    @FocusState private var renameFocused: Bool

    var body: some View {
        List(selection: Binding(get: { model.scene.id as UUID? }, set: { if let id = $0 { model.selectScene(id) } })) {
            ForEach(model.config.scenes) { scene in
                row(scene)
                    .tag(scene.id)
                    .contextMenu {
                        Button("Rename") { startRenaming(scene.id) }
                        Button("Duplicate") { model.duplicateScene(scene.id) }
                        Divider()
                        Button("Delete", role: .destructive) { model.deleteScene(scene.id) }
                            .disabled(model.config.scenes.count < 2)
                    }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button { model.addScene() } label: { Label("New Scene", systemImage: "plus") }
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
            Label(scene.name, systemImage: scene.layers.contains { $0.party } ? "sparkles" : "photo.on.rectangle")
                .simultaneousGesture(TapGesture(count: 2).onEnded { startRenaming(scene.id) })
        }
    }

    private func startRenaming(_ id: UUID) {
        renamingID = id
        DispatchQueue.main.async { renameFocused = true }
    }
}
