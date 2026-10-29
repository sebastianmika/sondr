import Foundation

/// A perceptually even colour scale (viridis) for colouring the map by a dim.
public enum ColourRamp {
    private static let stops: [(Double, Double, Double)] = [
        (68, 1, 84), (72, 40, 120), (62, 74, 137), (49, 104, 142), (38, 130, 142),
        (31, 158, 137), (53, 183, 121), (110, 206, 88), (181, 222, 43), (253, 231, 37),
    ]

    /// `t` in 0...1, clipped.
    public static func colour(_ t: Double) -> ClusterPalette.RGB {
        let position = min(max(t, 0), 1) * Double(stops.count - 1)
        let lower = min(Int(position), stops.count - 2)
        let f = position - Double(lower)
        func mix(_ a: Double, _ b: Double) -> UInt8 { UInt8((a + (b - a) * f).rounded()) }
        let (a, b) = (stops[lower], stops[lower + 1])
        return ClusterPalette.RGB(red: mix(a.0, b.0), green: mix(a.1, b.1), blue: mix(a.2, b.2))
    }

    /// What ``MapRaster/render`` takes for ``MapDots/recoloured(by:)``: grey for unknown, then 256 steps.
    public static let table: [ClusterPalette.RGB] = [ClusterPalette.unsorted] + (0..<256).map { colour(Double($0) / 255) }
}
