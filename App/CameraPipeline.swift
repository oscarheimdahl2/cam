import AVFoundation
import CoreImage

/// Captures the physical camera, composites each frame, and fans the result out
/// to the virtual camera and/or the editor preview.
final class CameraPipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    struct Settings { var scene: CamScene; var stickersEnabled: Bool; var partyMode = false }

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "cam.capture", qos: .userInitiated)
    private let compositor: Compositor
    private let link: VirtualCameraLink
    private var pool: CVPixelBufferPool?
    private let lock = NSLock()
    private var settings = Settings(scene: CamScene(name: ""), stickersEnabled: true)
    private var sendToVirtualCamera = false
    private var previewHandler: ((CGImage) -> Void)?
    private var lastPreview = Date.distantPast
    private var configured = false

    private(set) var isRunning = false

    init(stickersDir: URL, link: VirtualCameraLink) {
        compositor = Compositor(stickersDir: stickersDir)
        self.link = link
        super.init()
    }

    // MARK: Control (call from main)

    func update(_ settings: Settings) {
        lock.lock(); self.settings = settings; lock.unlock()
    }

    func stickersChanged() { queue.async { self.compositor.forgetCachedImages() } }

    func setDemand(virtualCamera: Bool, preview: ((CGImage) -> Void)?) {
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

    private func configureIfNeeded() -> Bool {
        if configured { return true }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified)
        // Never capture our own virtual camera.
        let device = discovery.devices.first {
            $0.localizedName != CamConstants.deviceName && $0.uniqueID != CamConstants.deviceUUID.uuidString
        }
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
        if session.canAddInput(input) { session.addInput(input) }
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        configured = true
        return true
    }

    // MARK: Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let frame = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        let settings = self.settings, toCamera = sendToVirtualCamera, preview = previewHandler
        lock.unlock()

        let image = compositor.render(frame: frame, scene: settings.scene, stickersEnabled: settings.stickersEnabled,
                                      partyMode: settings.partyMode, time: ProcessInfo.processInfo.systemUptime)

        if toCamera, link.openSink() || link.isSinkOpen, let buffer = makeOutputBuffer() {
            compositor.render(image, to: buffer)
            link.send(buffer)
        }
        if let preview, Date().timeIntervalSince(lastPreview) > 1.0 / 20 {
            lastPreview = Date()
            if let cg = compositor.cgImage(image, maxWidth: 960) {
                DispatchQueue.main.async { preview(cg) }
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
