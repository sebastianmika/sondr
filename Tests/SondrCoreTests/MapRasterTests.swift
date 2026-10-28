import Foundation
import Testing
import simd

@testable import SondrCore

// MARK: Palette

/// What the app builds from the seeded clusters table.
private let palette = ClusterPalette(
    hex: Dictionary(uniqueKeysWithValues: try! ClusterCentres.seed().map { ($0.id, $0.color) }))
private let colours = palette.denseTable

@Test func everySeededClusterHasItsOwnColourAndUnsortedIsGrey() {
    let own = (0..<14).map { palette.rgb(forCluster: $0) }
    for i in own.indices {
        for j in own.indices where j > i {
            let a = own[i], b = own[j]
            let distance = (pow(Double(a.red) - Double(b.red), 2) + pow(Double(a.green) - Double(b.green), 2)
                + pow(Double(a.blue) - Double(b.blue), 2)).squareRoot()
            #expect(distance > 70, "clusters \(i) and \(j) look alike")
        }
    }
    let unsorted = palette.rgb(forCluster: -1)
    #expect(unsorted.red == unsorted.green && abs(Int(unsorted.green) - Int(unsorted.blue)) < 12, "greyish")
    #expect(!own.contains(unsorted))
}

@Test func clusterIDsBeyondTheTableDrawAsUnsorted() {
    let buffer = MapRaster.render(
        MapDots(ids: [1], x: [0], y: [0], cluster: [50], fitted: [true]), colours: colours,
        viewport: MapViewport(centre: SIMD2(0, 0), scale: 10), width: 40, height: 40, highlight: nil, radius: 1)
    let i = (20 * 40 + 20) * 4
    let grey = ClusterPalette.unsorted
    #expect(abs(Int(buffer[i]) - Int(Double(grey.red) * Double(buffer[i + 3]) / 255)) <= 2)
}

// MARK: Viewport

private let size = SIMD2<Float>(400, 300)

@Test func viewportConvertsBetweenMapAndPixelsBothWays() {
    let viewport = MapViewport(centre: SIMD2(10, -5), scale: 20)
    #expect(viewport.toPixel(SIMD2(10, -5), size: size) == SIMD2(200, 150), "the centre is in the middle")
    for point in [SIMD2<Float>(0, 0), SIMD2(12.5, -7), SIMD2(-3, 4)] {
        let back = viewport.toMap(viewport.toPixel(point, size: size), size: size)
        #expect(simd_distance(back, point) < 1e-4)
    }
}

@Test func fittingShowsEveryPointWithAMarginAndKeepsTheAspectRatio() {
    let x: [Float] = [-50, 0, 50, 10], y: [Float] = [-5, 5, 0, 2]
    let viewport = MapViewport.fitting(x: x, y: y, size: size)
    for (px, py) in zip(x, y) {
        let p = viewport.toPixel(SIMD2(px, py), size: size)
        #expect(p.x > 0 && p.x < size.x && p.y > 0 && p.y < size.y)
    }
    #expect(viewport.centre == SIMD2(0, 0))
}

@Test func fittingIgnoresAFewFarOutliers() {
    var x = (0..<1000).map { Float($0 % 100) }, y = (0..<1000).map { Float($0 / 10) }
    x.append(1e6); y.append(1e6)
    let viewport = MapViewport.fitting(x: x, y: y, size: size)
    #expect(viewport.scale > 1, "the outlier did not squash everything into a point")
}

@Test func fittingEmptyOrSinglePointDataDoesNotBreak() {
    #expect(MapViewport.fitting(x: [], y: [], size: size).scale > 0)
    #expect(MapViewport.fitting(x: [3], y: [4], size: size).scale > 0)
}

@Test func zoomingKeepsThePointUnderTheCursorInPlace() {
    let viewport = MapViewport(centre: SIMD2(0, 0), scale: 10)
    let cursor = SIMD2<Float>(300, 80)
    let before = viewport.toMap(cursor, size: size)
    let zoomed = viewport.zoomed(by: 2.5, around: cursor, size: size)
    #expect(zoomed.scale == 25)
    #expect(simd_distance(zoomed.toMap(cursor, size: size), before) < 1e-4)
}

@Test func panningMovesTheMapWithTheDrag() {
    let viewport = MapViewport(centre: SIMD2(0, 0), scale: 10)
    let panned = viewport.panned(by: SIMD2(30, -20))
    let point = SIMD2<Float>(1, 1)
    #expect(panned.toPixel(point, size: size) == viewport.toPixel(point, size: size) + SIMD2(30, -20))
}

@Test func zoomIsLimited() {
    let viewport = MapViewport(centre: .zero, scale: 10)
    #expect(viewport.zoomed(by: 1e9, around: .zero, size: size).scale <= MapViewport.maxScale)
    #expect(viewport.zoomed(by: 1e-9, around: .zero, size: size).scale >= MapViewport.minScale)
}

// MARK: Raster

private func dots(_ points: [(Float, Float, Int)], ids: [Int64]? = nil) -> MapDots {
    MapDots(
        ids: ids ?? points.indices.map { Int64($0 + 1) }, x: points.map(\.0), y: points.map(\.1), cluster: points.map(\.2),
        fitted: [Bool](repeating: true, count: points.count))
}

private func pixel(_ buffer: [UInt8], _ x: Int, _ y: Int, width: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
    let i = (y * width + x) * 4
    return (buffer[i], buffer[i + 1], buffer[i + 2], buffer[i + 3])
}

private let unit = MapViewport(centre: SIMD2(0, 0), scale: 10)

@Test func aDotIsDrawnInItsClusterColourWhereTheViewportPutsIt() {
    let buffer = MapRaster.render(dots([(0, 0, 3)]), colours: colours, viewport: unit, width: 400, height: 300, highlight: nil, radius: 1)
    #expect(buffer.count == 400 * 300 * 4)
    let colour = palette.rgb(forCluster: 3)
    let p = pixel(buffer, 200, 150, width: 400)
    #expect(p.a > 150)
    // premultiplied: the colour channels are the colour times alpha
    #expect(abs(Int(p.r) - Int(Double(colour.red) * Double(p.a) / 255)) <= 2)
    #expect(abs(Int(p.g) - Int(Double(colour.green) * Double(p.a) / 255)) <= 2)
    #expect(pixel(buffer, 20, 20, width: 400).a == 0, "empty places stay transparent")
}

@Test func dotsOutsideTheViewAreSkipped() {
    let buffer = MapRaster.render(dots([(1000, 1000, 0), (-1000, 5, 1)]), colours: colours, viewport: unit, width: 100, height: 100, highlight: nil, radius: 2)
    #expect(buffer.allSatisfy { $0 == 0 })
}

@Test func unsortedDotsAreGrey() {
    let buffer = MapRaster.render(dots([(0, 0, -1)]), colours: colours, viewport: unit, width: 40, height: 40, highlight: nil, radius: 1)
    let p = pixel(buffer, 20, 20, width: 40)
    #expect(p.a > 0 && abs(Int(p.r) - Int(p.g)) <= 4 && abs(Int(p.g) - Int(p.b)) <= 12)
}

@Test func withAHighlightEverythingElseFadesOut() {
    let data = dots([(-5, 0, 0), (5, 0, 0)], ids: [10, 20])
    let buffer = MapRaster.render(data, colours: colours, viewport: unit, width: 400, height: 300, highlight: [20], radius: 1)
    let faded = pixel(buffer, 150, 150, width: 400), shown = pixel(buffer, 250, 150, width: 400)
    #expect(faded.a > 0 && shown.a > faded.a * 3, "faded \(faded.a) shown \(shown.a)")
}

@Test func anEmptyHighlightFadesEverything() {
    let buffer = MapRaster.render(dots([(0, 0, 0)]), colours: colours, viewport: unit, width: 40, height: 40, highlight: [], radius: 1)
    #expect(pixel(buffer, 20, 20, width: 40).a < 80)
}

@Test func overlappingDotsAddUpWithoutOverflowing() {
    let many = dots((0..<500).map { _ in (0, 0, 2) })
    let buffer = MapRaster.render(many, colours: colours, viewport: unit, width: 40, height: 40, highlight: nil, radius: 1)
    let p = pixel(buffer, 20, 20, width: 40)
    #expect(p.a == 255 || p.a >= 250)
    #expect(p.r <= p.a && p.g <= p.a && p.b <= p.a, "stays a valid premultiplied colour")
}

@Test func aBiggerRadiusPaintsMorePixels() {
    func painted(_ radius: Float) -> Int {
        let b = MapRaster.render(dots([(0, 0, 0)]), colours: colours, viewport: unit, width: 60, height: 60, highlight: nil, radius: radius)
        return stride(from: 3, to: b.count, by: 4).filter { b[$0] > 0 }.count
    }
    #expect(painted(1) >= 1)
    #expect(painted(3) > painted(1))
}

@Test func theDefaultRadiusShrinksAsTheMapFillsUp() {
    let sparse = MapRaster.defaultRadius(count: 500, width: 1200, height: 800)
    let dense = MapRaster.defaultRadius(count: 250_000, width: 1200, height: 800)
    #expect(sparse > dense && dense >= 1 && sparse <= 4)
}

// MARK: Hit testing

@Test func theNearestDotUnderTheCursorIsFound() {
    let data = dots([(0, 0, 0), (1, 0, 0), (5, 5, 0)])
    let at = { (x: Float, y: Float) in MapRaster.nearest(in: data, to: SIMD2(x, y), viewport: unit, size: size, maxDistance: 8) }
    #expect(at(200, 150) == 0)
    #expect(at(212, 150) == 1, "10 px per unit: dot 1 is at x = 210")
    #expect(at(205, 150) == 0 || at(205, 150) == 1)
    #expect(at(250, 200) == 2)
    #expect(at(100, 20) == nil, "nothing within reach")
}

@Test func hitTestingOnAnEmptyMapFindsNothing() {
    #expect(MapRaster.nearest(in: dots([]), to: SIMD2(1, 1), viewport: unit, size: size, maxDistance: 10) == nil)
}

@Test func aRectangleSelectsTheDotsInsideIt() {
    let data = dots([(-10, 0, 0), (0, 0, 0), (1, 1, 0), (9, 9, 0)])
    let inside = MapRaster.indices(in: data, rect: (min: SIMD2(190, 140), max: SIMD2(230, 170)), viewport: unit, size: size)
    #expect(inside == [1, 2])
    let reversed = MapRaster.indices(in: data, rect: (min: SIMD2(230, 170), max: SIMD2(190, 140)), viewport: unit, size: size)
    #expect(reversed == inside, "dragging up-left works too")
}

// MARK: Speed (reported, not gated)

@Test(.enabled(if: ProcessInfo.processInfo.environment["SONDR_BENCH"] != nil, "set SONDR_BENCH=1"))
func rasterOf250kDotsIsFast() {
    let count = 250_000
    var state: UInt64 = 5
    func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(state >> 40) / Float(1 << 24)
    }
    let data = MapDots(
        ids: (0..<count).map(Int64.init), x: (0..<count).map { _ in next() * 100 }, y: (0..<count).map { _ in next() * 60 },
        cluster: (0..<count).map { $0 % 9 - 1 }, fitted: [Bool](repeating: true, count: count))
    let viewport = MapViewport.fitting(x: data.x, y: data.y, size: SIMD2(2400, 1600))
    let clock = ContinuousClock()
    var buffer: [UInt8] = []
    let draw = clock.measure { buffer = MapRaster.render(data, colours: colours, viewport: viewport, width: 2400, height: 1600, highlight: nil, radius: nil) }
    let highlight = Set((0..<20_000).map(Int64.init))
    let drawHighlight = clock.measure { buffer = MapRaster.render(data, colours: colours, viewport: viewport, width: 2400, height: 1600, highlight: highlight, radius: nil) }
    let hit = clock.measure { _ = MapRaster.nearest(in: data, to: SIMD2(1200, 800), viewport: viewport, size: SIMD2(2400, 1600), maxDistance: 10) }
    print("raster 250k at 2400x1600: \(draw), with a 20k highlight: \(drawHighlight), hit test: \(hit); \(buffer.count) bytes")
}
