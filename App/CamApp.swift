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
