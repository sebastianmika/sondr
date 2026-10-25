import Foundation
import Metal
import simd

private extension Duration {
    var asSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}

/// How a new point's starting position is chosen before it is optimized.
public enum TSNETransformInitialization: Sendable {
    /// Coordinate-wise median of the new point's nearest reference neighbors.
    /// Robust to a neighbor that sits in a different part of the map, which is
    /// why it is the default.
    case median
    /// Affinity-weighted mean of the nearest reference neighbors' positions.
    /// Smoother, but a single distant neighbor can drag the start position into
    /// empty space between clusters.
    case weighted
}

/// Tunable parameters for placing new points into an existing embedding.
///
/// The defaults follow the same conventions as `openTSNE.transform`: a small
/// perplexity (new points should attach to their immediate neighborhood, not to
/// global structure), a short optimization with a clipped gradient, and a mild
/// exaggeration so points settle *inside* clusters rather than on their rim.
public struct TSNETransformParameters: Sendable {
    /// Target perplexity for each new point's affinity row. Much smaller than
    /// the fit perplexity by design — the reference map already encodes the
    /// global structure, so a new point only needs its local neighborhood.
    public var perplexity: Double = 5

    /// Number of reference neighbors retained per new point. Should be at least
    /// `3 * perplexity`.
    public var neighborCount: Int = 25

    /// Gradient-descent iterations. New points start close to their final spot
    /// (see ``initialization``), so far fewer are needed than for a fit.
    public var iterations: Int = 250

    /// Attractive-force multiplier during the first
    /// ``earlyExaggerationIterations`` steps.
    public var earlyExaggeration: Double = 4

    /// Number of leading iterations that use ``earlyExaggeration``. Defaults to
    /// 0: with a neighbor-based initialization there is no cluster-forming phase
    /// to accelerate.
    public var earlyExaggerationIterations: Int = 0

    /// Attractive-force multiplier for the remaining iterations. Slightly above
    /// 1 keeps new points from drifting out toward the sparse rim of a cluster,
    /// where the repulsive field is weakest.
    public var exaggeration: Double = 1.5

    /// Gradient-descent learning rate. Because each new point carries its own
    /// normalizer (see ``TSNEModel/transform(data:parameters:onProgress:)``),
    /// the gradient is on a per-point scale: unlike the fit learning rate, this
    /// one does not need to grow with the size of the reference set. Rates much
    /// above ~0.5 leave points jittering around their optimum instead of
    /// settling into it.
    public var learningRate: Double = 0.25

    /// Momentum used during early exaggeration.
    public var initialMomentum: Double = 0.5

    /// Momentum used after early exaggeration ends.
    public var finalMomentum: Double = 0.8

    /// Per-point gradient norms are clipped to this value before the step, so a
    /// point that lands in a repulsive hot spot cannot be flung across the map.
    /// Set to 0 to disable.
    public var maximumGradientNorm: Double = 0.25

    /// How new points are seeded before optimization.
    public var initialization: TSNETransformInitialization = .median

    /// Repulsion backend, resolved against the *reference* point count exactly
    /// as ``TSNEParameters/optimizer`` is for a fit.
    public var optimizer: TSNEOptimizer = .auto

    /// Reference count at/above which `.auto` switches to the field backend.
    public var autoFastThreshold: Int = 10_000

    public init() {}
}

/// Wall-clock timing breakdown for the most recent `transform` call.
public struct TSNETransformStatistics: Sendable {
    /// Number of new points placed.
    public var pointCount = 0
    /// Number of points in the reference embedding.
    public var referenceCount = 0
    /// Reference neighbors used per new point.
    public var neighborCount = 0
    public var knnSeconds = 0.0
    public var affinitySeconds = 0.0
    public var optimizeSeconds = 0.0
    public var totalSeconds = 0.0
    public var usedFieldOptimizer = false
}

/// A fitted t-SNE embedding, plus everything needed to place new points into it.
///
/// Produced by ``TSNE/fit(data:onProgress:)``. Retains the reference points in
/// their working (post-PCA) space and the PCA basis, so it is heavier than the
/// embedding alone: roughly `N × workingDimensions` floats.
///
/// ```swift
/// let tsne = try TSNE()
/// let model = try tsne.fit(data: trainingVectors)
/// let reference = model.embedding                  // laid-out points
/// let placed = try model.transform(data: newVectors)  // new points in the same space
/// ```
public final class TSNEModel {
    /// The reference embedding, one 2-D point per fitted input point.
    public let embedding: [SIMD2<Float>]
    /// Number of points the embedding was fitted on.
    public var pointCount: Int { embedding.count }
    /// Dimensionality the model expects new points to have.
    public let inputDimensions: Int
    /// The parameters the embedding was fitted with.
    public let fitParameters: TSNEParameters
    /// Timing breakdown of the fit that produced this model.
    public let fitStatistics: TSNEStatistics
    /// Timing breakdown of the most recent ``transform(data:parameters:onProgress:)``.
    public private(set) var transformStatistics = TSNETransformStatistics()
    /// Timing breakdown of the most recent ``project(data:parameters:)``.
    public internal(set) var projectionStatistics = TSNEProjectionStatistics()

    /// Reference points in working space (post-PCA), row-major.
    let referenceWork: [Float]
    let workDimensions: Int
    let pcaBasis: PCABasis?
    let context: MetalContext

    /// Largest `neighborCount` the mode-seeking kernel keeps in registers; must
    /// match `TSNE_MAX_PROJECT_K` in the shader source.
    static let maxProjectionNeighbors = 32

    /// Per-reference local map spacing, built on demand by `project` and reused
    /// across calls. Keyed by the neighbor index it was measured at.
    var localScaleCache: [Float]?
    var localScaleCacheNeighbor: Int?

    init(context: MetalContext,
         parameters: TSNEParameters,
         embedding: [SIMD2<Float>],
         referenceWork: [Float],
         workDimensions: Int,
         inputDimensions: Int,
         pcaBasis: PCABasis?,
         fitStatistics: TSNEStatistics) {
        self.context = context
        self.fitParameters = parameters
        self.embedding = embedding
        self.referenceWork = referenceWork
        self.workDimensions = workDimensions
        self.inputDimensions = inputDimensions
        self.pcaBasis = pcaBasis
        self.fitStatistics = fitStatistics
    }

    // MARK: - Transform

    /// Places new points into the fitted embedding, leaving it unchanged.
    ///
    /// Each new point is attracted to its nearest *reference* points and repelled
    /// by the reference map as a whole; new points exert no force on the map and
    /// none on each other. A point therefore lands in the same place whether it
    /// is transformed on its own or in a batch of a million, and two `transform`
    /// calls on the same input give the same answer.
    ///
    /// One consequence worth knowing when reading the resulting picture: because
    /// new points do not repel one another, they settle a little closer to the
    /// dense core of a cluster than the fitted points around them (~0.8× the
    /// fitted radius, measured on separable synthetic data). That is inherent to
    /// out-of-sample placement rather than a tuning artifact — it barely moves
    /// with ``TSNETransformParameters/exaggeration``.
    ///
    /// - Parameters:
    ///   - data: new feature vectors, each of length ``inputDimensions``.
    ///   - parameters: transform-specific tuning; see ``TSNETransformParameters``.
    ///   - onProgress: called periodically with the new points' current positions.
    /// - Returns: one 2-D point per input, in the same coordinate space as
    ///   ``embedding``.
    public func transform(
        data: [[Float]],
        parameters: TSNETransformParameters = TSNETransformParameters(),
        onProgress: (@Sendable (TSNEProgress) -> Void)? = nil
    ) throws -> [SIMD2<Float>] {
        guard let first = data.first else { return [] }
        let dim = first.count
        guard data.allSatisfy({ $0.count == dim }) else {
            throw TSNEError.invalidInput("all feature vectors must have the same length")
        }
        var flat = [Float]()
        flat.reserveCapacity(data.count * dim)
        for row in data { flat.append(contentsOf: row) }
        return try transform(flatData: flat, count: data.count, dimensions: dim,
                             parameters: parameters, onProgress: onProgress)
    }

    /// Places new points stored as a flat row-major `count` × `dimensions` array.
    public func transform(
        flatData: [Float],
        count m: Int,
        dimensions dim: Int,
        parameters: TSNETransformParameters = TSNETransformParameters(),
        onProgress: (@Sendable (TSNEProgress) -> Void)? = nil
    ) throws -> [SIMD2<Float>] {
        guard m > 0 else { return [] }
        guard dim == inputDimensions else {
            throw TSNEError.invalidInput(
                "new points have \(dim) dimensions but the model was fitted on \(inputDimensions)")
        }
        guard flatData.count == m * dim else {
            throw TSNEError.invalidInput("flatData length must equal count * dimensions")
        }
        let n = embedding.count
        guard n > 0 else { throw TSNEError.invalidInput("the model has an empty embedding") }

        let clock = ContinuousClock()
        let t0 = clock.now
        var stats = TSNETransformStatistics()
        stats.pointCount = m
        stats.referenceCount = n

        // A single reference point: everything collapses onto it.
        if n == 1 {
            stats.totalSeconds = (t0.duration(to: clock.now)).asSeconds
            transformStatistics = stats
            return [SIMD2<Float>](repeating: embedding[0], count: m)
        }

        // 1. Map the new points into the same working space as the reference.
        let work = pcaBasis.map { $0.project(data: flatData, count: m) } ?? flatData

        let k = max(1, min(parameters.neighborCount, n))
        stats.neighborCount = k

        // 2. Nearest reference neighbors for each new point.
        let tk = clock.now
        let (knnDist, knnIdx) = try queryKNN(queries: work, queryCount: m, k: k)
        stats.knnSeconds = (tk.duration(to: clock.now)).asSeconds

        // 3. Row-normalized conditional affinities P(reference | new point). This
        //    matrix is asymmetric and never symmetrized: the reference map is
        //    fixed, so there is no reverse direction to average with.
        let ta = clock.now
        let pValues = Affinities.conditional(neighborDist: knnDist, count: m, k: k,
                                             perplexity: parameters.perplexity)
        stats.affinitySeconds = (ta.duration(to: clock.now)).asSeconds

        // 4. Seed each new point from its neighbors' positions.
        let initial = makeInitialPositions(neighborIdx: knnIdx, affinities: pValues,
                                           count: m, k: k,
                                           mode: parameters.initialization)

        // 5. Gradient descent on the new points only.
        let to = clock.now
        let useField = resolveUseField(parameters: parameters, referenceCount: n)
            && context.supportsFieldSplatting
        let positions = try optimizeTransform(
            initial: initial, neighborIdx: knnIdx, affinities: pValues,
            count: m, k: k, parameters: parameters, useField: useField,
            onProgress: onProgress)
        stats.usedFieldOptimizer = useField
        stats.optimizeSeconds = (to.duration(to: clock.now)).asSeconds

        stats.totalSeconds = (t0.duration(to: clock.now)).asSeconds
        transformStatistics = stats
        return positions
    }

    private func resolveUseField(parameters: TSNETransformParameters, referenceCount n: Int) -> Bool {
        switch parameters.optimizer {
        case .exact: return false
        case .field: return true
        case .auto: return n > parameters.autoFastThreshold
        }
    }

    // MARK: - Query KNN

    private struct KNNQueryParams {
        var m: UInt32; var n: UInt32; var dim: UInt32; var k: UInt32; var tile: UInt32
    }

    /// Exact tiled brute-force search of the reference set for each new point.
    /// One-shot and O(M·N·D); the per-iteration cost of the optimization below is
    /// what dominates a transform, which is why this stays exact.
    func queryKNN(queries: [Float], queryCount m: Int, k: Int) throws -> (dist: [Float], idx: [UInt32]) {
        try bruteForceKNN(queries: queries, queryCount: m,
                          refs: referenceWork, refCount: embedding.count,
                          dimensions: workDimensions, k: k)
    }

    /// Largest padded float4 count the register-blocked query kernel supports
    /// (⇒ 128 dimensions); must match `TSNE_KNN_MAX_VEC` in the shader source.
    static let maxQueryBlockVectors = 32

    /// Exact tiled brute-force KNN of `queries` against `refs`. The returned
    /// distances are **squared** and the per-query top-k list is **unordered**.
    ///
    /// Dispatches the register-blocked kernel when the (4-padded) dimension fits
    /// in its register budget — the case for anything that has been through PCA
    /// — and the scalar kernel otherwise. Both compute the same distances.
    func bruteForceKNN(
        queries: [Float], queryCount m: Int,
        refs: [Float], refCount n: Int,
        dimensions dim: Int, k: Int,
        forceScalarKernel: Bool = false
    ) throws -> (dist: [Float], idx: [UInt32]) {
        let vectors = (max(1, dim) + 3) / 4
        let blocked = !forceScalarKernel && vectors <= TSNEModel.maxQueryBlockVectors

        let pipeline = blocked
            ? try context.pipeline("knn_query_blocked", constants: [0: UInt32(vectors)])
            : try context.pipeline("knn_query")

        let qBuf = try context.makeBuffer(Float.self, count: m * dim, from: queries)
        let rBuf = try context.makeBuffer(Float.self, count: n * dim, from: refs)
        let distBuf = try context.makeBuffer(Float.self, count: m * k)
        let idxBuf = try context.makeBuffer(UInt32.self, count: m * k)

        // Same ~16 KB threadgroup budget either way; the blocked path counts in
        // padded float4s rather than raw floats.
        let maxTileFloats = 4096
        let rowFloats = blocked ? vectors * 4 : max(1, dim)
        let tile = max(1, min(1024, maxTileFloats / rowFloats))
        var params = KNNQueryParams(m: UInt32(m), n: UInt32(n), dim: UInt32(dim),
                                    k: UInt32(k), tile: UInt32(tile))

        let tgSize = min(256, pipeline.maxTotalThreadsPerThreadgroup)
        let groups = (m + tgSize - 1) / tgSize

        guard let cb = context.queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else {
            throw TSNEError.bufferAllocationFailed
        }
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(qBuf, offset: 0, index: 0)
        enc.setBuffer(rBuf, offset: 0, index: 1)
        enc.setBuffer(distBuf, offset: 0, index: 2)
        enc.setBuffer(idxBuf, offset: 0, index: 3)
        enc.setBytes(&params, length: MemoryLayout<KNNQueryParams>.stride, index: 4)
        enc.setThreadgroupMemoryLength(tile * rowFloats * MemoryLayout<Float>.stride, index: 0)
        enc.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: tgSize, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        return (distBuf.array(Float.self, count: m * k), idxBuf.array(UInt32.self, count: m * k))
    }

    // MARK: - Initialization

    private func makeInitialPositions(
        neighborIdx: [UInt32],
        affinities: [Float],
        count m: Int,
        k: Int,
        mode: TSNETransformInitialization
    ) -> [SIMD2<Float>] {
        var out = [SIMD2<Float>](repeating: .zero, count: m)
        switch mode {
        case .weighted:
            for i in 0..<m {
                var acc = SIMD2<Float>.zero
                var wsum: Float = 0
                for t in 0..<k {
                    let w = affinities[i * k + t]
                    acc += w * embedding[Int(neighborIdx[i * k + t])]
                    wsum += w
                }
                out[i] = wsum > 1e-12 ? acc / wsum : embedding[Int(neighborIdx[i * k])]
            }
        case .median:
            var xs = [Float](repeating: 0, count: k)
            var ys = [Float](repeating: 0, count: k)
            for i in 0..<m {
                for t in 0..<k {
                    let p = embedding[Int(neighborIdx[i * k + t])]
                    xs[t] = p.x; ys[t] = p.y
                }
                xs.sort(); ys.sort()
                let mid = k / 2
                let x = k % 2 == 1 ? xs[mid] : 0.5 * (xs[mid - 1] + xs[mid])
                let y = k % 2 == 1 ? ys[mid] : 0.5 * (ys[mid - 1] + ys[mid])
                out[i] = SIMD2(x, y)
            }
        }
        return out
    }

    // MARK: - Optimization

    private struct TransformApplyParams {
        var m: UInt32
        var learningRate: Float
        var momentum: Float
        var exaggeration: Float
        var minGain: Float
        var maxGradNorm: Float
    }

    private func optimizeTransform(
        initial: [SIMD2<Float>],
        neighborIdx: [UInt32],
        affinities: [Float],
        count m: Int,
        k: Int,
        parameters: TSNETransformParameters,
        useField: Bool,
        onProgress: (@Sendable (TSNEProgress) -> Void)?
    ) throws -> [SIMD2<Float>] {
        let n = embedding.count
        let attrPipe = try context.pipeline("tsne_transform_attractive")
        let applyPipe = try context.pipeline("tsne_transform_apply")

        let qposBuf = try context.makeBuffer(SIMD2<Float>.self, count: m, from: initial)
        let rposBuf = try context.makeBuffer(SIMD2<Float>.self, count: n, from: embedding)
        let velBuf = try context.makeBuffer(SIMD2<Float>.self, count: m,
                                            from: [SIMD2<Float>](repeating: .zero, count: m))
        let gainBuf = try context.makeBuffer(SIMD2<Float>.self, count: m,
                                             from: [SIMD2<Float>](repeating: SIMD2(1, 1), count: m))
        let attrBuf = try context.makeBuffer(SIMD2<Float>.self, count: m)
        let repBuf = try context.makeBuffer(SIMD2<Float>.self, count: m)
        let zBuf = try context.makeBuffer(Float.self, count: m)
        let pValBuf = try context.makeBuffer(Float.self, count: m * k, from: affinities)
        let colBuf = try context.makeBuffer(UInt32.self, count: m * k, from: neighborIdx)

        let tgSize = 256
        let gridGroups = MTLSize(width: (m + tgSize - 1) / tgSize, height: 1, depth: 1)
        let tgGroup = MTLSize(width: tgSize, height: 1, depth: 1)
        var mkVar = SIMD2<UInt32>(UInt32(m), UInt32(k))
        var countsVar = SIMD2<UInt32>(UInt32(m), UInt32(n))
        var mVar = UInt32(m)

        // Exact-repulsion resources.
        var repPipe: MTLComputePipelineState? = nil
        // Field-repulsion resources: the reference map is frozen, so its field is
        // splatted exactly once and then sampled every iteration.
        var fieldPipe: MTLComputePipelineState? = nil
        var fieldTex: MTLTexture? = nil
        var resVar = UInt32(0)
        var transformVar = SIMD4<Float>()

        if useField {
            fieldPipe = try context.pipeline("tsne_transform_field_sample")
            let splatPipe = try context.renderPipeline(vertex: "splat_vertex",
                                                       fragment: "splat_fragment",
                                                       pixelFormat: .rgba16Float)
            let R = MetalContext.fieldResolution(count: n)
            resVar = UInt32(R)
            let kernelTex = try context.makeKernelTexture()
            let tex = try context.makeFieldTexture(resolution: R)
            fieldTex = tex

            // Bound the field by the reference map *and* the new points' starting
            // positions, so nothing samples off the edge of the texture.
            var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
            var hi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
            for p in embedding { lo = simd_min(lo, p); hi = simd_max(hi, p) }
            for p in initial { lo = simd_min(lo, p); hi = simd_max(hi, p) }
            transformVar = MetalContext.fieldTransform(lo: lo, hi: hi, resolution: R)

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = tex
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            pass.colorAttachments[0].storeAction = .store
            guard let cb = context.queue.makeCommandBuffer(),
                  let re = cb.makeRenderCommandEncoder(descriptor: pass) else {
                throw TSNEError.bufferAllocationFailed
            }
            re.setRenderPipelineState(splatPipe)
            re.setVertexBuffer(rposBuf, offset: 0, index: 0)
            re.setVertexBytes(&transformVar, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            re.setVertexBytes(&resVar, length: MemoryLayout<UInt32>.stride, index: 2)
            re.setFragmentTexture(kernelTex, index: 0)
            re.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: n)
            re.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
        } else {
            repPipe = try context.pipeline("tsne_transform_repulsive")
        }

        let totalIters = parameters.iterations
        let earlyIters = parameters.earlyExaggerationIterations
        let reportEvery = max(1, min(onProgress == nil ? 150 : 25, max(1, totalIters)))

        var iter = 0
        while iter < totalIters {
            let batchEnd = min(iter + reportEvery, totalIters)
            guard let cb = context.queue.makeCommandBuffer(),
                  let enc = cb.makeComputeCommandEncoder() else {
                throw TSNEError.bufferAllocationFailed
            }
            for it in iter..<batchEnd {
                let inEarly = it < earlyIters
                var apply = TransformApplyParams(
                    m: UInt32(m),
                    learningRate: Float(parameters.learningRate),
                    momentum: Float(inEarly ? parameters.initialMomentum : parameters.finalMomentum),
                    exaggeration: Float(inEarly ? parameters.earlyExaggeration : parameters.exaggeration),
                    minGain: 0.01,
                    maxGradNorm: Float(max(0, parameters.maximumGradientNorm)))

                // (a) repulsion from the frozen reference map → repForce, per-point Z
                if let fieldPipe, let fieldTex {
                    enc.setComputePipelineState(fieldPipe)
                    enc.setBuffer(qposBuf, offset: 0, index: 0)
                    enc.setBuffer(repBuf, offset: 0, index: 1)
                    enc.setBuffer(zBuf, offset: 0, index: 2)
                    enc.setBytes(&transformVar, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)
                    enc.setBytes(&resVar, length: MemoryLayout<UInt32>.stride, index: 4)
                    enc.setBytes(&mVar, length: MemoryLayout<UInt32>.stride, index: 5)
                    enc.setTexture(fieldTex, index: 0)
                    enc.dispatchThreadgroups(gridGroups, threadsPerThreadgroup: tgGroup)
                } else if let repPipe {
                    enc.setComputePipelineState(repPipe)
                    enc.setBuffer(qposBuf, offset: 0, index: 0)
                    enc.setBuffer(rposBuf, offset: 0, index: 1)
                    enc.setBuffer(repBuf, offset: 0, index: 2)
                    enc.setBuffer(zBuf, offset: 0, index: 3)
                    enc.setBytes(&countsVar, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 4)
                    enc.setThreadgroupMemoryLength(tgSize * MemoryLayout<SIMD2<Float>>.stride, index: 0)
                    enc.dispatchThreadgroups(gridGroups, threadsPerThreadgroup: tgGroup)
                }

                // (b) attraction to the k nearest reference points
                enc.setComputePipelineState(attrPipe)
                enc.setBuffer(qposBuf, offset: 0, index: 0)
                enc.setBuffer(rposBuf, offset: 0, index: 1)
                enc.setBuffer(pValBuf, offset: 0, index: 2)
                enc.setBuffer(colBuf, offset: 0, index: 3)
                enc.setBuffer(attrBuf, offset: 0, index: 4)
                enc.setBytes(&mkVar, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 5)
                enc.dispatchThreadgroups(gridGroups, threadsPerThreadgroup: tgGroup)

                // (c) clipped gradient step
                enc.setComputePipelineState(applyPipe)
                enc.setBuffer(qposBuf, offset: 0, index: 0)
                enc.setBuffer(velBuf, offset: 0, index: 1)
                enc.setBuffer(gainBuf, offset: 0, index: 2)
                enc.setBuffer(attrBuf, offset: 0, index: 3)
                enc.setBuffer(repBuf, offset: 0, index: 4)
                enc.setBuffer(zBuf, offset: 0, index: 5)
                enc.setBytes(&apply, length: MemoryLayout<TransformApplyParams>.stride, index: 6)
                enc.dispatchThreadgroups(gridGroups, threadsPerThreadgroup: tgGroup)
            }
            enc.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            iter = batchEnd

            if let onProgress {
                let pts = qposBuf.array(SIMD2<Float>.self, count: m)
                onProgress(TSNEProgress(iteration: iter, totalIterations: totalIters, positions: pts))
            }
        }

        return qposBuf.array(SIMD2<Float>.self, count: m)
    }
}
