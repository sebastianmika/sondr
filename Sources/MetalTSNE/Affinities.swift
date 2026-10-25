import Foundation

/// Symmetric, sparse high-dimensional affinity matrix P in CSR layout, ready to
/// hand to the GPU attractive-force kernel.
struct SparseAffinities {
    var rowStart: [UInt32]   // count + 1
    var colIndex: [UInt32]   // nnz
    var values: [Float]      // nnz, already symmetrized and normalized so Σ = 1
}

enum Affinities {
    /// Per-point conditional probabilities p_{j|i} over each point's `k`
    /// neighbors, calibrated by binary search on beta = 1/(2σ²) so that each
    /// row's entropy matches log(perplexity). Rows sum to 1.
    ///
    /// - Parameters:
    ///   - neighborDist: squared distances, `count` × `k`, row-major.
    ///   - perplexity: target perplexity (≈ effective neighbor count).
    static func conditional(
        neighborDist: [Float],
        count n: Int,
        k: Int,
        perplexity: Double
    ) -> [Float] {
        let targetEntropy = log(perplexity)
        var condP = [Float](repeating: 0, count: n * k)

        condP.withUnsafeMutableBufferPointer { condBuf in
        // Each iteration writes a disjoint k-length slice, so concurrent writes
        // through this pointer do not overlap.
        nonisolated(unsafe) let condP = condBuf.baseAddress!
        DispatchQueue.concurrentPerform(iterations: n) { i in
            let base = i * k
            var beta = 1.0
            var lo = -Double.infinity
            var hi = Double.infinity
            var p = [Double](repeating: 0, count: k)

            for _ in 0..<60 {
                var sumP = 0.0
                var sumDP = 0.0
                for t in 0..<k {
                    let d = Double(neighborDist[base + t])
                    let val = exp(-beta * d)
                    p[t] = val
                    sumP += val
                    sumDP += d * val
                }
                if sumP < 1e-12 { sumP = 1e-12 }
                // Entropy H = log(sumP) + beta * <d>
                let entropy = log(sumP) + beta * sumDP / sumP
                let diff = entropy - targetEntropy
                if abs(diff) < 1e-5 { break }
                if diff > 0 {            // entropy too high → sharpen → larger beta
                    lo = beta
                    beta = hi.isInfinite ? beta * 2 : (beta + hi) / 2
                } else {
                    hi = beta
                    beta = lo.isInfinite ? beta / 2 : (beta + lo) / 2
                }
            }

            // Normalize to a conditional distribution.
            var sumP = 0.0
            for t in 0..<k {
                let val = exp(-beta * Double(neighborDist[base + t]))
                p[t] = val
                sumP += val
            }
            if sumP < 1e-12 { sumP = 1e-12 }
            for t in 0..<k { condP[base + t] = Float(p[t] / sumP) }
        }
        } // condP.withUnsafeMutableBufferPointer
        return condP
    }

    /// Builds the symmetric P used when fitting an embedding.
    ///
    /// - Parameters:
    ///   - neighborDist: squared distances, `count` × `k`, row-major.
    ///   - neighborIdx: neighbor indices, `count` × `k`, row-major.
    ///   - perplexity: target perplexity (≈ effective neighbor count).
    static func build(
        neighborDist: [Float],
        neighborIdx: [UInt32],
        count n: Int,
        k: Int,
        perplexity: Double
    ) -> SparseAffinities {
        // 1. Per-point conditional probabilities p_{j|i}.
        let condP = conditional(neighborDist: neighborDist, count: n, k: k, perplexity: perplexity)

        // 2. Symmetrize into CSR. P_ij = (p_{j|i} + p_{i|j}) / (2N). Rather than
        //    dedup with per-row dictionaries (slow), emit each directed edge a→b
        //    (value p_{b|a}/2N) into BOTH row a (col b) and row b (col a). Mutual
        //    edges thus produce two entries for the same (i,j) cell; the GPU
        //    attractive pass sums a row, so the duplicates add up to exactly
        //    P_ij — correct, and built with plain arrays in O(N·k).
        let inv2N = Float(1.0 / (2.0 * Double(n)))

        // 2a. Build an un-deduped CSR: each valid directed edge a→b drops a
        //     (col b) entry in row a and a (col a) entry in row b. Plain arrays,
        //     O(N·k), no dictionaries.
        var rawStart = [Int](repeating: 0, count: n + 1)
        for i in 0..<n {
            let base = i * k
            for t in 0..<k {
                let j = Int(neighborIdx[base + t])
                if j == i { continue }
                rawStart[i + 1] += 1
                rawStart[j + 1] += 1
            }
        }
        for i in 0..<n { rawStart[i + 1] += rawStart[i] }
        let rawCount = rawStart[n]
        var rawCol = [UInt32](repeating: 0, count: rawCount)
        var rawVal = [Float](repeating: 0, count: rawCount)
        var cursor = [Int](repeating: 0, count: n)
        for i in 0..<n { cursor[i] = rawStart[i] }
        for i in 0..<n {
            let base = i * k
            for t in 0..<k {
                let j = Int(neighborIdx[base + t])
                if j == i { continue }
                let v = condP[base + t] * inv2N
                let ci = cursor[i]; rawCol[ci] = UInt32(j); rawVal[ci] = v; cursor[i] = ci + 1
                let cj = cursor[j]; rawCol[cj] = UInt32(i); rawVal[cj] = v; cursor[j] = cj + 1
            }
        }

        // 2b. Dedup each row by sort-and-merge so the GPU attractive pass walks
        //     each (i,j) cell once. (Duplicates would otherwise inflate every
        //     iteration of optimization.) Rows are independent.
        var rowSize = [Int](repeating: 0, count: n)
        var pairs = [(UInt32, Float)]()
        for i in 0..<n {
            let s = rawStart[i], e = rawStart[i + 1]
            pairs.removeAll(keepingCapacity: true)
            for idx in s..<e { pairs.append((rawCol[idx], rawVal[idx])) }
            pairs.sort { $0.0 < $1.0 }
            var w = s, p = 0
            while p < pairs.count {
                let col = pairs[p].0
                var acc = pairs[p].1
                p += 1
                while p < pairs.count && pairs[p].0 == col { acc += pairs[p].1; p += 1 }
                rawCol[w] = col; rawVal[w] = acc; w += 1
            }
            rowSize[i] = w - s
        }

        // 2c. Compact the deduped rows into the final CSR.
        var rowStart = [UInt32](repeating: 0, count: n + 1)
        for i in 0..<n { rowStart[i + 1] = rowStart[i] + UInt32(rowSize[i]) }
        let nnz = Int(rowStart[n])
        var colIndex = [UInt32](repeating: 0, count: nnz)
        var values = [Float](repeating: 0, count: nnz)
        for i in 0..<n {
            let src = rawStart[i], dst = Int(rowStart[i])
            for t in 0..<rowSize[i] { colIndex[dst + t] = rawCol[src + t]; values[dst + t] = rawVal[src + t] }
        }
        return SparseAffinities(rowStart: rowStart, colIndex: colIndex, values: values)
    }
}
