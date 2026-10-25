/// One colour per cluster, the same in the sidebar and on the map. Eight hues that differ clearly
/// from each other; unsorted samples are grey.
public enum ClusterPalette {
    public struct RGB: Equatable, Sendable {
        public let red: UInt8
        public let green: UInt8
        public let blue: UInt8
    }

    private static let colours: [RGB] = [
        RGB(red: 242, green: 140, blue: 40),  // kicks: orange
        RGB(red: 229, green: 72, blue: 77),  // snares: red
        RGB(red: 31, green: 166, blue: 201),  // hats/perc: cyan
        RGB(red: 47, green: 180, blue: 87),  // bass: green
        RGB(red: 155, green: 93, blue: 229),  // pads: purple
        RGB(red: 195, green: 204, blue: 43),  // leads: yellow-green
        RGB(red: 214, green: 60, blue: 190),  // vox chops: magenta
        RGB(red: 79, green: 107, blue: 216),  // fx/risers: blue
    ]

    public static let unsorted = RGB(red: 142, green: 142, blue: 147)

    /// -1 (or any negative) is unsorted; ids beyond the catalog wrap around.
    public static func rgb(forCluster id: Int) -> RGB {
        id < 0 ? unsorted : colours[id % colours.count]
    }
}
