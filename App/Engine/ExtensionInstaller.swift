import AppKit
import Foundation
import SystemExtensions

/// Installs and removes Cam's virtual camera (a system extension). Problems are shown to the user, not just stored:
/// a failed install used to leave no trace at all.
final class ExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate, ObservableObject {
    @Published var status = "Virtual camera not installed"
    /// Set while the last install or uninstall has a problem the user should know about; cleared on the next attempt.
    @Published private(set) var problem: String?
    private enum Action { case install, uninstall }
    private var lastAction = Action.install

    /// macOS only installs a system extension for an app that lives in /Applications. An app opened straight from a
    /// disk image or the Downloads folder is run from a hidden, randomised read-only copy ("translocated"), which fails
    /// the same check, so this looks at where the app is really running from.
    static var isRunningFromApplications: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }

    func install() {
        lastAction = .install
        problem = nil
        guard Self.isRunningFromApplications else {
            report("Move Cam to your Applications folder first, then open it from there and try again.",
                   detail: "macOS only installs the virtual camera for an app that lives in the Applications folder. An app opened straight from the disk image or the Downloads folder doesn't count, even if it looks like it is in the right place.")
            return
        }
        status = "Installing…"
        CamLog.app.notice("installer: asking macOS to install the virtual camera (from \(Bundle.main.bundlePath, privacy: .public))")
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: CamConstants.extensionBundleID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func uninstall() {
        lastAction = .uninstall
        problem = nil
        status = "Uninstalling…"
        CamLog.app.notice("installer: asking macOS to uninstall the virtual camera")
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: CamConstants.extensionBundleID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        CamLog.app.notice("installer: replacing version \(existing.bundleVersion, privacy: .public) with \(ext.bundleVersion, privacy: .public)")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        CamLog.app.notice("installer: waiting for you to approve it in System Settings")
        status = "Approve the extension in System Settings → General → Login Items & Extensions → Camera Extensions"
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        CamLog.app.notice("installer: finished, result \(result.rawValue, privacy: .public) (0 = completed, 1 = needs a restart)")
        problem = nil
        switch (lastAction, result) {
        case (.install, .completed):
            status = "Virtual camera installed"
            offerRestart()
        case (.uninstall, .completed): status = "Virtual camera uninstalled"
        default: status = "Restart your Mac to finish this"
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let nsError = error as NSError
        let verb = lastAction == .install ? "install" : "uninstall"
        CamLog.app.error("installer: failed, \(nsError.domain, privacy: .public) code \(nsError.code, privacy: .public): \(error.localizedDescription, privacy: .public)")
        if nsError.domain == OSSystemExtensionErrorDomain,
           OSSystemExtensionError.Code(rawValue: nsError.code) == .unsupportedParentBundleLocation {
            report("Move Cam to your Applications folder first, then open it from there and try again.",
                   detail: "macOS refused to \(verb) the virtual camera because Cam isn't running from the Applications folder.")
        } else {
            report("Couldn't \(verb) the virtual camera: \(error.localizedDescription)",
                   detail: "\(error.localizedDescription)\n\n(error \(nsError.domain) \(nsError.code))")
        }
    }

    // MARK: Restarting after an install

    /// A Cam that was already running when its camera appeared never sees that camera: macOS only tells a process about
    /// devices that existed when it started. It could not tell when Photo Booth or Teams starts reading, so the camera
    /// would show "Cam isn't running". Starting Cam again fixes it, so it's offered right after a successful install.
    private func offerRestart() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "The virtual camera is installed"
            alert.informativeText = "Cam needs to restart once to connect to it. Your scenes and stickers are kept."
            alert.addButton(withTitle: "Restart Cam")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn { Self.relaunch() }
        }
    }

    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: Showing problems

    private func report(_ message: String, detail: String) {
        status = message
        problem = message
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = message
            alert.informativeText = detail
            alert.runModal()
        }
    }
}
