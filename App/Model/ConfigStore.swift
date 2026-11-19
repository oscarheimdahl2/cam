import Foundation

/// Loads and saves `CamConfig` as JSON. Saves are debounced: dragging a sticker changes the config on every
/// mouse move, and writing the file each time would be wasteful.
@MainActor
final class ConfigStore {
    let folder: URL
    let stickersDirectory: URL
    private let fileURL: URL
    private let delay: Duration
    private var latest: CamConfig?
    private var pendingSave: Task<Void, Never>?

    init(folder: URL, saveDelay: Duration = .milliseconds(400)) {
        self.folder = folder
        self.delay = saveDelay
        stickersDirectory = folder.appendingPathComponent("stickers", isDirectory: true)
        fileURL = folder.appendingPathComponent("config.json")
        try? FileManager.default.createDirectory(at: stickersDirectory, withIntermediateDirectories: true)
    }

    /// The saved config, or a fresh one if there isn't a usable file. Always has a valid active scene.
    func load() -> CamConfig {
        var config = CamConfig()
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(CamConfig.self, from: data), !decoded.scenes.isEmpty {
            config = decoded
        }
        if !config.scenes.contains(where: { $0.id == config.activeSceneID }) {
            config.activeSceneID = config.scenes[0].id
        }
        return config
    }

    /// Schedules a save; later calls within the delay replace earlier ones.
    func save(_ config: CamConfig) {
        latest = config
        pendingSave?.cancel()
        pendingSave = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Writes any pending change right now (used when the app quits).
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let config = latest, let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: fileURL, options: .atomic)
        latest = nil
    }
}
