import SwiftUI

/// Which camera Cam reads, and how to get a blurred background without blurring the stickers.
struct CameraSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CameraPicker(model: model)
            Button("Open Video Effects…", systemImage: "person.crop.rectangle") { model.openVideoEffects() }
            Text("For a blurred background, switch on Portrait for Cam. Keep Portrait off for the app that shows the Cam camera (Teams, Zoom…), or your stickers get blurred too.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 300)
    }
}

/// The camera choice as a picker. "Automatic" uses the first camera found.
struct CameraPicker: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Picker("Camera", selection: Binding(get: { model.selectedCameraID }, set: { model.selectCamera($0) })) {
            Text("Automatic").tag(String?.none)
            ForEach(model.cameras) { Text($0.name).tag(Optional($0.id)) }
        }
    }
}
