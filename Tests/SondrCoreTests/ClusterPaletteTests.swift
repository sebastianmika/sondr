import Testing

@testable import SondrCore

@Test func paletteReadsHexFromTheClustersAndIsGreyForUnsortedAndUnknown() {
    let palette = ClusterPalette(hex: [0: "#FF8000", 3: "#00ff00", 4: "nonsense"])
    #expect(palette.rgb(forCluster: 0) == .init(red: 255, green: 128, blue: 0))
    #expect(palette.rgb(forCluster: 3) == .init(red: 0, green: 255, blue: 0))
    #expect(palette.rgb(forCluster: 4) == ClusterPalette.unsorted)
    #expect(palette.rgb(forCluster: -1) == ClusterPalette.unsorted)
    #expect(palette.rgb(forCluster: 99) == ClusterPalette.unsorted)
}

@Test func denseTableIsIndexedByClusterPlusOneWithGapsGrey() {
    let table = ClusterPalette(hex: [0: "#FF0000", 2: "#0000FF"]).denseTable
    #expect(table.count == 4)
    #expect(table[0] == ClusterPalette.unsorted)
    #expect(table[1] == .init(red: 255, green: 0, blue: 0))
    #expect(table[2] == ClusterPalette.unsorted)
    #expect(table[3] == .init(red: 0, green: 0, blue: 255))
    #expect(ClusterPalette(hex: [:]).denseTable == [ClusterPalette.unsorted])
}

@Test func hexRoundTripsAndRejectsGarbage() {
    #expect(ClusterPalette.RGB(hex: "#F28C28")?.hex == "#F28C28")
    #expect(ClusterPalette.RGB(hex: "F28C28")?.hex == "#F28C28")
    #expect(ClusterPalette.RGB(hex: "#F28C2") == nil)
    #expect(ClusterPalette.RGB(hex: "#GGGGGG") == nil)
}

@Test func generatedColoursForManyClustersStayDistinctAndReadable() {
    let hexes = (0..<30).map { ClusterPalette.generatedHex(forCluster: $0) }
    #expect(Set(hexes).count == 30)
    #expect(hexes.allSatisfy { ClusterPalette.RGB(hex: $0) != nil })
    #expect(!hexes.contains(ClusterPalette.unsorted.hex))
}
