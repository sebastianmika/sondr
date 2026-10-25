import Foundation
import Testing
import simd
@testable import MetalTSNE

/// Generates `perCluster` points around each of `clusters` separated centers
/// in `dim` dimensions.
private func blobs(clusters: Int, perCluster: Int, dim: Int, seed: UInt64)
    -> (data: [[Float]], labels: [Int])
{
    var rng = SplitMix64(seed: seed)
    var centers: [[Float]] = []
    for _ in 0..<clusters {
        centers.append((0..<dim).map { _ in Float(rng.nextUnit() * 2 - 1) * 8 })
    }
    var data: [[Float]] = []
    var labels: [Int] = []
    for c in 0..<clusters {
        for _ in 0..<perCluster {
            var v = centers[c]
            for d in 0..<dim { v[d] += rng.nextGaussian() }
            data.append(v)
            labels.append(c)
        }
    }
    return (data, labels)
}

/// Ratio of mean between-centroid distance to mean within-cluster distance in
/// the embedding. Large ⇒ well-separated clusters.
private func separationRatio(_ pts: [SIMD2<Float>], _ labels: [Int], clusters: Int) -> Float {
    var centroids = [SIMD2<Float>](repeating: .zero, count: clusters)
    var counts = [Float](repeating: 0, count: clusters)
    for (i, p) in pts.enumerated() { centroids[labels[i]] += p; counts[labels[i]] += 1 }
    for c in 0..<clusters { centroids[c] /= counts[c] }
    var within: Float = 0
    for (i, p) in pts.enumerated() { within += simd_distance(p, centroids[labels[i]]) }
    within /= Float(pts.count)
    var between: Float = 0, pairs: Float = 0
    for a in 0..<clusters { for b in (a + 1)..<clusters {
        between += simd_distance(centroids[a], centroids[b]); pairs += 1
    } }
    return (between / pairs) / max(within, 1e-6)
}

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"))
func fieldOptimizerSeparatesClusters() throws {
    // The linear-time field optimizer must produce equally clean clusters.
    let (data, labels) = blobs(clusters: 5, perCluster: 200, dim: 20, seed: 11)
    var params = TSNEParameters()
    params.iterations = 600
    params.perplexity = 30
    params.neighborCount = 90
    params.pcaDimensions = nil
    params.optimizer = .field      // force the field backend regardless of size
    let tsne = try TSNE(parameters: params)
    let pts = try tsne.embed(data: data)

    #expect(pts.count == data.count)
    #expect(pts.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    #expect(tsne.statistics.usedFieldOptimizer)
    #expect(separationRatio(pts, labels, clusters: 5) > 4)
}

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"))
func embedsSeparableClusters() throws {
    let (data, labels) = blobs(clusters: 4, perCluster: 150, dim: 20, seed: 7)
    var params = TSNEParameters()
    params.iterations = 500
    params.perplexity = 30
    params.neighborCount = 90
    params.pcaDimensions = nil
    let tsne = try TSNE(parameters: params)
    let pts = try tsne.embed(data: data)

    #expect(pts.count == data.count)
    #expect(pts.allSatisfy { $0.x.isFinite && $0.y.isFinite })

    // Cluster quality: mean within-cluster distance should be far smaller than
    // the mean between-centroid distance in the 2-D embedding.
    var centroids = [SIMD2<Float>](repeating: .zero, count: 4)
    var counts = [Float](repeating: 0, count: 4)
    for (i, p) in pts.enumerated() { centroids[labels[i]] += p; counts[labels[i]] += 1 }
    for c in 0..<4 { centroids[c] /= counts[c] }

    var within: Float = 0
    for (i, p) in pts.enumerated() { within += simd_distance(p, centroids[labels[i]]) }
    within /= Float(pts.count)

    var between: Float = 0; var pairs: Float = 0
    for a in 0..<4 { for b in (a + 1)..<4 { between += simd_distance(centroids[a], centroids[b]); pairs += 1 } }
    between /= pairs

    // Well-separated clusters: between-centroid spread dwarfs within-cluster scatter.
    #expect(between > within * 4)
}

// MARK: - Out-of-sample transform

/// Splits `data` into a training set and every `stride`-th point held out.
private func holdOut(_ data: [[Float]], _ labels: [Int], stride: Int)
    -> (train: [[Float]], trainLabels: [Int], test: [[Float]], testLabels: [Int])
{
    var train: [[Float]] = [], trainLabels: [Int] = []
    var test: [[Float]] = [], testLabels: [Int] = []
    for (i, v) in data.enumerated() {
        if i % stride == 0 { test.append(v); testLabels.append(labels[i]) }
        else { train.append(v); trainLabels.append(labels[i]) }
    }
    return (train, trainLabels, test, testLabels)
}

/// Index of the reference point nearest `p`.
private func nearestReference(_ p: SIMD2<Float>, _ reference: [SIMD2<Float>]) -> Int {
    var best = 0, bestD = Float.greatestFiniteMagnitude
    for (j, r) in reference.enumerated() {
        let d = simd_distance_squared(p, r)
        if d < bestD { bestD = d; best = j }
    }
    return best
}

/// Fraction of transformed points whose nearest reference point shares their label.
private func neighborAgreement(
    placed: [SIMD2<Float>], placedLabels: [Int],
    reference: [SIMD2<Float>], referenceLabels: [Int]
) -> Double {
    var correct = 0
    for (i, p) in placed.enumerated() {
        if referenceLabels[nearestReference(p, reference)] == placedLabels[i] { correct += 1 }
    }
    return Double(correct) / Double(max(1, placed.count))
}

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"))
func transformPlacesHeldOutPointsWithTheirCluster() throws {
    let (data, labels) = blobs(clusters: 5, perCluster: 240, dim: 20, seed: 21)
    let split = holdOut(data, labels, stride: 6)

    var params = TSNEParameters()
    params.iterations = 500
    params.pcaDimensions = nil
    let tsne = try TSNE(parameters: params)
    let model = try tsne.fit(data: split.train)
    let placed = try model.transform(data: split.test)

    #expect(placed.count == split.test.count)
    #expect(placed.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    let agreement = neighborAgreement(placed: placed, placedLabels: split.testLabels,
                                      reference: model.embedding, referenceLabels: split.trainLabels)
    #expect(agreement > 0.95)
}

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"))
func transformReproducesTrainingPositions() throws {
    // Re-transforming points the model was fitted on should land them close to
    // where the fit itself put them.
    let (data, labels) = blobs(clusters: 4, perCluster: 150, dim: 16, seed: 4)
    var params = TSNEParameters()
    params.iterations = 500
    params.pcaDimensions = nil
    let tsne = try TSNE(parameters: params)
    let model = try tsne.fit(data: data)

    let sample = stride(from: 0, to: data.count, by: 7).map { data[$0] }
    let expected = stride(from: 0, to: data.count, by: 7).map { model.embedding[$0] }
    let placed = try model.transform(data: sample)

    // Scale the tolerance by the spread of the map: displacement should be small
    // compared with the distance between clusters.
    var centroids = [SIMD2<Float>](repeating: .zero, count: 4)
    var counts = [Float](repeating: 0, count: 4)
    for (i, p) in model.embedding.enumerated() { centroids[labels[i]] += p; counts[labels[i]] += 1 }
    for c in 0..<4 { centroids[c] /= counts[c] }
    var between: Float = 0, pairs: Float = 0
    for a in 0..<4 { for b in (a + 1)..<4 { between += simd_distance(centroids[a], centroids[b]); pairs += 1 } }
    between /= pairs

    var displacement: Float = 0
    for i in 0..<placed.count { displacement += simd_distance(placed[i], expected[i]) }
    displacement /= Float(placed.count)
    #expect(displacement < between * 0.2)
}

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"))
func transformIsIndependentOfBatchComposition() throws {
    // New points exert no force on each other, so a point must land in the same
    // spot alone as it does inside a batch.
    let (data, labels) = blobs(clusters: 4, perCluster: 120, dim: 12, seed: 9)
    let split = holdOut(data, labels, stride: 5)

    var params = TSNEParameters()
    params.iterations = 400
    params.pcaDimensions = nil
    let tsne = try TSNE(parameters: params)
    let model = try tsne.fit(data: split.train)

    let batch = try model.transform(data: split.test)
    let solo = try model.transform(data: [split.test[3]])
    #expect(simd_distance(solo[0], batch[3]) < 1e-3)

    // …and repeating the same call gives the same answer.
    let again = try model.transform(data: split.test)
    #expect(zip(batch, again).allSatisfy { simd_distance($0, $1) < 1e-5 })
}

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"))
func transformFieldBackendMatchesExact() throws {
    let (data, labels) = blobs(clusters: 5, perCluster: 200, dim: 16, seed: 33)
    let split = holdOut(data, labels, stride: 8)

    var params = TSNEParameters()
    params.iterations = 500
    params.pcaDimensions = nil
    let tsne = try TSNE(parameters: params)
    let model = try tsne.fit(data: split.train)

    var exact = TSNETransformParameters(); exact.optimizer = .exact
    var field = TSNETransformParameters(); field.optimizer = .field
    let placedExact = try model.transform(data: split.test, parameters: exact)
    #expect(!model.transformStatistics.usedFieldOptimizer)
    let placedField = try model.transform(data: split.test, parameters: field)
    #expect(model.transformStatistics.usedFieldOptimizer)

    let exactAgreement = neighborAgreement(placed: placedExact, placedLabels: split.testLabels,
                                           reference: model.embedding, referenceLabels: split.trainLabels)
    let fieldAgreement = neighborAgreement(placed: placedField, placedLabels: split.testLabels,
                                           reference: model.embedding, referenceLabels: split.trainLabels)
    #expect(exactAgreement > 0.95)
    #expect(fieldAgreement > 0.95)
}

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"))
func transformProjectsThroughTheFittedPCA() throws {
    // With PCA enabled the new points must go through the *training* basis, not
    // a basis refitted on themselves.
    let (data, labels) = blobs(clusters: 4, perCluster: 150, dim: 64, seed: 17)
    let split = holdOut(data, labels, stride: 6)

    var params = TSNEParameters()
    params.iterations = 400
    params.pcaDimensions = 20
    let tsne = try TSNE(parameters: params)
    let model = try tsne.fit(data: split.train)
    // A handful of new points from a single cluster: refitting PCA on this batch
    // would give a completely different subspace.
    let oneCluster = zip(split.test, split.testLabels).filter { $0.1 == 2 }.map { $0.0 }
    let placed = try model.transform(data: Array(oneCluster.prefix(20)))

    let agreement = neighborAgreement(placed: placed,
                                      placedLabels: [Int](repeating: 2, count: placed.count),
                                      reference: model.embedding, referenceLabels: split.trainLabels)
    #expect(agreement > 0.95)
}

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"))
func transformKeepsOutOfDistributionPointsOnTheMap() throws {
    // A point unlike anything in the reference set must still land somewhere
    // sane: finite, and within the span of the existing map rather than flung
    // off to infinity by the repulsive field.
    let (data, _) = blobs(clusters: 4, perCluster: 120, dim: 16, seed: 63)
    var params = TSNEParameters()
    params.iterations = 400
    params.pcaDimensions = nil
    let model = try TSNE(parameters: params).fit(data: data)

    var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
    var hi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
    for p in model.embedding { lo = simd_min(lo, p); hi = simd_max(hi, p) }
    let span = hi - lo

    var rng = SplitMix64(seed: 999)
    let outliers = (0..<10).map { _ in (0..<16).map { _ in Float(rng.nextUnit() * 2 - 1) * 60 } }
    let placed = try model.transform(data: outliers)

    #expect(placed.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    // Allow a margin of one map-width outside the reference bounds.
    #expect(placed.allSatisfy {
        $0.x > lo.x - span.x && $0.x < hi.x + span.x &&
        $0.y > lo.y - span.y && $0.y < hi.y + span.y
    })
}

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"))
func fitAndEmbedAgree() throws {
    // `embed` is now a thin wrapper over `fit`; the refactor must not have
    // changed what it returns.
    let (data, _) = blobs(clusters: 3, perCluster: 80, dim: 10, seed: 2)
    var params = TSNEParameters()
    params.iterations = 200
    params.pcaDimensions = nil

    let a = try TSNE(parameters: params).embed(data: data)
    let b = try TSNE(parameters: params).fit(data: data).embedding
    #expect(a.count == b.count)
    #expect(zip(a, b).allSatisfy { simd_distance($0, $1) < 1e-4 })
}

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"))
func transformValidatesInput() throws {
    let (data, _) = blobs(clusters: 2, perCluster: 60, dim: 8, seed: 1)
    var params = TSNEParameters()
    params.iterations = 100
    params.pcaDimensions = nil
    let model = try TSNE(parameters: params).fit(data: data)

    #expect(try model.transform(data: []).isEmpty)
    #expect(throws: TSNEError.self) {
        try model.transform(data: [[Float](repeating: 0, count: 3)])
    }
}

// MARK: - Non-iterative projection

/// Mean recall@K of a placement: the fraction of each new point's K nearest
/// neighbors *in the input space* that are also among its K nearest reference
/// points *in the map*. This is the metric out-of-sample t-SNE is actually
/// judged on — t-SNE exists to preserve local neighborhoods.
private func neighborRecall(
    placed: [SIMD2<Float>], test: [[Float]],
    reference: [SIMD2<Float>], train: [[Float]], k: Int
) -> Double {
    func topK<T>(_ items: [T], _ dist: (T) -> Float) -> Set<Int> {
        var scored = [(index: Int, d: Float)]()
        scored.reserveCapacity(items.count)
        for (i, item) in items.enumerated() { scored.append((i, dist(item))) }
        scored.sort { $0.d < $1.d }
        return Set(scored.prefix(k).map { $0.index })
    }
    var total = 0.0
    for (i, q) in test.enumerated() {
        let latent = topK(train) { r in
            var d: Float = 0
            for c in 0..<q.count { let df = q[c] - r[c]; d += df * df }
            return d
        }
        let mapped = topK(reference) { simd_distance_squared(placed[i], $0) }
        total += Double(latent.intersection(mapped).count) / Double(k)
    }
    return total / Double(max(1, test.count))
}

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"))
func projectPlacesHeldOutPointsWithTheirCluster() throws {
    let (data, labels) = blobs(clusters: 5, perCluster: 240, dim: 20, seed: 21)
    let split = holdOut(data, labels, stride: 6)

    var params = TSNEParameters()
    params.iterations = 500
    params.pcaDimensions = nil
    let model = try TSNE(parameters: params).fit(data: split.train)
    let placed = try model.project(data: split.test)

    #expect(placed.count == split.test.count)
    #expect(placed.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    let agreement = neighborAgreement(placed: placed, placedLabels: split.testLabels,
                                      reference: model.embedding, referenceLabels: split.trainLabels)
    #expect(agreement > 0.95)

    let stats = model.projectionStatistics
    #expect(stats.pointCount == split.test.count)
    #expect(stats.referenceCount == split.train.count)
    #expect(stats.neighborCount == 8)
}

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"))
func projectPreservesNeighborhoodsAsWellAsTheOptimizer() throws {
    // The whole point of the non-iterative path: near-parity on recall@5 at a
    // fraction of the work. On the validation suite it averaged 1.09x the
    // optimizer's recall; here we only assert it is not materially worse.
    let (data, labels) = blobs(clusters: 6, perCluster: 200, dim: 16, seed: 77)
    let split = holdOut(data, labels, stride: 7)

    var params = TSNEParameters()
    params.iterations = 500
    params.pcaDimensions = nil
    let model = try TSNE(parameters: params).fit(data: split.train)

    let projected = try model.project(data: split.test)
    let transformed = try model.transform(data: split.test)

    let rProject = neighborRecall(placed: projected, test: split.test,
                                  reference: model.embedding, train: split.train, k: 5)
    let rTransform = neighborRecall(placed: transformed, test: split.test,
                                    reference: model.embedding, train: split.train, k: 5)
    #expect(rProject > 0.2)
    #expect(rProject > rTransform * 0.9)
}

/// A swiss roll embedded in `dim` dimensions — continuous structure with no
/// cluster gaps, the topology the projector's adaptive bandwidth has to handle
/// by behaving like a mean rather than a mode.
private func swissRoll(count: Int, dim: Int, seed: UInt64) -> [[Float]] {
    var rng = SplitMix64(seed: seed)
    var basis: [[Float]] = []
    for _ in 0..<3 { basis.append((0..<dim).map { _ in Float(rng.nextGaussian()) }) }
    var out: [[Float]] = []
    for _ in 0..<count {
        let t = Float(1.5 * Double.pi * (1 + 2 * rng.nextUnit()))
        let h = Float(21 * rng.nextUnit())
        let coords = [t * cos(t), h, t * sin(t)]
        var v = [Float](repeating: 0, count: dim)
        for (c, w) in coords.enumerated() {
            for d in 0..<dim { v[d] += w * basis[c][d] }
        }
        for d in 0..<dim { v[d] += Float(rng.nextGaussian()) * 0.05 }
        out.append(v)
    }
    return out
}

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"))
func projectHoldsUpOnContinuousStructure() throws {
    // The hard case for a mode-seeker: a manifold with no gaps, where averaging
    // is the right behavior. The bandwidth is what makes the same call adapt.
    let data = swissRoll(count: 3000, dim: 32, seed: 101)
    let labels = [Int](repeating: 0, count: data.count)
    let split = holdOut(data, labels, stride: 10)

    var params = TSNEParameters()
    params.iterations = 500
    params.pcaDimensions = nil
    let model = try TSNE(parameters: params).fit(data: split.train)

    let projected = try model.project(data: split.test)
    let transformed = try model.transform(data: split.test)

    for k in [3, 5, 15] {
        let rp = neighborRecall(placed: projected, test: split.test,
                                reference: model.embedding, train: split.train, k: k)
        let rt = neighborRecall(placed: transformed, test: split.test,
                                reference: model.embedding, train: split.train, k: k)
        print(String(format: "swiss roll recall@%d: project %.3f  transform %.3f  (%.2fx)",
                     k, rp, rt, rp / max(1e-9, rt)))
        #expect(rp > rt * 0.9)
    }
}

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"))
func projectMatchesCPUReferenceObjective() throws {
    // The GPU mode-seek must reach a point that is no worse, under the Cauchy
    // objective it claims to minimize, than an independent CPU implementation of
    // the same multi-start fixed point.
    let (data, labels) = blobs(clusters: 4, perCluster: 100, dim: 12, seed: 41)
    let split = holdOut(data, labels, stride: 9)

    var params = TSNEParameters()
    params.iterations = 400
    params.pcaDimensions = nil
    let model = try TSNE(parameters: params).fit(data: split.train)

    var pp = TSNEProjectionParameters()
    pp.neighborCount = 8
    let placed = try model.project(data: split.test, parameters: pp)

    let k = pp.neighborCount
    let scales = try model.localScales(neighbor: pp.localScaleNeighbor)
    let flat = split.test.flatMap { $0 }
    let (d2, idx) = try model.queryKNN(queries: flat, queryCount: split.test.count, k: k)

    var w = (1...k).map { 1.0 / Double($0) }
    let wsum = w.reduce(0, +)
    for i in 0..<k { w[i] /= wsum }

    func objective(_ y: SIMD2<Double>, _ nb: [SIMD2<Double>], _ h2: Double) -> Double {
        var j = 0.0
        for i in 0..<nb.count {
            let dv = y - nb[i]
            let r2: Double = (dv.x * dv.x + dv.y * dv.y) / h2
            j += w[i] * log1p(r2)
        }
        return j
    }

    var worseCount = 0
    for q in 0..<split.test.count {
        // Rank-order this query's neighbors, as the kernel does.
        let order = (0..<k).sorted { d2[q * k + $0] < d2[q * k + $1] }
        let nb = order.map { t -> SIMD2<Double> in
            let p = model.embedding[Int(idx[q * k + t])]
            return SIMD2(Double(p.x), Double(p.y))
        }
        let h = pp.bandwidthScale * Double(scales[Int(idx[q * k + order[0]])])
        let h2 = max(h * h, 1e-20)

        var bestJ = Double.greatestFiniteMagnitude
        for s in 0..<k {
            var y = nb[s]
            for _ in 0..<pp.iterations {
                var acc = SIMD2<Double>.zero, den = 0.0
                for i in 0..<k {
                    let dv = y - nb[i]
                    let ww = w[i] / (1.0 + (dv.x * dv.x + dv.y * dv.y) / h2)
                    acc += ww * nb[i]; den += ww
                }
                if !(den > 0) { break }
                y = acc / den
            }
            bestJ = min(bestJ, objective(y, nb, h2))
        }
        let gpuJ = objective(SIMD2(Double(placed[q].x), Double(placed[q].y)), nb, h2)
        // Float vs Double arithmetic, and .fast math in the shader, so allow a
        // small relative slack rather than demanding an exact match.
        if gpuJ > bestJ + 1e-3 * max(1, abs(bestJ)) { worseCount += 1 }
    }
    #expect(worseCount == 0)
}

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"))
func projectIsIndependentOfBatchComposition() throws {
    // Nothing couples the new points, so a point lands identically alone and in
    // a batch, and repeat calls are exact.
    let (data, labels) = blobs(clusters: 4, perCluster: 120, dim: 12, seed: 9)
    let split = holdOut(data, labels, stride: 5)

    var params = TSNEParameters()
    params.iterations = 400
    params.pcaDimensions = nil
    let model = try TSNE(parameters: params).fit(data: split.train)

    let batch = try model.project(data: split.test)
    let solo = try model.project(data: [split.test[3]])
    #expect(simd_distance(solo[0], batch[3]) == 0)

    let again = try model.project(data: split.test)
    #expect(zip(batch, again).allSatisfy { simd_distance($0, $1) == 0 })
}

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"))
func projectCachesLocalScalesAcrossCalls() throws {
    let (data, labels) = blobs(clusters: 3, perCluster: 100, dim: 10, seed: 15)
    let split = holdOut(data, labels, stride: 8)

    var params = TSNEParameters()
    params.iterations = 300
    params.pcaDimensions = nil
    let model = try TSNE(parameters: params).fit(data: split.train)

    _ = try model.project(data: split.test)
    #expect(!model.projectionStatistics.reusedLocalScale)
    _ = try model.project(data: split.test)
    #expect(model.projectionStatistics.reusedLocalScale)
    #expect(model.projectionStatistics.localScaleSeconds < 1e-3)

    // Prepared up front, the very first projection reuses the table too.
    let fresh = try TSNE(parameters: params).fit(data: split.train)
    try fresh.prepareProjection()
    _ = try fresh.project(data: split.test)
    #expect(fresh.projectionStatistics.reusedLocalScale)
}

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"))
func projectMultiStartBeatsSingleStartWhenNeighborsStraddleClusters() throws {
    // The objective is non-convex on purpose. For a query whose neighbors span
    // two clusters, starting at the 1-NN can settle in the wrong basin — so the
    // restarts must actually change the answer, and never for the worse.
    let (data, _) = blobs(clusters: 5, perCluster: 150, dim: 16, seed: 71)
    var params = TSNEParameters()
    params.iterations = 400
    params.pcaDimensions = nil
    let model = try TSNE(parameters: params).fit(data: data)

    // Points far from every cluster pull neighbors from several of them.
    var rng = SplitMix64(seed: 4242)
    let queries = (0..<200).map { _ in (0..<16).map { _ in Float(rng.nextUnit() * 2 - 1) * 20 } }

    let multi = TSNEProjectionParameters()
    var single = TSNEProjectionParameters()
    single.multiStart = false
    let yMulti = try model.project(data: queries, parameters: multi)
    let ySingle = try model.project(data: queries, parameters: single)

    let k = multi.neighborCount
    let scales = try model.localScales(neighbor: multi.localScaleNeighbor)
    let (d2, idx) = try model.queryKNN(queries: queries.flatMap { $0 },
                                       queryCount: queries.count, k: k)
    var w = (1...k).map { 1.0 / Double($0) }
    let wsum = w.reduce(0, +)
    for i in 0..<k { w[i] /= wsum }

    var improved = 0, regressed = 0
    for q in 0..<queries.count {
        let order = (0..<k).sorted { d2[q * k + $0] < d2[q * k + $1] }
        let nb = order.map { model.embedding[Int(idx[q * k + $0])] }
        let h = multi.bandwidthScale * Double(scales[Int(idx[q * k + order[0]])])
        let h2 = max(h * h, 1e-20)
        func objective(_ y: SIMD2<Float>) -> Double {
            var j = 0.0
            for i in 0..<k {
                let r2 = Double(simd_distance_squared(y, nb[i])) / h2
                j += w[i] * log1p(r2)
            }
            return j
        }
        let jm = objective(yMulti[q]), js = objective(ySingle[q])
        if jm < js - 1e-6 { improved += 1 }
        if jm > js + 1e-4 { regressed += 1 }
    }
    #expect(improved > 0)
    #expect(regressed == 0)
}

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"))
func projectSingleStartStaysOnTheMap() throws {
    // The cheap single-start variant must remain sane, just not necessarily as
    // good as the multi-start default.
    let (data, labels) = blobs(clusters: 5, perCluster: 150, dim: 16, seed: 55)
    let split = holdOut(data, labels, stride: 7)

    var params = TSNEParameters()
    params.iterations = 400
    params.pcaDimensions = nil
    let model = try TSNE(parameters: params).fit(data: split.train)

    var pp = TSNEProjectionParameters()
    pp.multiStart = false
    let placed = try model.project(data: split.test, parameters: pp)
    #expect(placed.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    let agreement = neighborAgreement(placed: placed, placedLabels: split.testLabels,
                                      reference: model.embedding, referenceLabels: split.trainLabels)
    #expect(agreement > 0.95)
}

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"))
func projectLandsInsideTheMapForOutOfDistributionPoints() throws {
    // A projected point is a weighted combination of reference positions, so it
    // is inside their convex hull by construction — never flung outside the map
    // the way a mis-stepped gradient can be.
    let (data, _) = blobs(clusters: 4, perCluster: 120, dim: 16, seed: 63)
    var params = TSNEParameters()
    params.iterations = 400
    params.pcaDimensions = nil
    let model = try TSNE(parameters: params).fit(data: data)

    var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
    var hi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
    for p in model.embedding { lo = simd_min(lo, p); hi = simd_max(hi, p) }

    var rng = SplitMix64(seed: 999)
    let outliers = (0..<10).map { _ in (0..<16).map { _ in Float(rng.nextUnit() * 2 - 1) * 60 } }
    let placed = try model.project(data: outliers)

    #expect(placed.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    let eps: Float = 1e-3
    #expect(placed.allSatisfy {
        $0.x >= lo.x - eps && $0.x <= hi.x + eps &&
        $0.y >= lo.y - eps && $0.y <= hi.y + eps
    })
}

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"))
func projectHandlesDuplicateReferencePoints() throws {
    // Coincident reference points give a local spacing of zero, which would
    // collapse the bandwidth; the fallback must keep the arithmetic finite.
    let (base, _) = blobs(clusters: 3, perCluster: 40, dim: 8, seed: 88)
    let data = base + base          // every point duplicated
    var params = TSNEParameters()
    params.iterations = 200
    params.pcaDimensions = nil
    let model = try TSNE(parameters: params).fit(data: data)

    let scales = try model.localScales(neighbor: 5)
    #expect(scales.allSatisfy { $0 > 0 && $0.isFinite })
    let placed = try model.project(data: Array(base.prefix(20)))
    #expect(placed.allSatisfy { $0.x.isFinite && $0.y.isFinite })
}

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"))
func projectClampsNeighborCountToTheKernelLimit() throws {
    let (data, labels) = blobs(clusters: 3, perCluster: 80, dim: 10, seed: 6)
    let split = holdOut(data, labels, stride: 8)
    var params = TSNEParameters()
    params.iterations = 200
    params.pcaDimensions = nil
    let model = try TSNE(parameters: params).fit(data: split.train)

    var pp = TSNEProjectionParameters()
    pp.neighborCount = 500                       // far past the register budget
    let placed = try model.project(data: split.test, parameters: pp)
    #expect(model.projectionStatistics.neighborCount == 32)
    #expect(placed.allSatisfy { $0.x.isFinite && $0.y.isFinite })
}

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"))
func projectValidatesInput() throws {
    let (data, _) = blobs(clusters: 2, perCluster: 60, dim: 8, seed: 1)
    var params = TSNEParameters()
    params.iterations = 100
    params.pcaDimensions = nil
    let model = try TSNE(parameters: params).fit(data: data)

    #expect(try model.project(data: []).isEmpty)
    #expect(throws: TSNEError.self) {
        try model.project(data: [[Float](repeating: 0, count: 3)])
    }
}

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"))
func projectRespectsTheFittedPCABasis() throws {
    // With PCA enabled the neighbor search happens in the projected space; a
    // point identical to a training point must land on top of it.
    let (data, _) = blobs(clusters: 4, perCluster: 120, dim: 24, seed: 31)
    var params = TSNEParameters()
    params.iterations = 400
    params.pcaDimensions = 8
    let model = try TSNE(parameters: params).fit(data: data)
    #expect(model.inputDimensions == 24)

    let sample = stride(from: 0, to: data.count, by: 11).map { data[$0] }
    let expected = stride(from: 0, to: data.count, by: 11).map { model.embedding[$0] }
    let placed = try model.project(data: sample)

    var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
    var hi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
    for p in model.embedding { lo = simd_min(lo, p); hi = simd_max(hi, p) }
    let span = max(hi.x - lo.x, hi.y - lo.y)

    var displacement: Float = 0
    for i in 0..<placed.count { displacement += simd_distance(placed[i], expected[i]) }
    displacement /= Float(placed.count)
    #expect(displacement < span * 0.05)
}

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"))
func approximateKNNHasHighRecall() throws {
    // NN-Descent should recover most of the true k nearest neighbors.
    let (data, _) = blobs(clusters: 6, perCluster: 350, dim: 16, seed: 5)
    let n = data.count, dim = 16, k = 30
    let flat = data.flatMap { $0 }
    let tsne = try TSNE()

    let (_, approxIdx) = try tsne.computeApproxKNN(data: flat, count: n, dim: dim, k: k)

    // Exact top-k per point (CPU reference).
    var hits = 0, total = 0
    for i in 0..<n {
        var dists = [(Float, Int)]()
        for j in 0..<n where j != i {
            var d: Float = 0
            for c in 0..<dim { let df = data[i][c] - data[j][c]; d += df * df }
            dists.append((d, j))
        }
        let trueK = Set(dists.sorted { $0.0 < $1.0 }.prefix(k).map { $0.1 })
        let got = Set((0..<k).map { Int(approxIdx[i * k + $0]) })
        hits += trueK.intersection(got).count
        total += k
    }
    let recall = Double(hits) / Double(total)
    #expect(recall >= 0.85)
}

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"))
func blockedQueryKNNMatchesScalarKernel() throws {
    // The register-blocked kernel is an optimization, not a new algorithm: it
    // must return the same neighbors and the same squared distances as the
    // scalar one. Swept across dimensions so the float4 padding tail (dim % 4)
    // and the specialization boundary are both covered.
    for dim in [2, 3, 5, 8, 17, 32, 50, 64] {
        let (data, labels) = blobs(clusters: 3, perCluster: 90, dim: dim, seed: UInt64(dim))
        let split = holdOut(data, labels, stride: 5)
        var params = TSNEParameters()
        params.iterations = 50
        params.pcaDimensions = nil
        let model = try TSNE(parameters: params).fit(data: split.train)

        let k = 12
        let flat = split.test.flatMap { $0 }
        let fast = try model.bruteForceKNN(
            queries: flat, queryCount: split.test.count,
            refs: model.referenceWork, refCount: split.train.count,
            dimensions: dim, k: k)
        let slow = try model.bruteForceKNN(
            queries: flat, queryCount: split.test.count,
            refs: model.referenceWork, refCount: split.train.count,
            dimensions: dim, k: k, forceScalarKernel: true)

        // The top-k comes back unordered, so compare as sorted lists.
        for q in 0..<split.test.count {
            let a = (0..<k).map { fast.idx[q * k + $0] }.sorted()
            let b = (0..<k).map { slow.idx[q * k + $0] }.sorted()
            #expect(a == b, "neighbor sets differ at dim=\(dim), query \(q)")
            let da = (0..<k).map { fast.dist[q * k + $0] }.sorted()
            let db = (0..<k).map { slow.dist[q * k + $0] }.sorted()
            for i in 0..<k {
                #expect(abs(da[i] - db[i]) <= 1e-4 * max(1, abs(db[i])),
                        "distances differ at dim=\(dim), query \(q)")
            }
        }
    }
}

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"))
func blockedQueryKNNBeatsScalarKernel() throws {
    // Interleaved in one process and reported as best-of-N, because the GPU's
    // clock state drifts enough across separate process launches to swamp the
    // effect being measured.
    let dim = 32, nRef = 8000, nQuery = 8000, k = 8
    let (data, labels) = blobs(clusters: 6, perCluster: (nRef + nQuery) / 6, dim: dim, seed: 314)
    var params = TSNEParameters()
    params.iterations = 100
    params.pcaDimensions = nil
    let model = try TSNE(parameters: params).fit(data: Array(data.prefix(nRef)))
    let queries = Array(data.suffix(nQuery)).flatMap { $0 }
    _ = labels

    func best(scalar: Bool) throws -> Double {
        var bestSeconds = Double.greatestFiniteMagnitude
        for _ in 0..<3 {
            let clock = ContinuousClock()
            let t0 = clock.now
            _ = try model.bruteForceKNN(queries: queries, queryCount: nQuery,
                                        refs: model.referenceWork, refCount: nRef,
                                        dimensions: dim, k: k, forceScalarKernel: scalar)
            let d = t0.duration(to: clock.now)
            let s = Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
            bestSeconds = min(bestSeconds, s)
        }
        return bestSeconds
    }

    // Alternate so any thermal trend is shared between the two.
    _ = try best(scalar: false)
    let blocked = try best(scalar: false)
    let scalar = try best(scalar: true)
    let blocked2 = try best(scalar: false)
    let fast = min(blocked, blocked2)
    print(String(format: "query KNN %d×%d dim=%d: scalar %.4fs  blocked %.4fs  (%.1fx)",
                 nQuery, nRef, dim, scalar, fast, scalar / fast))
    #expect(fast < scalar)
}

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"))
func knnMatchesBruteForce() throws {
    // Verify the GPU KNN against a CPU brute-force reference on small data.
    let (data, _) = blobs(clusters: 3, perCluster: 40, dim: 8, seed: 3)
    let n = data.count, dim = 8, k = 10
    let flat = data.flatMap { $0 }
    let tsne = try TSNE()
    let (_, idx) = try tsne._debugKNN(flat: flat, count: n, dim: dim, k: k)

    // CPU reference: nearest neighbor of each point.
    for i in 0..<n {
        var bestJ = -1; var bestD = Float.greatestFiniteMagnitude
        for j in 0..<n where j != i {
            var d: Float = 0
            for c in 0..<dim { let df = data[i][c] - data[j][c]; d += df * df }
            if d < bestD { bestD = d; bestJ = j }
        }
        let gpuNearest = (0..<k).map { Int(idx[i * k + $0]) }
        #expect(gpuNearest.contains(bestJ))
    }
}
