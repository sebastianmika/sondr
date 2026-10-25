import Foundation
import simd

/// Finds the rotation, flip, scale and shift that bring one 2D layout as close as possible to another
/// (orthogonal Procrustes with scale). A new fit of the same data is spun differently every time;
/// aligning it to the current map keeps the picture familiar and makes comparing the two meaningful.
public enum MapAlignment {
    /// `point -> matrix * point + shift`.
    public struct Transform: Equatable, Sendable {
        public var matrix: simd_double2x2
        public var shift: SIMD2<Double>

        public static let identity = Transform(matrix: matrix_identity_double2x2, shift: .zero)

        public func apply(_ point: SIMD2<Float>) -> SIMD2<Float> {
            SIMD2<Float>(matrix * SIMD2<Double>(point) + shift)
        }
    }

    /// The transform that maps `source` closest onto `target`, point by point.
    ///
    /// - Returns: nil if there are fewer than 3 pairs, the lengths differ, or the points have no extent.
    public static func transform(from source: [SIMD2<Float>], to target: [SIMD2<Float>]) -> Transform? {
        guard source.count == target.count, source.count >= 3 else { return nil }
        let n = Double(source.count)
        let meanSource = source.reduce(SIMD2<Double>.zero) { $0 + SIMD2<Double>($1) } / n
        let meanTarget = target.reduce(SIMD2<Double>.zero) { $0 + SIMD2<Double>($1) } / n
        let x = source.map { SIMD2<Double>($0) - meanSource }
        let t = target.map { SIMD2<Double>($0) - meanTarget }
        let energy = x.reduce(0) { $0 + simd_length_squared($1) }
        guard energy > 1e-12 else { return nil }

        var best: (error: Double, matrix: simd_double2x2)?
        for flip in [1.0, -1.0] {
            let q = x.map { SIMD2($0.x, $0.y * flip) }
            var cross = 0.0, dot = 0.0
            for (a, b) in zip(q, t) {
                cross += a.x * b.y - a.y * b.x
                dot += a.x * b.x + a.y * b.y
            }
            let angle = atan2(cross, dot)
            let (c, s) = (cos(angle), sin(angle))
            let rotation = simd_double2x2(columns: (SIMD2(c, s), SIMD2(-s, c)))
            let fit = zip(q, t).reduce(0) { $0 + simd_dot($1.1, rotation * $1.0) }
            let scale = fit / energy
            let matrix = scale * rotation * simd_double2x2(columns: (SIMD2(1, 0), SIMD2(0, flip)))
            let error = zip(x, t).reduce(0) { $0 + simd_length_squared(matrix * $1.0 - $1.1) }
            if error < (best?.error ?? .infinity) { best = (error, matrix) }
        }
        guard let best else { return nil }
        return Transform(matrix: best.matrix, shift: meanTarget - best.matrix * meanSource)
    }
}
