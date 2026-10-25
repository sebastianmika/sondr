import Foundation

/// One colour per cluster, the same in the sidebar, the table and the map. Built from the
/// `clusters` table (colours are `#RRGGBB`); unsorted samples and unknown ids are grey.
public struct ClusterPalette: Equatable, Sendable {
    public struct RGB: Equatable, Sendable {
        public let red: UInt8
        public let green: UInt8
        public let blue: UInt8

        public init(red: UInt8, green: UInt8, blue: UInt8) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// Reads `#RRGGBB` (the `#` is optional); nil for anything else.
        public init?(hex: String) {
            let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
            guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
            self.init(red: UInt8(value >> 16), green: UInt8((value >> 8) & 255), blue: UInt8(value & 255))
        }

        public var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
    }

    public static let unsorted = RGB(red: 142, green: 142, blue: 147)

    private let colours: [Int: RGB]

    /// - Parameter hex: `#RRGGBB` by cluster id; unreadable values become grey.
    public init(hex: [Int: String]) {
        colours = hex.mapValues { RGB(hex: $0) ?? Self.unsorted }
    }

    public init(_ clusters: [ClusterInfo]) {
        self.init(hex: Dictionary(clusters.map { ($0.id, $0.color) }, uniquingKeysWith: { first, _ in first }))
    }

    /// -1 (or any negative) and ids that are not in the table are unsorted.
    public func rgb(forCluster id: Int) -> RGB { colours[id] ?? Self.unsorted }

    /// Colours by `cluster + 1`, so index 0 is unsorted (-1); what ``MapRaster/render`` takes.
    public var denseTable: [RGB] {
        (-1...(colours.keys.max() ?? -1)).map { rgb(forCluster: $0) }
    }

    /// A colour for a new cluster: hues a golden angle apart stay distinct however many there are.
    public static func generatedHex(forCluster id: Int) -> String {
        let hue = (Double(id) * 0.381_966_011).truncatingRemainder(dividingBy: 1)
        let (saturation, value) = (0.72, 0.88)
        let sector = Int(hue * 6), fraction = hue * 6 - Double(sector)
        let (p, q, t) = (value * (1 - saturation), value * (1 - saturation * fraction), value * (1 - saturation * (1 - fraction)))
        let (r, g, b) = [(value, t, p), (q, value, p), (p, value, t), (p, q, value), (t, p, value), (value, p, q)][sector % 6]
        return RGB(red: UInt8(r * 255), green: UInt8(g * 255), blue: UInt8(b * 255)).hex
    }
}
