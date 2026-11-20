import Foundation
import SystemExtensions

final class ExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate, ObservableObject {
    @Published var status = "Virtual camera not installed"
    private enum Action { case install, uninstall }
    private var lastAction = Action.install

    func install() {
        lastAction = .install
        status = "Installing…"
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: CamConstants.extensionBundleID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func uninstall() {
        lastAction = .uninstall
        status = "Uninstalling…"
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: CamConstants.extensionBundleID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        status = "Approve the extension in System Settings → General → Login Items & Extensions → Camera Extensions"
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch (lastAction, result) {
        case (.install, .completed): status = "Virtual camera installed"
        case (.uninstall, .completed): status = "Virtual camera uninstalled"
        default: status = "Restart your Mac to finish this"
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        status = "\(lastAction == .install ? "Install" : "Uninstall") failed: \(error.localizedDescription)"
    }
}
