import Foundation

/// The two colour schemes of the app (Settings → General → Appearance resolves "system" to one of them).
public enum ThemeScheme: Sendable, CaseIterable {
    case dark
    case light
}

/// A colour with one value per scheme.
public struct ThemeColour: Equatable, Sendable {
    public let dark: ClusterPalette.RGB
    public let light: ClusterPalette.RGB

    public func value(for scheme: ThemeScheme) -> ClusterPalette.RGB {
        scheme == .dark ? dark : light
    }

    fileprivate init(dark: UInt32, light: UInt32) {
        self.dark = ClusterPalette.RGB(rgb: dark)
        self.light = ClusterPalette.RGB(rgb: light)
    }
}

/// The "Signal Grid" colours, see `docs/DESIGN.md`. The app wraps each one into a dynamic colour;
/// `ThemeTokensTests` holds every text/ground pair to its contrast target.
public enum ThemeTokens {
    public static let window = ThemeColour(dark: 0x0E0E0F, light: 0xF2F0EB)
    public static let panel = ThemeColour(dark: 0x131314, light: 0xE9E6DF)
    public static let surface = ThemeColour(dark: 0x171718, light: 0xFAF9F6)
    public static let hairline = ThemeColour(dark: 0x2B2B2D, light: 0xD3CFC6)
    public static let text = ThemeColour(dark: 0xE8E6E1, light: 0x16161A)
    public static let textMid = ThemeColour(dark: 0xB4B2AC, light: 0x4A4843)
    public static let textDim = ThemeColour(dark: 0x8F8F8A, light: 0x5F5D58)
    /// Fills and thin strokes: playing, selected ring, progress, waveform. Darker on the light ground to keep 3:1.
    public static let signal = ThemeColour(dark: 0xFF5A1F, light: 0xE9440E)
    /// Signal-coloured text.
    public static let signalText = ThemeColour(dark: 0xFF5A1F, light: 0xB93705)
    /// Text and glyphs on a `signal` fill.
    public static let onSignal = ThemeColour(dark: 0x0E0E0F, light: 0x16161A)

    /// The ground a cluster colour has to stand out against (map, sidebar, table).
    public static let clusterGround = window
}

extension ClusterPalette.RGB {
    fileprivate init(rgb value: UInt32) {
        self.init(red: UInt8(value >> 16), green: UInt8((value >> 8) & 255), blue: UInt8(value & 255))
    }

    /// WCAG relative luminance, 0 (black) to 1 (white).
    public var relativeLuminance: Double {
        func linear(_ byte: UInt8) -> Double {
            let c = Double(byte) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio, 1 (identical) to 21 (black on white); symmetric.
    public func contrast(against other: Self) -> Double {
        let (a, b) = (relativeLuminance, other.relativeLuminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// This colour, or the nearest darker (on a light ground) or lighter (on a dark ground) one with the same hue
    /// that reaches `minimum` contrast. Colours that already do are returned unchanged, so the result is stable.
    public func legible(on ground: Self, minimum: Double = 3) -> Self {
        guard contrast(against: ground) < minimum else { return self }
        let towardWhite = ground.relativeLuminance < 0.5
        let target: Double = towardWhite ? 255 : 0
        func mix(_ byte: UInt8, _ amount: Double) -> UInt8 {
            UInt8((Double(byte) + (target - Double(byte)) * amount).rounded())
        }
        var best = self
        for step in 1...50 {
            let amount = Double(step) / 50
            best = Self(red: mix(red, amount), green: mix(green, amount), blue: mix(blue, amount))
            if best.contrast(against: ground) >= minimum { break }
        }
        return best
    }
}
