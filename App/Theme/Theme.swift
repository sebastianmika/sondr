import AppKit
import SondrCore
import SwiftUI

/// The Signal Grid colours as dynamic colours: they resolve from the effective appearance, so views never
/// branch on the colour scheme. Values live in `ThemeTokens` (SondrCore), where they are tested.
enum Theme {
    static let window = colour(ThemeTokens.window)
    static let panel = colour(ThemeTokens.panel)
    static let surface = colour(ThemeTokens.surface)
    static let hairline = colour(ThemeTokens.hairline)
    static let text = colour(ThemeTokens.text)
    static let textMid = colour(ThemeTokens.textMid)
    static let textDim = colour(ThemeTokens.textDim)
    static let signal = colour(ThemeTokens.signal)
    static let signalText = colour(ThemeTokens.signalText)
    static let onSignal = colour(ThemeTokens.onSignal)

    static func scheme(_ colorScheme: ColorScheme) -> ThemeScheme { colorScheme == .dark ? .dark : .light }

    /// The scheme the given appearance resolves to.
    static func scheme(of appearance: NSAppearance) -> ThemeScheme {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    static func nsColour(_ token: ThemeColour) -> NSColor {
        NSColor(name: nil) { appearance in
            let rgb = token.value(for: scheme(of: appearance))
            return NSColor(
                srgbRed: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255, blue: CGFloat(rgb.blue) / 255, alpha: 1)
        }
    }

    /// A stored cluster colour, adjusted per appearance so it keeps 3:1 against the ground (see `ThemeTokens.clusterGround`).
    static func legibleCluster(_ rgb: ClusterPalette.RGB) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let c = rgb.legible(on: ThemeTokens.clusterGround.value(for: scheme(of: appearance)))
                return NSColor(srgbRed: CGFloat(c.red) / 255, green: CGFloat(c.green) / 255, blue: CGFloat(c.blue) / 255, alpha: 1)
            })
    }

    private static func colour(_ token: ThemeColour) -> Color { Color(nsColor: nsColour(token)) }
}
