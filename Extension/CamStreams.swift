import CoreMediaIO
import CoreVideo
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
    private var loggedFirstForward = false
    private var loggedPlaceholder = false
    private lazy var placeholder = PlaceholderCard.makePixelBuffer()
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
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        CamLog.ext.notice("source: client asked to start the stream")
        return true
    }

    func startStream() throws {
        CamLog.ext.notice("source: startStream (a meeting app started reading)")
        queue.sync {
            streaming += 1
            if timer == nil { startTimer() }
        }
        onConsumersChanged?(1)
    }

    func stopStream() throws {
        CamLog.ext.notice("source: stopStream")
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
            if !self.loggedFirstForward {
                self.loggedFirstForward = true
                CamLog.ext.notice("source: forwarding the first frame from the app")
            }
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
            if !self.loggedPlaceholder {
                self.loggedPlaceholder = true
                CamLog.ext.notice("source: no frames from the app, sending the placeholder card")
            }
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
}

// MARK: - Sink stream (what the Cam app writes into)

final class CamSinkStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let formatDescription: CMFormatDescription
    private var client: CMIOExtensionClient?
    private var sinkStarted = false
    private var loggedFirstConsume = false
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
        CamLog.ext.notice("sink: the Cam app connected")
        self.client = client
        return true
    }

    func startStream() throws {
        CamLog.ext.notice("sink: startStream (the Cam app is sending frames)")
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
                if !self.loggedFirstConsume {
                    self.loggedFirstConsume = true
                    CamLog.ext.notice("sink: received the first frame from the app")
                }
                self.forward?(buffer)
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                self.stream.notifyScheduledOutputChanged(
                    CMIOExtensionScheduledOutput(sequenceNumber: sequenceNumber, hostTimeInNanoseconds: hostNanos(now)))
            }
            self.consume(from: client)
        }
    }
}
