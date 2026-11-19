import CoreGraphics
import Foundation

/// The live preview frame and tracked face. Kept apart from `AppModel` on purpose: it changes ~30 times a second,
/// and only the preview canvas should redraw for that, not the whole editor.
@MainActor
final class PreviewState: ObservableObject {
    @Published var image: CGImage?
    @Published var face: FaceState?
}
