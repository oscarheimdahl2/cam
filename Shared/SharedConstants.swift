import Foundation
import os

enum CamConstants {
    static let deviceName = "Cam"
    static let deviceUUID = UUID(uuidString: "7B1E2C1A-5D0B-4C58-9A57-3E9B1E0C6A01")!
    static let sourceStreamUUID = UUID(uuidString: "7B1E2C1A-5D0B-4C58-9A57-3E9B1E0C6A02")!
    static let sinkStreamUUID = UUID(uuidString: "7B1E2C1A-5D0B-4C58-9A57-3E9B1E0C6A03")!
    static let width: Int32 = 1920
    static let height: Int32 = 1080
    static let fps: Int32 = 30
    /// Custom device property the extension updates with the number of active consumers (e.g. Teams).
    static let consumersProperty = "4cc_cons_glob_0000"
    static let extensionBundleID = "com.oscarheimdahl.cam.extension"
}

/// Logging for the virtual camera, readable with:
/// `log show --last 5m --info --predicate 'subsystem == "com.oscarheimdahl.cam"'`
enum CamLog {
    static let ext = Logger(subsystem: "com.oscarheimdahl.cam", category: "extension")
    static let app = Logger(subsystem: "com.oscarheimdahl.cam", category: "app")
}
