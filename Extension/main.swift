import CoreMediaIO
import Foundation

let providerSource = CamProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
