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
    private var previewHandler: ((CGImage, FaceState?) -> Void)?
    private let faceTracker = FaceTracker()
    private var lastPreview = Date.distantPast
    private var configured = false
    private var currentInput: AVCaptureDeviceInput?
    /// Only touched on `queue`.
    private var preferredCameraID: String?
    /// Watches macOS's Portrait effect on the camera Cam reads, so it's logged when it turns on or off.
    private var portraitObservation: NSKeyValueObservation?

    private(set) var isRunning = false

    init(stickersDir: URL, link: VirtualCameraLink, particleFrames: ParticleFrames) {
        compositor = Compositor(stickersDir: stickersDir, particleFrames: particleFrames)
        self.link = link
        super.init()
    }

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

    func setDemand(virtualCamera: Bool, preview: ((CGImage, FaceState?) -> Void)?) {
        lock.lock()
        sendToVirtualCamera = virtualCamera
        previewHandler = preview
        lock.unlock()
        if virtualCamera || preview != nil { start() } else { stop() }
    }

    private func start() {
        guard !isRunning else { return }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self, granted else { return }
            self.queue.async {
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

    /// Puts the chosen camera (or the first real one) on the session, replacing the previous one. Runs on `queue`.
    private func attachInput() -> Bool {
        let cameras = Self.realCameras(in: Self.makeDiscovery().devices)
        let device = cameras.first { $0.uniqueID == preferredCameraID } ?? cameras.first
        guard let device, device.uniqueID != currentInput?.device.uniqueID,
              let input = try? AVCaptureDeviceInput(device: device) else { return currentInput != nil }
        session.beginConfiguration()
        if let old = currentInput { session.removeInput(old); currentInput = nil }
        if session.canAddInput(input) { session.addInput(input); currentInput = input }
        if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
        session.commitConfiguration()
        faceTracker.reset()
        // For finding out where macOS applies its Portrait blur: "applied" means the picture Cam receives is already
        // blurred, before any layer is added.
        portraitObservation = device.observe(\.isPortraitEffectActive, options: [.initial, .new]) { device, _ in
            CamLog.app.notice("Portrait effect on \(device.localizedName, privacy: .public): applied to Cam's picture: \(device.isPortraitEffectActive, privacy: .public)")
        }
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

        // Face detection only runs when something needs it: a head sticker in this scene, or the editor is open
        // (so ticking "Follow head" can use your live face).
        let needsFace = (settings.stickersEnabled && (settings.scene.layers + (outgoing?.scene.layers ?? [])).contains { $0.followsHead }) || preview != nil
        var face: FaceState?
        if needsFace { face = faceTracker.update(frame: frame, time: time) } else { faceTracker.reset() }

        var image = compositor.render(frame: frame, scene: settings.scene, stickersEnabled: settings.stickersEnabled,
                                      time: time, face: face)
        if let outgoing {
            let old = compositor.render(frame: frame, scene: outgoing.scene, stickersEnabled: settings.stickersEnabled,
                                        time: time, face: face)
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
                DispatchQueue.main.async { preview(cg, face) }
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
