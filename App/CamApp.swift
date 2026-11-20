import SwiftUI

@main
struct CamApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            // A template image: macOS tints it for light and dark menu bars.
            #if DEV_BUILD
            // The CamDev build says so in the menu bar, so it is never mistaken for the installed Cam.
            HStack(spacing: 3) {
                Image("MenuIcon")
                Text("DEV").font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(.red)
            #else
            Image("MenuIcon")
            #endif
        }
        .menuBarExtraStyle(.menu)

        Window("Cam Editor", id: "editor") {
            EditorView(model: model)
        }
        .defaultSize(width: 1180, height: 700)
    }
}
