import SwiftUI

@main
struct CamApp: App {
    @StateObject private var model = AppModel()
    #if DEV_BUILD
    @Environment(\.openWindow) private var openWindow
    #endif

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
            // The dev build opens the editor by itself, so a rebuild (scripts/dev.sh) lands straight in it.
            .onAppear {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "editor")
            }
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
