import CoreMediaIO
import Foundation

final class CamProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: CamDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = CamDeviceSource(localizedName: CamConstants.deviceName)
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let state = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            state.manufacturer = "Cam"
        }
        return state
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
