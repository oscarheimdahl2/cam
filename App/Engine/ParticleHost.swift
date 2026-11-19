import CoreImage
import SwiftUI
import Vortex

/// The most recent picture of each particle layer. Written on the main thread by `ParticleHost`, read from the
/// capture thread by the compositor.
final class ParticleFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [UUID: CIImage] = [:]

    func frame(for id: UUID) -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        return frames[id]
    }

    fileprivate func set(_ image: CIImage, for id: UUID) {
        lock.lock(); frames[id] = image; lock.unlock()
    }

    fileprivate func keepOnly(_ ids: Set<UUID>) {
        lock.lock(); frames = frames.filter { ids.contains($0.key) }; lock.unlock()
    }
}

/// Runs the particle effects. Vortex only draws through SwiftUI and keeps its particles to itself, so each effect is
/// a `VortexView` that `ImageRenderer` turns into a picture about 30 times a second (about 1.5 ms each at the
/// size used here). Particles advance with the wall clock.
@MainActor
final class ParticleHost {
    /// Rendered at half the output width; the layer renderer scales it up like any other image.
    static let frameSize = CGSize(width: 960, height: 540)
    private static let framesPerSecond = 30.0

    private final class Running {
        let preset: ParticlePreset
        let system: VortexSystem
        let renderer: ImageRenderer<AnyView>
        /// For burst-only effects: when the current burst ends, and when the next automatic one is due.
        var burstEnd: Date?
        var nextAutoBurst = Date()

        init(preset: ParticlePreset, system: VortexSystem, renderer: ImageRenderer<AnyView>) {
            self.preset = preset; self.system = system; self.renderer = renderer
        }
    }

    private static let burstBirthRate = 600.0
    private static let burstDuration = 0.1
    private static let autoBurstInterval: TimeInterval = 3

    private let frames: ParticleFrames
    private var running: [UUID: Running] = [:]
    private var timer: Timer?
    private var tickCount = 0

    /// Effects only run while someone is looking (the editor is open or a meeting app uses the camera).
    var isActive = false { didSet { updateTimer() } }

    init(frames: ParticleFrames) { self.frames = frames }

    /// Starts effects for new particle layers, restarts ones whose preset changed, and stops removed ones.
    func sync(layers: [Layer]) {
        var wanted: [UUID: ParticlePreset] = [:]
        for layer in layers {
            if case .particles(let content) = layer.content { wanted[layer.id] = content.preset }
        }
        running = running.filter { wanted[$0.key] == $0.value.preset }
        for (id, preset) in wanted where running[id] == nil {
            let system = Self.system(for: preset)
            let renderer = ImageRenderer(content: AnyView(Self.view(for: system)))
            renderer.proposedSize = ProposedViewSize(Self.frameSize)
            renderer.isOpaque = false
            renderer.scale = 1
            running[id] = Running(preset: preset, system: system, renderer: renderer)
        }
        frames.keepOnly(Set(running.keys))
        updateTimer()
    }

    private func updateTimer() {
        let shouldRun = isActive && !running.isEmpty
        if shouldRun, timer == nil {
            let timer = Timer(timeInterval: 1 / Self.framesPerSecond, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)   // keep going while a menu is open
            self.timer = timer
        } else if !shouldRun {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Fires a burst now (confetti). Vortex's own burst is only reachable through SwiftUI view plumbing, so this uses
    /// the public `birthRate` instead: a very high rate for a moment, then back to the preset's own.
    func burst(layer id: UUID) {
        guard let effect = running[id] else { return }
        effect.system.birthRate = Self.burstBirthRate
        effect.burstEnd = Date().addingTimeInterval(Self.burstDuration)
    }

    private func tick() {
        tickCount += 1
        let now = Date()
        for (id, effect) in running {
            if effect.preset.isBurstOnly {
                if let end = effect.burstEnd, now >= end {
                    effect.system.birthRate = 0
                    effect.burstEnd = nil
                }
                if effect.burstEnd == nil, now >= effect.nextAutoBurst {
                    burst(layer: id)
                    effect.nextAutoBurst = now.addingTimeInterval(Self.autoBurstInterval)
                }
            }
            // ImageRenderer caches an unchanged view, so give it a new identity each time to force a redraw.
            effect.renderer.content = AnyView(Self.view(for: effect.system).id(tickCount))
            if let image = effect.renderer.cgImage { frames.set(CIImage(cgImage: image), for: id) }
        }
    }

    private static func view(for system: VortexSystem) -> some View {
        VortexView(system) {
            // The four tags the presets use. Additive blending makes overlapping particles glow.
            Image.circle.frame(width: 16).blendMode(.plusLighter).tag("circle")
            Image.confetti.frame(width: 16, height: 16).blendMode(.plusLighter).tag("confetti")
            Image.sparkle.frame(width: 16, height: 16).blendMode(.plusLighter).tag("sparkle")
            Rectangle().fill(Color.white).frame(width: 16, height: 16).blendMode(.plusLighter).tag("square")
        }
        .frame(width: frameSize.width, height: frameSize.height)
    }

    /// Each layer needs its own system: the presets are shared objects that keep their particles inside.
    private static func system(for preset: ParticlePreset) -> VortexSystem {
        let shared: VortexSystem
        switch preset {
        case .fireflies: shared = .fireflies
        case .snow: shared = .snow
        case .confetti: shared = .confetti
        case .fireworks: shared = .fireworks
        case .magic: shared = .magic
        case .spark: shared = .spark
        case .fire: shared = .fire
        case .smoke: shared = .smoke
        case .rain: shared = .rain
        case .splash: shared = .splash
        }
        return shared.makeUniqueCopy()
    }
}
