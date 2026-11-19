import CoreMedia
import CoreMediaIO
import Foundation

/// CMIO client for the Cam extension: finds the device, pushes frames into its sink stream,
/// and reads how many apps (Teams) are currently consuming the source stream.
final class VirtualCameraLink {
    private var deviceID = CMIODeviceID(kCMIODeviceUnknown)
    private var sinkID = CMIOStreamID(kCMIOStreamUnknown)
    private var queue: CMSimpleQueue?
    private(set) var isSinkOpen = false

    var deviceFound: Bool { findDevice() != nil }

    // MARK: Consumers

    func consumerCount() -> Int? {
        guard let device = findDevice() else { return nil }
        var address = Self.address(CamConstants.consumersProperty)
        guard CMIOObjectHasProperty(device, &address) else { return nil }
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &address, 0, nil, &size) == 0 else { return nil }
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &value) {
            CMIOObjectGetPropertyData(device, &address, 0, nil, size, &used, $0)
        }
        guard status == 0, let string = value?.takeRetainedValue() as String? else { return nil }
        return Int(string)
    }

    // MARK: Sink

    func openSink() -> Bool {
        if isSinkOpen { return true }
        guard let device = findDevice(), let sink = findSinkStream(of: device) else { return false }
        var unmanagedQueue: Unmanaged<CMSimpleQueue>?
        guard CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &unmanagedQueue) == 0,
              let q = unmanagedQueue?.takeRetainedValue() else { return false }
        guard CMIODeviceStartStream(device, sink) == 0 else { return false }
        deviceID = device
        sinkID = sink
        queue = q
        isSinkOpen = true
        return true
    }

    func closeSink() {
        guard isSinkOpen else { return }
        CMIODeviceStopStream(deviceID, sinkID)
        queue = nil
        isSinkOpen = false
    }

    func send(_ pixelBuffer: CVPixelBuffer) {
        guard isSinkOpen, let queue else { return }
        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else { return }
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: pixelBuffer,
                                                     formatDescriptionOut: &description)
        guard let description else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CamConstants.fps),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                 formatDescription: description, sampleTiming: &timing,
                                                 sampleBufferOut: &sample)
        guard let sample else { return }
        CMSimpleQueueEnqueue(queue, element: Unmanaged.passRetained(sample).toOpaque())
    }

    // MARK: Lookup

    private func findDevice() -> CMIODeviceID? {
        var address = Self.address(selector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0 else { return nil }
        var devices = [CMIODeviceID](repeating: 0, count: Int(size) / MemoryLayout<CMIODeviceID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == 0 else { return nil }
        return devices.first { stringProperty($0, CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID)) == CamConstants.deviceUUID.uuidString }
    }

    private func findSinkStream(of device: CMIODeviceID) -> CMIOStreamID? {
        var address = Self.address(selector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &address, 0, nil, &size) == 0 else { return nil }
        var streams = [CMIOStreamID](repeating: 0, count: Int(size) / MemoryLayout<CMIOStreamID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(device, &address, 0, nil, size, &used, &streams) == 0 else { return nil }
        return streams.first { stream in
            var direction = Self.address(selector: CMIOObjectPropertySelector(kCMIOStreamPropertyDirection))
            var value: UInt32 = 0
            var got: UInt32 = 0
            guard CMIOObjectGetPropertyData(stream, &direction, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &value) == 0 else { return false }
            return value == 1   // 0 = output (source), 1 = input (sink)
        }
    }

    private func stringProperty(_ object: CMIOObjectID, _ selector: CMIOObjectPropertySelector) -> String? {
        var address = Self.address(selector: selector)
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &value) {
            CMIOObjectGetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>>.size), &used, $0)
        }
        guard status == 0 else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func address(selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: selector,
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    /// "4cc_cons_glob_0000" -> selector 'cons', global scope, main element.
    private static func address(_ custom: String) -> CMIOObjectPropertyAddress {
        let code = custom.split(separator: "_")[1].utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return address(selector: code)
    }
}
