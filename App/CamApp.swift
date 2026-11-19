import SwiftUI

@main
struct CamApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("Cam", systemImage: "camera.filters") {
            MenuContent(model: model)
        }
        .menuBarExtraStyle(.menu)

        Window("Cam Editor", id: "editor") {
            EditorView(model: model)
        }
        .defaultSize(width: 1180, height: 700)
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.statusLine)
        Divider()
        Toggle("Stickers", isOn: Binding(get: { model.config.stickersEnabled }, set: { model.config.stickersEnabled = $0 }))
        Toggle("Party mode", isOn: Binding(get: { model.config.partyMode }, set: { model.config.partyMode = $0 }))
        Toggle("Blur background", isOn: Binding(get: { model.scene.blurEnabled }, set: { _ in model.toggleBlur() }))
        Divider()
        ForEach(model.config.scenes) { scene in
            Button {
                model.selectScene(scene.id)
            } label: {
                if scene.id == model.scene.id { Image(systemName: "checkmark") }
                Text(scene.name)
            }
        }
        Divider()
        Button("Open Editor…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "editor")
        }
        Button("Install / Update Virtual Camera") { model.installer.install() }
        Toggle("Launch at Login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
        Divider()
        Button("Quit Cam") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
