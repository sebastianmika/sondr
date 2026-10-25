import Testing

@testable import SondrCore

@Test func paletteHasEightDistinctHuesAndGreyForUnsorted() {
    let colours = (0..<8).map { ClusterPalette.rgb(forCluster: $0) }
    #expect(Set(colours.map { [$0.red, $0.green, $0.blue] }).count == 8)
    #expect(!colours.contains(ClusterPalette.unsorted))
    #expect(ClusterPalette.rgb(forCluster: -1) == ClusterPalette.unsorted)
    #expect(ClusterPalette.rgb(forCluster: 8) == colours[0])
}
