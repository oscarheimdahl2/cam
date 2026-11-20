import AppKit
import AVFoundation
import Combine
import ServiceManagement

/// Coordinates the app: owns the config (scenes and stickers), starts and stops the camera pipeline, and exposes
/// the editing operations the UI calls. Storage, image import and the live preview are delegated to
/// `ConfigStore`, `StickerLibrary` and `PreviewState`.
@MainActor
final class AppModel: ObservableObject {
    @Published var config: CamConfig { didSet { configChanged() } }
    @Published var selectedLayerID: UUID?
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Whether the virtual camera is installed, and how many apps are reading it. Refreshed once a second.
    @Published private(set) var virtualCameraInstalled = false
    @Published private(set) var consumers = 0
    /// The cameras Cam can read, and the one picked (`nil`: the first one found). Remembered between launches.
    @Published private(set) var cameras: [CameraChoice] = []
    @Published private(set) var selectedCameraID: String? = UserDefaults.standard.string(forKey: "cameraID")

    let preview = PreviewState()
    let installer = ExtensionInstaller()
    let library: StickerLibrary

    private let store: ConfigStore
    private let link = VirtualCameraLink()
    private let pipeline: CameraPipeline
    let particles: ParticleHost
    /// The frames the particle host produces (the compositor reads them); exposed for previews and tests.
    let particleFramesForTesting: ParticleFrames
    private let cameraEnabled: Bool
    private var editorOpen = false
    /// The scene being cross-faded away from after a scene switch.
    private var fadingOut: CamScene?
    private var fadeTask: Task<Void, Never>?
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private let discovery = CameraPipeline.makeDiscovery()
    private var camerasObservation: NSKeyValueObservation?

    private nonisolated static let folderKey = "dataFolder"

    nonisolated static var standardFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cam", isDirectory: true)
    }

    /// The folder the user picked in "Data Folder…", or the standard one in Application Support.
    nonisolated static var defaultFolder: URL {
        if let path = UserDefaults.standard.string(forKey: folderKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return standardFolder
    }

    var dataFolder: URL { store.folder }

    /// Asks for a new folder for the config and stickers, copies the current ones over (unless the folder already
    /// holds a Cam config, which is then used as it is) and relaunches so every part of the app uses the new place.
    func chooseDataFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose the folder for your scenes and stickers"
        panel.prompt = "Use Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = dataFolder
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        moveData(to: url)
    }

    func resetDataFolder() { moveData(to: Self.standardFolder) }

    private func moveData(to target: URL) {
        let source = store.folder
        guard target.standardizedFileURL != source.standardizedFileURL else { return }
        store.flush()
        let fm = FileManager.default
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: target.appendingPathComponent("config.json").path) {
            for name in ["config.json", "stickers"] {
                let from = source.appendingPathComponent(name), to = target.appendingPathComponent(name)
                guard fm.fileExists(atPath: from.path) else { continue }
                try? fm.removeItem(at: to)   // an empty stickers folder the store created
                do { try fm.copyItem(at: from, to: to) } catch {
                    CamLog.app.error("copying \(name, privacy: .public) to the new folder failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        UserDefaults.standard.set(target.path, forKey: Self.folderKey)
        relaunch()
    }

    private func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.7; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// `folder` is where the config and sticker images live. `cameraEnabled: false` never touches the camera
    /// (for tests and previews).
    init(folder: URL = AppModel.defaultFolder, cameraEnabled: Bool = true) {
        store = ConfigStore(folder: folder)
        library = StickerLibrary(directory: store.stickersDirectory)
        let particleFrames = ParticleFrames()
        particleFramesForTesting = particleFrames
        particles = ParticleHost(frames: particleFrames)
        pipeline = CameraPipeline(stickersDir: store.stickersDirectory, link: link, particleFrames: particleFrames)
        self.cameraEnabled = cameraEnabled
        config = store.load()
        config.stickersEnabled = true   // there is no switch for this any more, so a config saved with it off must not hide layers for good
        pushSettingsToPipeline()
        syncParticles()

        // The installer is a separate object; forward its changes so views showing the status refresh.
        installer.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.store.flush() } }
            .store(in: &cancellables)

        if cameraEnabled {
            pipeline.setCamera(id: selectedCameraID)
            camerasObservation = discovery.observe(\.devices, options: [.initial, .new]) { [weak self] discovery, _ in
                let found = CameraPipeline.realCameras(in: discovery.devices).map { CameraChoice(id: $0.uniqueID, name: $0.localizedName) }
                Task { @MainActor in self?.cameras = found }
            }
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
            poll()
        }
    }

    // MARK: Status

    var statusLine: String {
        if let problem = installer.problem { return problem }   // a failed install must not be hidden by an old camera
        guard virtualCameraInstalled else { return installer.status }
        return consumers > 0 ? "In use by an app" : "Ready to use in any app"
    }

    private func poll() {
        let installed = link.deviceFound
        if installed != virtualCameraInstalled {
            virtualCameraInstalled = installed
            CamLog.app.notice("virtual camera device found: \(installed, privacy: .public)")
            if !installed { pipeline.virtualCameraLost() }
        }
        let reading = link.consumerCount()
        let count = reading ?? 0
        if count != consumers {
            consumers = count
            CamLog.app.notice("apps reading the virtual camera: \(count, privacy: .public) (property readable: \(reading != nil, privacy: .public))")
        }
        refreshDemand()
    }

    // MARK: Camera

    func setEditorOpen(_ open: Bool) {
        editorOpen = open
        // Menu-bar apps are hidden from Cmd+Tab. Become a regular app while the editor is open.
        NSApp.setActivationPolicy(open ? .regular : .accessory)
        if open { NSApp.activate(ignoringOtherApps: true) }
        refreshDemand()
    }

    func selectCamera(_ id: String?) {
        selectedCameraID = id
        UserDefaults.standard.set(id, forKey: "cameraID")
        pipeline.setCamera(id: id)
    }

    /// macOS's Video Effects panel (Portrait, Studio Light…). Only the user can switch these; apps can't.
    func openVideoEffects() {
        AVCaptureDevice.showSystemUserInterface(.videoEffects)
    }

    private func refreshDemand() {
        guard cameraEnabled else { return }
        particles.isActive = editorOpen || consumers > 0
        pipeline.setDemand(virtualCamera: consumers > 0,
                           preview: editorOpen ? { [weak self] image, face in
                               Task { @MainActor in
                                   self?.preview.image = image
                                   self?.preview.face = face
                               }
                           } : nil)
    }

    /// Particle effects only run for visible layers, and only while the editor or an app is using the camera.
    private func syncParticles() {
        // The scene fading out keeps its particle effects running until the fade is over.
        particles.sync(layers: config.stickersEnabled ? config.activeScene.layers + (fadingOut?.layers ?? []) : [])
    }

    private func pushSettingsToPipeline() {
        pipeline.update(.init(scene: config.activeScene, stickersEnabled: config.stickersEnabled))
    }

    private func configChanged() {
        pushSettingsToPipeline()
        syncParticles()
        store.save(config)
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
        if id != config.activeScene.id, cameraEnabled {
            fadingOut = config.activeScene
            fadeTask?.cancel()
            fadeTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(CameraPipeline.fadeDuration + 0.1))
                guard !Task.isCancelled else { return }
                self?.fadingOut = nil
                self?.syncParticles()
            }
        }
        config.activeSceneID = id
        selectedLayerID = nil
    }

    func addScene() {
        let scene = CamScene(name: "Scene \(config.scenes.count + 1)")
        config.scenes.append(scene)
        selectScene(scene.id)
    }

    func duplicateScene(_ id: UUID) {
        guard var copy = config.scenes.first(where: { $0.id == id }) else { return }
        copy.id = UUID()
        copy.name += " copy"
        copy.layers = copy.layers.map { var l = $0; l.id = UUID(); return l }
        config.scenes.append(copy)
        selectScene(copy.id)
    }

    func renameScene(_ id: UUID, to name: String) {
        guard let i = config.scenes.firstIndex(where: { $0.id == id }) else { return }
        config.scenes[i].name = name
    }

    /// Reorders the scene list. The menu bar lists scenes in the same order.
    func moveScenes(fromOffsets source: IndexSet, toOffset destination: Int) {
        config.scenes.move(fromOffsets: source, toOffset: destination)
    }

    func setSceneIcon(_ id: UUID, to icon: String) {
        guard let i = config.scenes.firstIndex(where: { $0.id == id }) else { return }
        config.scenes[i].icon = icon
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

    // MARK: Layers

    func importImage(from url: URL) {
        guard let imported = library.importImage(from: url) else { return }
        pipeline.stickersChanged()
        addLayer(Layer(content: .image(file: imported.file),
                       anchor: .frame(Placement(x: 0.5, y: 0.5, width: 0.2, rotation: 0)),
                       styled: true, aspect: imported.aspect))
    }

    func addEffectLayer(_ preset: ParticlePreset) {
        addLayer(.effect(preset))
    }

    func addTextLayer() {
        let text = TextContent()
        addLayer(Layer(content: .text(text),
                       anchor: .frame(Placement(x: 0.5, y: 0.85, width: 0.4, rotation: 0)),
                       inFront: true, aspect: TextRenderer.aspect(of: text)))
    }

    private func addLayer(_ layer: Layer) {
        mutateScene { $0.layers.append(layer) }
        selectedLayerID = layer.id
    }

    func pickImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(importImage)
    }

    func updateLayer(_ id: UUID, _ change: (inout Layer) -> Void) {
        mutateScene { scene in
            if let i = scene.layers.firstIndex(where: { $0.id == id }) { change(&scene.layers[i]) }
        }
    }

    /// Changes a text layer's text. The layer keeps its width, so its height follows the new text.
    func setText(_ id: UUID, _ text: TextContent) {
        updateLayer(id) {
            $0.content = .text(text)
            $0.aspect = TextRenderer.aspect(of: text)
        }
    }

    /// Moves/resizes/rotates a layer to an on-screen placement. For head layers this updates the face-relative offset.
    func setPlacement(_ id: UUID, _ placement: Placement) {
        let face = preview.face
        updateLayer(id) { $0.setPlacement(placement, face: face) }
    }

    /// Ticking "Follow head" keeps the layer where it is relative to your live face (or puts it above the head if
    /// no face is visible) and puts it in front of you. Unticking leaves it where it is on screen.
    func setFollowHead(_ id: UUID, _ on: Bool) {
        let face = preview.face
        updateLayer(id) { layer in
            if on {
                guard !layer.followsHead else { return }
                if let current = layer.placement(face: face), let face {
                    layer.anchor = .head(HeadOffset(placement: current, relativeTo: face))
                } else {
                    layer.anchor = .head(HeadOffset())
                }
                layer.inFront = true
            } else if layer.followsHead {
                layer.anchor = .frame(layer.placement(face: face) ?? Placement(x: 0.5, y: 0.3, width: 0.2, rotation: 0))
            }
        }
    }

    func duplicateLayer(_ id: UUID) {
        var copyID: UUID?
        mutateScene { copyID = $0.duplicateLayer(id) }
        if let copyID { selectedLayerID = copyID }
    }

    func deleteLayer(_ id: UUID) {
        mutateScene { $0.layers.removeAll { $0.id == id } }
        if selectedLayerID == id { selectedLayerID = nil }
    }

    /// Drag reordering in the layer list (`onMove`). Positions are in the order the list shows: front at the top.
    func moveLayers(fromOffsets source: IndexSet, toOffset destination: Int) {
        mutateScene { $0.moveLayers(inDisplayOrder: source, to: destination) }
    }

    /// direction +1 brings the layer towards the front.
    func moveLayer(_ id: UUID, by direction: Int) {
        mutateScene { scene in
            guard let i = scene.layers.firstIndex(where: { $0.id == id }) else { return }
            let j = i + direction
            guard scene.layers.indices.contains(j) else { return }
            scene.layers.swapAt(i, j)
        }
    }
}
