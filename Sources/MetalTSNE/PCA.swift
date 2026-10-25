import Foundation
import Accelerate

/// Principal Component Analysis used for (a) optionally reducing the input
/// dimensionality before the neighbor search and (b) producing a stable
/// initial 2-D layout.
///
/// We avoid LAPACK eigensolvers (awkward to call portably from Swift) and
/// instead use block power ("subspace") iteration on the D×D covariance matrix,
/// driven by Accelerate's BLAS. For the modest component counts t-SNE needs
/// (≤~50) this converges in a handful of iterations and is plenty accurate —
/// PCA here is a preprocessing aid, not the final analysis.
/// A fitted PCA projection: the training column means plus the top principal
/// directions. Retained by ``TSNEModel`` so that new points can be mapped into
/// exactly the same working space as the points the embedding was fitted on.
struct PCABasis: Sendable {
    /// Column means of the training data (`dim` entries).
    let mean: [Float]
    /// Principal directions, row-major `dim` × `components`; column *j* is the
    /// *j*-th direction, ordered by descending eigenvalue.
    let components: [Float]
    let dim: Int
    let componentCount: Int

    /// Projects `data` (row-major, `count` × `dim`) into the basis. Returns a
    /// row-major `count` × `componentCount` array.
    func project(data: [Float], count n: Int) -> [Float] {
        precondition(data.count == n * dim, "data must be count × dim")
        let k = componentCount
        var result = [Float](repeating: 0, count: n * k)
        data.withUnsafeBufferPointer { xp in
            components.withUnsafeBufferPointer { qp in
                mean.withUnsafeBufferPointer { mp in
                    var centered = [Float](repeating: 0, count: dim)
                    for i in 0..<n {
                        let row = xp.baseAddress! + i * dim
                        for c in 0..<dim { centered[c] = row[c] - mp[c] }
                        for j in 0..<k {
                            var acc: Float = 0
                            for c in 0..<dim { acc += centered[c] * qp[c * k + j] }
                            result[i * k + j] = acc
                        }
                    }
                }
            }
        }
        return result
    }
}

enum PCA {
    /// Projects `data` (row-major, `count` × `dim`) onto its top `components`
    /// principal directions. Returns a row-major `count` × `components` array.
    /// The input is mean-centered internally; the original is not modified.
    static func project(
        data: [Float],
        count n: Int,
        dim d: Int,
        components k: Int,
        iterations: Int = 24,
        seed: UInt64 = 42
    ) -> [Float] {
        fit(data: data, count: n, dim: d, components: k,
            iterations: iterations, seed: seed).projected
    }

    /// Same as ``project(data:count:dim:components:iterations:seed:)`` but also
    /// returns the fitted ``PCABasis``, so the identical projection can later be
    /// applied to out-of-sample points.
    static func fit(
        data: [Float],
        count n: Int,
        dim d: Int,
        components k: Int,
        iterations: Int = 24,
        seed: UInt64 = 42
    ) -> (projected: [Float], basis: PCABasis) {
        precondition(k <= d, "components must not exceed dimensionality")

        // 1. Mean-center a working copy (column means).
        var x = data
        var mean = [Float](repeating: 0, count: d)
        x.withUnsafeBufferPointer { xp in
            for i in 0..<n {
                let row = xp.baseAddress! + i * d
                cblas_saxpy(Int32(d), 1.0, row, 1, &mean, 1)
            }
        }
        let invN = Float(1.0 / Double(n))
        cblas_sscal(Int32(d), invN, &mean, 1)
        x.withUnsafeMutableBufferPointer { xp in
            for i in 0..<n {
                let row = xp.baseAddress! + i * d
                cblas_saxpy(Int32(d), -1.0, mean, 1, row, 1)
            }
        }

        // 2. Covariance C = Xᵀ X  (D×D, row-major). Scale irrelevant for vectors.
        var cov = [Float](repeating: 0, count: d * d)
        x.withUnsafeBufferPointer { xp in
            cblas_sgemm(
                CblasRowMajor, CblasTrans, CblasNoTrans,
                Int32(d), Int32(d), Int32(n),
                1.0, xp.baseAddress!, Int32(d),
                xp.baseAddress!, Int32(d),
                0.0, &cov, Int32(d))
        }

        // 3. Subspace iteration: Q ← orthonormalize(C · Q).
        var rng = SplitMix64(seed: seed)
        var q = [Float](repeating: 0, count: d * k) // row-major D×k, columns are vectors
        for idx in 0..<(d * k) { q[idx] = Float(rng.nextUnit() * 2 - 1) }
        orthonormalizeColumns(&q, rows: d, cols: k)

        var z = [Float](repeating: 0, count: d * k)
        for _ in 0..<iterations {
            cov.withUnsafeBufferPointer { cp in
                q.withUnsafeBufferPointer { qp in
                    z.withUnsafeMutableBufferPointer { zp in
                        cblas_sgemm(
                            CblasRowMajor, CblasNoTrans, CblasNoTrans,
                            Int32(d), Int32(k), Int32(d),
                            1.0, cp.baseAddress!, Int32(d),
                            qp.baseAddress!, Int32(k),
                            0.0, zp.baseAddress!, Int32(k))
                    }
                }
            }
            swap(&q, &z)
            orthonormalizeColumns(&q, rows: d, cols: k)
        }

        // 4. Order components by eigenvalue (Rayleigh quotient λⱼ = qⱼᵀ C qⱼ).
        var eigvals = [Float](repeating: 0, count: k)
        cov.withUnsafeBufferPointer { cp in
            for j in 0..<k {
                var cq = [Float](repeating: 0, count: d)
                for r in 0..<d {
                    var acc: Float = 0
                    let crow = cp.baseAddress! + r * d
                    for c in 0..<d { acc += crow[c] * q[c * k + j] }
                    cq[r] = acc
                }
                var lam: Float = 0
                for r in 0..<d { lam += q[r * k + j] * cq[r] }
                eigvals[j] = lam
            }
        }
        let order = (0..<k).sorted { eigvals[$0] > eigvals[$1] }

        // 5. Materialize the basis with its columns in eigenvalue order, so the
        //    same projection can be replayed on out-of-sample points.
        var ordered = [Float](repeating: 0, count: d * k)
        for (outCol, srcCol) in order.enumerated() {
            for r in 0..<d { ordered[r * k + outCol] = q[r * k + srcCol] }
        }
        let basis = PCABasis(mean: mean, components: ordered, dim: d, componentCount: k)

        // 6. Project: Y = X_centered · Q. `x` is already centered in place, so
        //    this is a plain multiply.
        var result = [Float](repeating: 0, count: n * k)
        x.withUnsafeBufferPointer { xp in
            ordered.withUnsafeBufferPointer { qp in
                for i in 0..<n {
                    let row = xp.baseAddress! + i * d
                    for j in 0..<k {
                        var acc: Float = 0
                        for c in 0..<d { acc += row[c] * qp[c * k + j] }
                        result[i * k + j] = acc
                    }
                }
            }
        }
        return (result, basis)
    }

    /// Modified Gram-Schmidt orthonormalization of the columns of a row-major
    /// `rows`×`cols` matrix, in place.
    private static func orthonormalizeColumns(_ m: inout [Float], rows: Int, cols: Int) {
        for j in 0..<cols {
            // Subtract projections onto earlier columns.
            for p in 0..<j {
                var dot: Float = 0
                for r in 0..<rows { dot += m[r * cols + j] * m[r * cols + p] }
                for r in 0..<rows { m[r * cols + j] -= dot * m[r * cols + p] }
            }
            // Normalize.
            var norm: Float = 0
            for r in 0..<rows { let v = m[r * cols + j]; norm += v * v }
            norm = sqrt(max(norm, 1e-20))
            let inv = 1.0 / norm
            for r in 0..<rows { m[r * cols + j] *= inv }
        }
    }
}

/// Small, fast, reproducible PRNG (SplitMix64) used for initialization.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform Double in [0, 1).
    mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }

    /// Standard-normal Float via Box-Muller.
    mutating func nextGaussian() -> Float {
        let u1 = max(nextUnit(), 1e-12)
        let u2 = nextUnit()
        return Float(sqrt(-2.0 * log(u1)) * cos(2.0 * Double.pi * u2))
    }
}
