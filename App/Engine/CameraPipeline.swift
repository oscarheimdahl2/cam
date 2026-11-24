import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

struct CameraChoice: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Captures the physical camera, composites each frame, and fans the result out
/// to the virtual camera and/or the editor preview.
final class CameraPipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    struct Settings { var scene: CamScene; var stickersEnabled: Bool }

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "cam.capture", qos: .userInitiated)
    private let compositor: Compositor
    private let link: VirtualCameraLink
    private var pool: CVPixelBufferPool?
    private let lock = NSLock()
    private var settings = Settings(scene: CamScene(name: ""), stickersEnabled: true)
    private var sendToVirtualCamera = false
    /// The scene being faded out; `start` is the camera time of the first frame of the fade. Guarded by `lock`.
    private var fade: (from: CamScene, start: Double?)?
    private var previewHandler: ((CGImage, Tracking) -> Void)?
    private let headTracker = PoseTracker.head()
    private let leftHandTracker = PoseTracker.hand(.left)
    private let rightHandTracker = PoseTracker.hand(.right)
    private var lastPreview = Date.distantPast
    private var configured = false
    private var currentInput: AVCaptureDeviceInput?
    /// Only touched on `queue`.
    private var preferredCameraID: String?
    /// Watches macOS's Portrait effect on the camera Cam reads, so it's logged when it turns on or off.
    private var portraitObservation: NSKeyValueObservation?
    /// Whether the session should be running (demand exists). Only touched on `queue`.
    private var shouldRun = false
    private var observers: [NSObjectProtocol] = []

    private(set) var isRunning = false

    init(stickersDir: URL, link: VirtualCameraLink, particleFrames: ParticleFrames) {
        compositor = Compositor(stickersDir: stickersDir, particleFrames: particleFrames)
        self.link = link
        super.init()
        watchForCameraProblems()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    // MARK: Control (call from main)

    /// How long switching scenes cross-fades, in seconds.
    static let fadeDuration = 0.5

    func update(_ settings: Settings) {
        lock.lock()
        // Switching to another scene fades from the old one (a rapid second switch fades from the one on screen).
        if settings.scene.id != self.settings.scene.id, !self.settings.scene.name.isEmpty || !self.settings.scene.layers.isEmpty {
            fade = (from: self.settings.scene, start: nil)
        }
        self.settings = settings
        lock.unlock()
    }

    /// The virtual camera disappeared (for instance its extension was replaced): drop the old frame pipe, so a new one
    /// is opened when the device comes back.
    func virtualCameraLost() {
        queue.async { self.link.closeSink() }
    }

    func stickersChanged() { queue.async { self.compositor.forgetCachedImages() } }

    func setDemand(virtualCamera: Bool, preview: ((CGImage, Tracking) -> Void)?) {
        lock.lock()
        sendToVirtualCamera = virtualCamera
        previewHandler = preview
        lock.unlock()
        if virtualCamera || preview != nil { start() } else { stop() }
    }

    private func start() {
        guard !isRunning else { return }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                CamLog.app.error("camera: access to the camera was denied (System Settings > Privacy & Security > Camera)")
                return
            }
            self.queue.async {
                self.shouldRun = true
                guard self.configureIfNeeded() else { return }
                if !self.session.isRunning { self.session.startRunning() }
                DispatchQueue.main.async { self.isRunning = true }
            }
        }
    }

    private func stop() {
        guard isRunning else { return }
        isRunning = false
        queue.async {
            self.shouldRun = false
            if self.session.isRunning { self.session.stopRunning() }
            self.link.closeSink()
        }
    }

    /// A camera Cam can read: any real camera, never Cam's own virtual one.
    static func realCameras(in devices: [AVCaptureDevice]) -> [AVCaptureDevice] {
        devices.filter { $0.localizedName != CamConstants.deviceName && $0.uniqueID != CamConstants.deviceUUID.uuidString }
    }

    static func makeDiscovery() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified)
    }

    /// Reads from this camera (`nil`: the first one found). Switches live if the camera is already running.
    func setCamera(id: String?) {
        queue.async {
            guard self.preferredCameraID != id else { return }
            self.preferredCameraID = id
            if self.configured { _ = self.attachInput() }
        }
    }

    /// The list of cameras changed (one was plugged in or woke up): switch to the chosen camera if it is there now.
    func camerasChanged() {
        queue.async { if self.configured { _ = self.attachInput() } }
    }

    /// Reattaches and restarts the camera when it goes away, errors out or is interrupted, so it doesn't stay dead
    /// until the app happens to stop and start it again.
    private func watchForCameraProblems() {
        let center = NotificationCenter.default
        func watch(_ name: Notification.Name, _ handler: @escaping (CameraPipeline, Notification) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                guard let self else { return }
                self.queue.async { handler(self, note) }
            })
        }
        watch(AVCaptureDevice.wasConnectedNotification) { me, _ in
            if me.configured { _ = me.attachInput() }
        }
        watch(AVCaptureDevice.wasDisconnectedNotification) { me, note in
            guard me.configured else { return }
            CamLog.app.notice("camera: a camera was disconnected: \((note.object as? AVCaptureDevice)?.localizedName ?? "?", privacy: .public)")
            _ = me.attachInput()
            me.restartIfNeeded()
        }
        watch(AVCaptureSession.runtimeErrorNotification) { me, note in
            guard (note.object as? AVCaptureSession) === me.session else { return }
            CamLog.app.error("camera: the capture session failed: \(String(describing: note.userInfo?[AVCaptureSessionErrorKey]), privacy: .public)")
            _ = me.attachInput(force: true)
            me.restartIfNeeded()
        }
        watch(AVCaptureSession.wasInterruptedNotification) { me, note in
            guard (note.object as? AVCaptureSession) === me.session else { return }
            CamLog.app.notice("camera: the session was interrupted")
        }
        watch(AVCaptureSession.interruptionEndedNotification) { me, note in
            guard (note.object as? AVCaptureSession) === me.session else { return }
            me.restartIfNeeded()
        }
    }

    private func restartIfNeeded() {
        if shouldRun, currentInput != nil, !session.isRunning { session.startRunning() }
    }

    private func configureIfNeeded() -> Bool {
        if configured { return true }
        guard attachInput() else { return false }
        session.beginConfiguration()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        configured = true
        return true
    }

    /// Puts the chosen camera on the session, replacing the previous one. Runs on `queue`.
    /// The chosen camera wins as soon as it is available. Until then (or with "Automatic") the camera already in use
    /// stays, and only if that one is gone does the first real one take over. `force` rebuilds the input even if it is
    /// the same camera, to recover from an error.
    private func attachInput(force: Bool = false) -> Bool {
        let cameras = Self.realCameras(in: Self.makeDiscovery().devices)
        let current = currentInput.flatMap { input in cameras.first { $0.uniqueID == input.device.uniqueID } }
        let device = cameras.first { $0.uniqueID == preferredCameraID } ?? current ?? cameras.first
        guard let device else {
            if let old = currentInput {   // the camera is gone and no other is available
                session.beginConfiguration()
                session.removeInput(old)
                session.commitConfiguration()
                currentInput = nil
                CamLog.app.notice("camera: no camera available")
            }
            return false
        }
        guard force || device.uniqueID != currentInput?.device.uniqueID else { return currentInput != nil }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch {
            CamLog.app.error("camera: could not open \(device.localizedName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return currentInput != nil
        }
        session.beginConfiguration()
        let old = currentInput
        if let old { session.removeInput(old); currentInput = nil }
        // The previous camera's size may be more than this one can do, and then the session refuses the input and
        // nothing is delivered: start from the default size and pick the best one after the input is in.
        session.sessionPreset = .high
        if session.canAddInput(input) {
            session.addInput(input); currentInput = input
        } else {
            CamLog.app.error("camera: the session refused \(device.localizedName, privacy: .public)")
            if let old, session.canAddInput(old) { session.addInput(old); currentInput = old }
        }
        // The best size this camera can do, up to 1080p. A preset it can't do must not stay from the previous camera
        // (a 720p camera after a 1080p one would deliver no frames at all).
        let preset = [AVCaptureSession.Preset.hd1920x1080, .hd1280x720, .high].first { self.session.canSetSessionPreset($0) }
        session.sessionPreset = preset ?? .high
        CamLog.app.notice("camera: \(device.localizedName, privacy: .public) preset \(self.session.sessionPreset.rawValue, privacy: .public)")
        session.commitConfiguration()
        guard currentInput === input else { return currentInput != nil }
        headTracker.reset()
        leftHandTracker.reset()
        rightHandTracker.reset()
        CamLog.app.notice("camera: using \(device.localizedName, privacy: .public)")
        // For finding out where macOS applies its Portrait blur: "applied" means the picture Cam receives is already
        // blurred, before any layer is added.
        portraitObservation = device.observe(\.isPortraitEffectActive, options: [.initial, .new]) { device, _ in
            CamLog.app.notice("Portrait effect on \(device.localizedName, privacy: .public): applied to Cam's picture: \(device.isPortraitEffectActive, privacy: .public)")
        }
        restartIfNeeded()
        return currentInput != nil
    }

    // MARK: Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let frame = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        let settings = self.settings, toCamera = sendToVirtualCamera, preview = previewHandler
        // Camera timestamp, not "now": steady even when processing time varies.
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        var outgoing: (scene: CamScene, progress: Double)?
        if var current = fade {
            let start = current.start ?? time
            let progress = (time - start) / Self.fadeDuration
            if progress >= 1 || progress < 0 { fade = nil } else {
                current.start = start
                fade = current
                outgoing = (current.from, progress)
            }
        }
        lock.unlock()

        // Head and hand detection only run when something needs them: a layer that follows one in this scene, or the
        // editor is open (so choosing "Follow" can use your live head or hand).
        let layers = settings.stickersEnabled ? settings.scene.layers + (outgoing?.scene.layers ?? []) : []
        let editing = preview != nil
        var tracking = Tracking()
        if editing || layers.contains(where: \.followsHead) {
            tracking.head = headTracker.update(frame: frame, time: time)
        } else { headTracker.reset() }
        if editing || layers.contains(where: { $0.followedHand == .left }) {
            tracking.leftHand = leftHandTracker.update(frame: frame, time: time)
        } else { leftHandTracker.reset() }
        if editing || layers.contains(where: { $0.followedHand == .right }) {
            tracking.rightHand = rightHandTracker.update(frame: frame, time: time)
        } else { rightHandTracker.reset() }

        var image = compositor.render(frame: frame, scene: settings.scene, stickersEnabled: settings.stickersEnabled,
                                      time: time, tracking: tracking)
        if let outgoing {
            let old = compositor.render(frame: frame, scene: outgoing.scene, stickersEnabled: settings.stickersEnabled,
                                        time: time, tracking: tracking)
            let dissolve = CIFilter.dissolveTransition()
            dissolve.inputImage = old
            dissolve.targetImage = image
            dissolve.time = Float(outgoing.progress)
            image = dissolve.outputImage?.cropped(to: OutputFrame.rect) ?? image
        }

        if toCamera, link.openSink() || link.isSinkOpen, let buffer = makeOutputBuffer() {
            compositor.render(image, to: buffer)
            link.send(buffer)
        }
        if let preview, Date().timeIntervalSince(lastPreview) > 0.030 {
            lastPreview = Date()
            if let cg = compositor.cgImage(image, maxWidth: 960) {
                DispatchQueue.main.async { preview(cg, tracking) }
            }
        }
    }

    private func makeOutputBuffer() -> CVPixelBuffer? {
        if pool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(CamConstants.width),
                kCVPixelBufferHeightKey as String: Int(CamConstants.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        }
        var buffer: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) }
        return buffer
    }
}
