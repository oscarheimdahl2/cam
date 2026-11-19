import CoreMediaIO
import CoreVideo
import CoreGraphics
import CoreText
import Foundation

private func hostNanos(_ time: CMTime) -> UInt64 {
    UInt64(max(0, time.seconds) * Double(NSEC_PER_SEC))
}

private let frameDuration = CMTime(value: 1, timescale: CamConstants.fps)

private func makeFormat(_ description: CMFormatDescription) -> CMIOExtensionStreamFormat {
    CMIOExtensionStreamFormat(formatDescription: description,
                              maxFrameDuration: frameDuration,
                              minFrameDuration: frameDuration,
                              validFrameDurations: nil)
}

// MARK: - Source stream (what Teams reads)

final class CamSourceStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let formatDescription: CMFormatDescription
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "cam.source")
    private var streaming = 0
    private var lastRealFrame = DispatchTime(uptimeNanoseconds: 0)
    private lazy var placeholder = makePlaceholder()
    var onConsumersChanged: ((Int) -> Void)?

    init(formatDescription: CMFormatDescription) {
        self.formatDescription = formatDescription
        super.init()
        stream = CMIOExtensionStream(localizedName: "\(CamConstants.deviceName) Video",
                                     streamID: CamConstants.sourceStreamUUID,
                                     direction: .source,
                                     clockType: .hostTime,
                                     source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [makeFormat(formatDescription)] }
    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let state = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { state.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { state.frameDuration = frameDuration }
        return state
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        queue.sync {
            streaming += 1
            if timer == nil { startTimer() }
        }
        onConsumersChanged?(1)
    }

    func stopStream() throws {
        queue.sync {
            streaming = max(0, streaming - 1)
            if streaming == 0 {
                timer?.cancel()
                timer = nil
            }
        }
        onConsumersChanged?(-1)
    }

    /// Frame arriving from the Cam app through the sink stream.
    func forward(_ buffer: CMSampleBuffer) {
        queue.async {
            guard self.streaming > 0 else { return }
            self.lastRealFrame = .now()
            let pts = CMClockGetTime(CMClockGetHostTimeClock())
            self.stream.send(buffer, discontinuity: [], hostTimeInNanoseconds: hostNanos(pts))
        }
    }

    // While the app isn't feeding us, show a "not running" card instead of freezing.
    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let stale = DispatchTime.now().uptimeNanoseconds - self.lastRealFrame.uptimeNanoseconds > 500_000_000
            guard stale, let placeholder = self.placeholder else { return }
            let pts = CMClockGetTime(CMClockGetHostTimeClock())
            var timing = CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: placeholder,
                                                     formatDescription: self.formatDescription,
                                                     sampleTiming: &timing,
                                                     sampleBufferOut: &sample)
            if let sample {
                self.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: hostNanos(pts))
            }
        }
        self.timer = timer
        timer.resume()
    }

    private func makePlaceholder() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true,
                     kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, Int(CamConstants.width), Int(CamConstants.height),
                            kCVPixelFormatType_32BGRA, attrs, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                      width: Int(CamConstants.width), height: Int(CamConstants.height),
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: Int(CamConstants.width), height: Int(CamConstants.height)))
        let text = "Cam isn't running. Open the Cam app." as CFString
        let font = CTFontCreateWithName("Helvetica" as CFString, 56, nil)
        let attributes = [kCTFontAttributeName: font,
                          kCTForegroundColorAttributeName: CGColor(gray: 0.85, alpha: 1)] as CFDictionary
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text, attributes))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        context.textPosition = CGPoint(x: (CGFloat(CamConstants.width) - bounds.width) / 2,
                                       y: CGFloat(CamConstants.height) / 2)
        CTLineDraw(line, context)
        return buffer
    }
}

// MARK: - Sink stream (what the Cam app writes into)

final class CamSinkStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let formatDescription: CMFormatDescription
    private var client: CMIOExtensionClient?
    private var sinkStarted = false
    var forward: ((CMSampleBuffer) -> Void)?

    init(formatDescription: CMFormatDescription) {
        self.formatDescription = formatDescription
        super.init()
        stream = CMIOExtensionStream(localizedName: "\(CamConstants.deviceName) Sink",
                                     streamID: CamConstants.sinkStreamUUID,
                                     direction: .sink,
                                     clockType: .hostTime,
                                     source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [makeFormat(formatDescription)] }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let state = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { state.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { state.frameDuration = frameDuration }
        if properties.contains(.streamSinkBufferQueueSize) { state.sinkBufferQueueSize = 3 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { state.sinkBuffersRequiredForStartup = 1 }
        return state
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws {
        sinkStarted = true
        if let client { consume(from: client) }
    }

    func stopStream() throws {
        sinkStarted = false
    }

    private func consume(from client: CMIOExtensionClient) {
        guard sinkStarted else { return }
        stream.consumeSampleBuffer(from: client) { [weak self] buffer, sequenceNumber, discontinuity, hasMore, error in
            guard let self else { return }
            if let buffer {
                self.forward?(buffer)
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                self.stream.notifyScheduledOutputChanged(
                    CMIOExtensionScheduledOutput(sequenceNumber: sequenceNumber, hostTimeInNanoseconds: hostNanos(now)))
            }
            self.consume(from: client)
        }
    }
}
