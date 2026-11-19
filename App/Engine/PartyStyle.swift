import CoreImage

/// What a layer's party mode adds: a slowly drifting rainbow wash and, for layers fixed in the frame, a slow
/// spin. Speeds are deliberately slow. These are ordinary `Motion`s, the same ones a layer can have on its own.
enum PartyStyle {
    static let spinRadiansPerSecond = 0.25
    static let huePerLayer = 0.17   // each layer starts at a different hue
    static let rainbow = Motion.hueDrift(speed: 0.055, opacity: 0.38)   // one trip round the colour wheel takes ~18 s

    static func motions(for layer: Layer) -> [Motion] {
        var motions = [rainbow]
        // Head layers follow the head instead of spinning.
        if !layer.followsHead { motions.append(.spin(speed: spinRadiansPerSecond * spinDirection(of: layer))) }
        return motions
    }

    /// Each layer spins clockwise or counter-clockwise, picked at random but stable: it comes from the layer's id,
    /// so it doesn't flip from frame to frame.
    static func spinDirection(of layer: Layer) -> Double {
        layer.id.uuid.0 % 2 == 0 ? 1 : -1
    }

    /// Fully saturated colour for a hue in 0...1 (HSV with s = v = 1).
    static func rainbowColor(hue: Double, alpha: CGFloat) -> CIColor {
        let h = hue * 6
        let f = h - floor(h)
        let (r, g, b): (Double, Double, Double)
        switch Int(floor(h)) % 6 {
        case 0: (r, g, b) = (1, f, 0)
        case 1: (r, g, b) = (1 - f, 1, 0)
        case 2: (r, g, b) = (0, 1, f)
        case 3: (r, g, b) = (0, 1 - f, 1)
        case 4: (r, g, b) = (f, 0, 1)
        default: (r, g, b) = (1, 0, 1 - f)
        }
        return CIColor(red: r, green: g, blue: b, alpha: alpha)
    }
}
