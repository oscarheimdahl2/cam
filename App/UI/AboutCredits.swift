import AppKit

/// The text under the app name in the standard About window: what Cam is, what it does with your data, and the
/// licence notice for the third-party library it includes (bundled from THIRD_PARTY_LICENSES.md).
enum AboutCredits {
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: text])
    }

    private static var text: NSAttributedString {
        let intro = """
        Puts stickers, text and effects around you on your camera picture, and sends the result to any app that uses a camera \
        as a virtual camera.

        Cam's own code makes no network connections. Your scenes and stickers stay on this Mac, in \
        ~/Library/Application Support/Cam.


        """
        let notice = Bundle.main.url(forResource: "THIRD_PARTY_LICENSES", withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "Third-party licences: see THIRD_PARTY_LICENSES.md in the source repository."
        return NSAttributedString(string: intro + notice, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
        ])
    }
}
