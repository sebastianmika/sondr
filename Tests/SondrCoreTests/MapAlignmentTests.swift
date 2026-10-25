import Foundation
import Testing
import simd

@testable import SondrCore

private func scatter(_ count: Int, seed: UInt64 = 3) -> [SIMD2<Float>] {
    var state = seed | 1
    func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: state >> 11) % 20000 - 10000) / 10000
    }
    // Deliberately lopsided so rotations and flips are distinguishable.
    return (0..<count).map { _ in SIMD2(next() * 4, next()) }
}

private func transformed(_ points: [SIMD2<Float>], angle: Float, flip: Bool, scale: Float, shift: SIMD2<Float>) -> [SIMD2<Float>] {
    let (c, s) = (cos(angle), sin(angle))
    return points.map { p in
        let q = SIMD2(p.x, flip ? -p.y : p.y)
        return SIMD2(c * q.x - s * q.y, s * q.x + c * q.y) * scale + shift
    }
}

private func rms(_ a: [SIMD2<Float>], _ b: [SIMD2<Float>]) -> Float {
    (zip(a, b).reduce(0) { $0 + simd_distance_squared($1.0, $1.1) } / Float(a.count)).squareRoot()
}

@Test(arguments: [(0.7 as Float, false, 1 as Float), (2.5, true, 0.4), (-1.9, false, 3), (3.1, true, 1)])
func alignmentUndoesAnyRotationFlipScaleAndShift(angle: Float, flip: Bool, scale: Float) throws {
    let target = scatter(200)
    let moved = transformed(target, angle: angle, flip: flip, scale: scale, shift: SIMD2(5, -3))
    let transform = try #require(MapAlignment.transform(from: moved, to: target))
    #expect(rms(moved.map(transform.apply), target) < 1e-3)
}

@Test func alignmentUsesOnlyThePointsItIsGiven() throws {
    // Fit the transform on the first 100 points, check it on the others.
    let target = scatter(300)
    let moved = transformed(target, angle: 1.1, flip: true, scale: 2, shift: SIMD2(-2, 4))
    let transform = try #require(MapAlignment.transform(from: Array(moved.prefix(100)), to: Array(target.prefix(100))))
    #expect(rms(Array(moved.suffix(200)).map(transform.apply), Array(target.suffix(200))) < 1e-3)
}

@Test func alignmentOfNoisyCopiesStillGetsClose() throws {
    let target = scatter(400)
    var noisy = transformed(target, angle: -0.4, flip: false, scale: 1.5, shift: SIMD2(1, 1))
    for i in noisy.indices { noisy[i] += SIMD2(Float(i % 7) - 3, Float(i % 5) - 2) * 0.01 }
    let transform = try #require(MapAlignment.transform(from: noisy, to: target))
    #expect(rms(noisy.map(transform.apply), target) < 0.1)
}

@Test func alignmentDoesNotMakeTwoUnrelatedLayoutsWorse() throws {
    let a = scatter(300, seed: 1), b = scatter(300, seed: 2)
    let transform = try #require(MapAlignment.transform(from: a, to: b))
    #expect(rms(a.map(transform.apply), b) <= rms(a, b) + 1e-4)
}

@Test(arguments: [0, 1, 2])
func tooFewPointsGiveNoTransform(count: Int) {
    #expect(MapAlignment.transform(from: Array(scatter(5).prefix(count)), to: Array(scatter(5, seed: 9).prefix(count))) == nil)
}

@Test func identicalPointsOnTopOfEachOtherGiveNoTransform() {
    let same = [SIMD2<Float>](repeating: SIMD2(1, 1), count: 10)
    #expect(MapAlignment.transform(from: same, to: scatter(10)) == nil)
}

@Test func mismatchedLengthsGiveNoTransform() {
    #expect(MapAlignment.transform(from: scatter(10), to: scatter(11)) == nil)
}

@Test func identityTransformChangesNothing() {
    let points = scatter(20)
    #expect(points.map(MapAlignment.Transform.identity.apply) == points)
}
