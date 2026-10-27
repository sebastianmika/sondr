import SondrCore
import SwiftUI

/// Small Signal Grid building blocks shared by the views.

/// Cluster colour that stays legible on the ground of the current appearance (see ``ClusterPalette/RGB/legible(on:minimum:)``).
/// The stored colour is never changed.
func clusterColor(_ id: Int, _ palette: ClusterPalette) -> Color {
    Theme.legibleCluster(palette.rgb(forCluster: id))
}

/// The 8 pt square that marks a cluster in lists.
struct ClusterMarker: View {
    let color: Color

    var body: some View {
        Rectangle().fill(color).frame(width: 8, height: 8)
    }
}

/// Segmented progress bar: five lit pixels, two dark, like the step LEDs of the icon.
struct LEDProgress: View {
    let value: Double
    let total: Double

    var body: some View {
        Canvas { context, size in
            let fraction = total > 0 ? min(max(value / total, 0), 1) : 0
            let lit = size.width * fraction
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.hairline))
            var x: CGFloat = 0
            while x < lit {
                context.fill(Path(CGRect(x: x, y: 0, width: min(5, lit - x), height: size.height)), with: .color(Theme.signal))
                x += 7
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityValue(total > 0 ? "\(Int(value / total * 100)) percent" : "")
    }
}

/// A tag shown as a small square-cornered chip; the active one is filled with the signal colour.
struct TagChip: View {
    let text: String
    let active: Bool

    var body: some View {
        Text(text)
            .font(.sondrMono(size: 10.5))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .foregroundStyle(active ? Theme.onSignal : Theme.textMid)
            .background(active ? Theme.signal : Color.clear, in: RoundedRectangle(cornerRadius: 2))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(active ? Theme.signal : Theme.hairline, lineWidth: 1))
    }
}

/// The one filled button of a screen (Play): signal fill, dark glyph, 2 pt corners.
struct SignalButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 5)
            .foregroundStyle(Theme.onSignal)
            .background(Theme.signal.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 2))
            .opacity(isEnabled ? 1 : 0.4)
    }
}
