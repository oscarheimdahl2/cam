import SwiftUI

/// The menu-bar menu: quick switches for the things you change mid-meeting.
struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Camera: \(model.statusLine)")
        Divider()
        Toggle("Stickers", isOn: model.stickersEnabledBinding)
        Toggle("Blur background", isOn: model.sceneBinding(\.blurEnabled))
        Divider()
        Picker("Scene", selection: model.activeSceneBinding) {
            ForEach(model.config.scenes) { Text($0.name).tag($0.id) }
        }
        .pickerStyle(.inline)
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
