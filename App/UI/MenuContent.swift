import SwiftUI

/// The menu-bar menu: quick switches for the things you change mid-meeting.
struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Camera: \(model.statusLine)")
        Divider()
        Toggle("Stickers", isOn: model.stickersEnabledBinding)
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
        Button("Uninstall Virtual Camera…") { confirmUninstall() }
        Toggle("Launch at Login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
        Divider()
        Button("About Cam") { AboutCredits.show() }
        Button("Quit Cam") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func confirmUninstall() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Uninstall the Cam virtual camera?"
        alert.informativeText = "Cam will disappear from the camera list in Teams, Zoom and other apps. Your scenes and stickers are kept, and you can install it again at any time."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { model.installer.uninstall() }
    }
}
