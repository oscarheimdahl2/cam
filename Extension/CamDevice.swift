import CoreMediaIO
import CoreVideo
import Foundation

/// The "Cam" device: one source stream that Teams reads, and one sink stream that the Cam app writes into.
final class CamDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var sourceStream: CamSourceStreamSource!
    private var sinkStream: CamSinkStreamSource!

    static let consumersProperty = CMIOExtensionProperty(rawValue: CamConstants.consumersProperty)

    /// Number of apps currently reading the source stream (e.g. Teams). The Cam app watches this
    /// so it only turns the physical camera on when somebody is looking.
    private(set) var consumers = 0 {
        didSet {
            CamLog.ext.notice("consumers is now \(self.consumers, privacy: .public)")
            device.notifyPropertiesChanged([Self.consumersProperty: CMIOExtensionPropertyState<AnyObject>(value: String(consumers) as NSString)])
        }
    }

    init(localizedName: String) {
        super.init()
        CamLog.ext.notice("extension started")
        device = CMIOExtensionDevice(localizedName: localizedName,
                                     deviceID: CamConstants.deviceUUID,
                                     legacyDeviceID: nil,
                                     source: self)

        let description = Self.makeFormatDescription()
        sourceStream = CamSourceStreamSource(formatDescription: description)
        sinkStream = CamSinkStreamSource(formatDescription: description)
        sourceStream.onConsumersChanged = { [weak self] delta in
            self?.consumers = max(0, (self?.consumers ?? 0) + delta)
        }
        sinkStream.forward = { [weak self] buffer in self?.sourceStream.forward(buffer) }

        do {
            try device.addStream(sourceStream.stream)
            try device.addStream(sinkStream.stream)
        } catch {
            fatalError("Failed to add streams: \(error)")
        }
    }

    static func makeFormatDescription() -> CMFormatDescription {
        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                       codecType: kCVPixelFormatType_32BGRA,
                                       width: CamConstants.width,
                                       height: CamConstants.height,
                                       extensions: nil,
                                       formatDescriptionOut: &description)
        return description!
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel, Self.consumersProperty]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let state = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            state.transportType = 0x76697274 /* 'virt' */
        }
        if properties.contains(.deviceModel) {
            state.model = "Cam Virtual Camera"
        }
        if properties.contains(Self.consumersProperty) {
            state.setPropertyState(CMIOExtensionPropertyState<AnyObject>(value: String(consumers) as NSString), forProperty: Self.consumersProperty)
        }
        return state
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}
}
