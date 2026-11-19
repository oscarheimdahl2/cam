import AppKit
import ImageIO
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var config: CamConfig { didSet { configChanged() } }
    @Published var selectedStickerID: UUID?
    @Published var previewImage: CGImage?
    @Published var consumers: Int?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    let installer = ExtensionInstaller()
    private let link = VirtualCameraLink()
    private let pipeline: CameraPipeline
    private let folder: URL
    let stickersDir: URL
    private var editorOpen = false
    private var timer: Timer?

    init() {
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cam", isDirectory: true)
        stickersDir = folder.appendingPathComponent("stickers", isDirectory: true)
        try? FileManager.default.createDirectory(at: stickersDir, withIntermediateDirectories: true)
        pipeline = CameraPipeline(stickersDir: stickersDir, link: link)

        var loaded = CamConfig()
        if let data = try? Data(contentsOf: folder.appendingPathComponent("config.json")),
           let decoded = try? JSONDecoder().decode(CamConfig.self, from: data), !decoded.scenes.isEmpty {
            loaded = decoded
        }
        if loaded.activeSceneID == nil { loaded.activeSceneID = loaded.scenes[0].id }
        config = loaded
        pipeline.update(.init(scene: loaded.activeScene, stickersEnabled: loaded.stickersEnabled, partyMode: loaded.partyMode))

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        if link.deviceFound == false { installer.status = "Virtual camera not installed" }
        else { installer.status = "Virtual camera installed" }
    }

    // MARK: Status

    var statusLine: String {
        guard link.deviceFound else { return installer.status }
        let n = consumers ?? 0
        return n > 0 ? "Camera: live in a meeting app" : "Camera: idle (ready for Teams)"
    }

    private func poll() {
        consumers = link.consumerCount()
        refreshDemand()
    }

    func setEditorOpen(_ open: Bool) {
        editorOpen = open
        // Menu-bar apps are hidden from Cmd+Tab. Become a regular app while the editor is open.
        NSApp.setActivationPolicy(open ? .regular : .accessory)
        if open { NSApp.activate(ignoringOtherApps: true) }
        refreshDemand()
    }

    private func refreshDemand() {
        let live = (consumers ?? 0) > 0
        pipeline.setDemand(virtualCamera: live,
                           preview: editorOpen ? { [weak self] image in
                               Task { @MainActor in self?.previewImage = image }
                           } : nil)
    }

    // MARK: Persistence

    private func configChanged() {
        pipeline.update(.init(scene: config.activeScene, stickersEnabled: config.stickersEnabled, partyMode: config.partyMode))
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: folder.appendingPathComponent("config.json"), options: .atomic)
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { NSLog("Launch at login failed: \(error)") }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Scenes

    var scene: CamScene { config.activeScene }

    func selectScene(_ id: UUID) {
        config.activeSceneID = id
        selectedStickerID = nil
    }

    func addScene() {
        let scene = CamScene(name: "Scene \(config.scenes.count + 1)")
        config.scenes.append(scene)
        selectScene(scene.id)
    }

    func deleteScene(_ id: UUID) {
        guard config.scenes.count > 1 else { return }
        config.scenes.removeAll { $0.id == id }
        if config.activeSceneID == id { selectScene(config.scenes[0].id) }
    }

    func mutateScene(_ change: (inout CamScene) -> Void) {
        var copy = config
        change(&copy.scenes[copy.activeIndex])
        config = copy
    }

    func toggleBlur() { mutateScene { $0.blurEnabled.toggle() } }

    // MARK: Stickers

    func importSticker(from url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1024,
              ] as CFDictionary) else { return }
        let name = UUID().uuidString + ".png"
        guard let destination = CGImageDestinationCreateWithURL(
            stickersDir.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        pipeline.stickersChanged()
        let sticker = Sticker(file: name, aspect: Double(image.width) / Double(image.height))
        mutateScene { $0.stickers.append(sticker) }
        selectedStickerID = sticker.id
    }

    func pickStickers() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(importSticker)
    }

    func updateSticker(_ id: UUID, _ change: (inout Sticker) -> Void) {
        mutateScene { scene in
            if let i = scene.stickers.firstIndex(where: { $0.id == id }) { change(&scene.stickers[i]) }
        }
    }

    func deleteSticker(_ id: UUID) {
        mutateScene { $0.stickers.removeAll { $0.id == id } }
        if selectedStickerID == id { selectedStickerID = nil }
    }

    /// direction +1 brings the sticker towards the front.
    func moveSticker(_ id: UUID, by direction: Int) {
        mutateScene { scene in
            guard let i = scene.stickers.firstIndex(where: { $0.id == id }) else { return }
            let j = i + direction
            guard scene.stickers.indices.contains(j) else { return }
            scene.stickers.swapAt(i, j)
        }
    }
}
