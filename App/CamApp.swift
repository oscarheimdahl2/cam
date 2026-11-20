import SwiftUI

@main
struct CamApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("Cam", image: "MenuIcon") {   // a template image: macOS tints it for light and dark menu bars
            MenuContent(model: model)
        }
        .menuBarExtraStyle(.menu)

        Window("Cam Editor", id: "editor") {
            EditorView(model: model)
        }
        .defaultSize(width: 1180, height: 700)
    }
}
