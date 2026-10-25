import Foundation
import Metal

private extension Duration {
    /// Elapsed time as fractional seconds.
    var asSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}

/// Progress reported during optimization, suitable for live animation.
public struct TSNEProgress: Sendable {
    public let iteration: Int
    public let totalIterations: Int
    /// Current 2-D positions (one entry per input point).
    public let positions: [SIMD2<Float>]
}

/// A fixed [0,1]×[0,1] rescaling of embedding coordinates, captured from one
/// point set by ``TSNE/normalizer(for:)`` and reusable on others.
public struct TSNENormalizer: Sendable {
    /// Lower bound of each axis (0.5 percentile of the source points).
    public let lo: SIMD2<Float>
    /// Upper bound of each axis (99.5 percentile of the source points).
    public let hi: SIMD2<Float>

    /// Maps `points` into the unit square, clamping anything outside the bounds.
    public func apply(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        let span = SIMD2(max(hi.x - lo.x, 1e-12), max(hi.y - lo.y, 1e-12))
        func clamp01(_ v: Float) -> Float { min(1, max(0, v)) }
        return points.map {
            SIMD2(clamp01(($0.x - lo.x) / span.x), clamp01(($0.y - lo.y) / span.y))
        }
    }
}

/// Wall-clock timing breakdown for the most recent `embed` call.
public struct TSNEStatistics: Sendable {
    public var pointCount = 0
    public var inputDimensions = 0
    public var workingDimensions = 0
    public var pcaSeconds = 0.0
    public var knnSeconds = 0.0
    public var affinitySeconds = 0.0
    public var optimizeSeconds = 0.0
    public var totalSeconds = 0.0
    public var usedFieldOptimizer = false
    public var usedApproximateKNN = false
}

/// GPU-accelerated t-SNE for macOS / Apple Silicon.
///
/// Typical use:
/// ```swift
/// let tsne = try TSNE()
/// let points = try tsne.embed(data: vectors) { progress in
///     // render progress.positions live
/// }
/// ```
public final class TSNE {
    public var parameters: TSNEParameters
    public private(set) var statistics = TSNEStatistics()

    let context: MetalContext

    public init(parameters: TSNEParameters = TSNEParameters()) throws {
        self.parameters = parameters
        self.context = try MetalContext()
    }

    /// Name of the Metal device performing the work (useful for diagnostics).
    public var deviceName: String { context.device.name }

    // MARK: - Public entry points

    /// Embeds an array of equal-length feature vectors into 2-D.
    public func embed(
        data: [[Float]],
        onProgress: (@Sendable (TSNEProgress) -> Void)? = nil
    ) throws -> [SIMD2<Float>] {
        guard !data.isEmpty else { return [] }
        return try fit(data: data, onProgress: onProgress).embedding
    }

    /// Embeds points stored as a flat row-major `count` × `dimensions` array.
    public func embed(
        flatData: [Float],
        count n: Int,
        dimensions inputDim: Int,
        onProgress: (@Sendable (TSNEProgress) -> Void)? = nil
    ) throws -> [SIMD2<Float>] {
        try fit(flatData: flatData, count: n, dimensions: inputDim, onProgress: onProgress).embedding
    }

    /// Embeds `data` and returns a ``TSNEModel``: the embedding plus everything
    /// needed to place *new* points into it later via
    /// ``TSNEModel/transform(data:parameters:onProgress:)``.
    public func fit(
        data: [[Float]],
        onProgress: (@Sendable (TSNEProgress) -> Void)? = nil
    ) throws -> TSNEModel {
        guard let first = data.first else {
            throw TSNEError.invalidInput("cannot fit an empty data set")
        }
        let dimensions = first.count
        guard data.allSatisfy({ $0.count == dimensions }) else {
            throw TSNEError.invalidInput("all feature vectors must have the same length")
        }
        var flatData: [Float] = []
        flatData.reserveCapacity(data.count * dimensions)
        for row in data { flatData.append(contentsOf: row) }
        return try fit(
            flatData: flatData,
            count: data.count,
            dimensions: dimensions,
            onProgress: onProgress)
    }

    /// Fits an embedding from a flat row-major `count` × `dimensions` array.
    public func fit(
        flatData: [Float],
        count n: Int,
        dimensions inputDim: Int,
        onProgress: (@Sendable (TSNEProgress) -> Void)? = nil
    ) throws -> TSNEModel {
        let clock = ContinuousClock()
        let started = clock.now
        let problem = try prepare(flatData: flatData, count: n, dimensions: inputDim)
        return try finishPreparedProblem(
            problem, started: started, clock: clock, onProgress: onProgress)
    }

    /// Prepares nested feature vectors for one or more optimization sessions.
    /// PCA, neighbor search, and affinity calibration are completed before this
    /// method returns.
    public func prepare(data: [[Float]]) throws -> TSNEProblem {
        guard let first = data.first else {
            throw TSNEError.invalidInput("cannot prepare an empty data set")
        }
        let dim = first.count
        guard data.allSatisfy({ $0.count == dim }) else {
            throw TSNEError.invalidInput("all feature vectors must have the same length")
        }
        var flat = [Float]()
        flat.reserveCapacity(data.count * dim)
        for row in data { flat.append(contentsOf: row) }
        return try prepare(flatData: flat, count: data.count, dimensions: dim)
    }

    /// Prepares a row-major `count` × `dimensions` feature matrix for one or
    /// more optimization sessions.
    public func prepare(
        flatData: [Float],
        count n: Int,
        dimensions inputDim: Int
    ) throws -> TSNEProblem {
        guard parameters.outputDimensions == 2 else {
            throw TSNEError.invalidInput("only 2-D output is currently supported")
        }
        guard n > 0, inputDim > 0, flatData.count == n * inputDim else {
            throw TSNEError.invalidInput("flatData length must equal count * dimensions")
        }
        guard flatData.allSatisfy(\.isFinite) else {
            throw TSNEError.invalidInput("flatData must contain only finite values")
        }
        let clock = ContinuousClock()
        let t0 = clock.now
        var stats = TSNEStatistics()
        stats.pointCount = n
        stats.inputDimensions = inputDim

        if n == 1 {
            stats.workingDimensions = inputDim
            stats.totalSeconds = (t0.duration(to: clock.now)).asSeconds
            statistics = stats
            let graph = try TSNEAffinityGraph(
                pointCount: 1, rowOffsets: [0, 0], columnIndices: [], values: [])
            return TSNEProblem(
                context: context, parameters: parameters, affinities: graph,
                defaultPositions: [.zero], referenceWork: flatData,
                workDimensions: inputDim, inputDimensions: inputDim,
                pcaBasis: nil, preparationStatistics: stats,
                useFieldOptimizer: false)
        }
        guard parameters.perplexity.isFinite, parameters.perplexity > 0 else {
            throw TSNEError.invalidInput("perplexity must be finite and greater than zero")
        }
        guard parameters.neighborCount > 0 else {
            throw TSNEError.invalidInput("neighborCount must be greater than zero")
        }
        if let target = parameters.pcaDimensions, target <= 0 {
            throw TSNEError.invalidInput("pcaDimensions must be greater than zero when supplied")
        }
        let k = max(1, min(parameters.neighborCount, n - 1))

        // 1. Optional PCA reduction of the input feature space. The fitted basis
        //    is kept so out-of-sample points can be mapped the same way.
        var work = flatData
        var workDim = inputDim
        var basis: PCABasis? = nil
        if let target = parameters.pcaDimensions, target < inputDim {
            let tp = clock.now
            let fitted = PCA.fit(data: flatData, count: n, dim: inputDim,
                                 components: target, seed: parameters.seed)
            work = fitted.projected
            basis = fitted.basis
            workDim = target
            stats.pcaSeconds = (tp.duration(to: clock.now)).asSeconds
        }
        stats.workingDimensions = workDim

        // 2. KNN graph on the GPU (exact brute force or approximate NN-Descent).
        let tk = clock.now
        let useApprox = resolveUseApproxKNN(count: n)
        let (knnDist, knnIdx) = useApprox
            ? try computeApproxKNN(data: work, count: n, dim: workDim, k: k)
            : try computeKNN(data: work, count: n, dim: workDim, k: k)
        stats.usedApproximateKNN = useApprox
        stats.knnSeconds = (tk.duration(to: clock.now)).asSeconds

        // 3. Symmetric affinities P (CPU, sparse).
        let ta = clock.now
        let sparseAffinities = Affinities.build(
            neighborDist: knnDist, neighborIdx: knnIdx,
            count: n, k: k, perplexity: parameters.perplexity)
        let affinities = TSNEAffinityGraph(
            pointCount: n, sparseAffinities: sparseAffinities)
        stats.affinitySeconds = (ta.duration(to: clock.now)).asSeconds

        // 4. Initial embedding.
        let initial = makeInitialEmbedding(work: work, count: n, dim: workDim)

        // 5. Select the optimizer now so every session from this problem uses
        //    the same backend and retains the corresponding resource set.
        let useField = resolveUseField(count: n) && context.supportsFieldSplatting
        stats.usedFieldOptimizer = useField
        stats.totalSeconds = (t0.duration(to: clock.now)).asSeconds
        statistics = stats
        return TSNEProblem(
            context: context, parameters: parameters, affinities: affinities,
            defaultPositions: initial, referenceWork: work,
            workDimensions: workDim, inputDimensions: inputDim,
            pcaBasis: basis, preparationStatistics: stats,
            useFieldOptimizer: useField)
    }

    /// Constructs a public affinity graph directly from the supplied feature
    /// matrix. Unlike ``prepare(flatData:count:dimensions:)``, this method does
    /// not apply the instance's optional PCA setting.
    public func makeAffinityGraph(
        flatData: [Float],
        count n: Int,
        dimensions dim: Int,
        perplexity: Double,
        neighborCount: Int,
        neighborSearch: TSNENeighborSearch = .auto
    ) throws -> TSNEAffinityGraph {
        guard n > 0, dim > 0, flatData.count == n * dim else {
            throw TSNEError.invalidInput("flatData length must equal count * dimensions")
        }
        guard flatData.allSatisfy(\.isFinite) else {
            throw TSNEError.invalidInput("flatData must contain only finite values")
        }
        guard perplexity.isFinite, perplexity > 0 else {
            throw TSNEError.invalidInput("perplexity must be finite and greater than zero")
        }
        guard neighborCount > 0 else {
            throw TSNEError.invalidInput("neighborCount must be greater than zero")
        }
        if n == 1 {
            return try TSNEAffinityGraph(
                pointCount: 1, rowOffsets: [0, 0], columnIndices: [], values: [])
        }

        let k = max(1, min(neighborCount, n - 1))
        let useApproximate = resolveUseApproxKNN(count: n, search: neighborSearch)
        let (distances, indices) = useApproximate
            ? try computeApproxKNN(data: flatData, count: n, dim: dim, k: k)
            : try computeKNN(data: flatData, count: n, dim: dim, k: k)
        let sparse = Affinities.build(
            neighborDist: distances, neighborIdx: indices,
            count: n, k: k, perplexity: perplexity)
        return TSNEAffinityGraph(pointCount: n, sparseAffinities: sparse)
    }

    private func finishPreparedProblem(
        _ problem: TSNEProblem,
        started: ContinuousClock.Instant,
        clock: ContinuousClock,
        onProgress: (@Sendable (TSNEProgress) -> Void)?
    ) throws -> TSNEModel {
        if problem.pointCount == 1 {
            var stats = problem.preparationStatistics
            stats.totalSeconds = started.duration(to: clock.now).asSeconds
            statistics = stats
            return TSNEModel(
                context: problem.context,
                parameters: problem.parameters,
                embedding: problem.defaultPositions,
                referenceWork: problem.referenceWork,
                workDimensions: problem.workDimensions,
                inputDimensions: problem.inputDimensions,
                pcaBasis: problem.pcaBasis,
                fitStatistics: stats)
        }
        let optimizationStarted = clock.now
        let session = try problem.makeSession()
        try session.runInitialSchedule(onProgress: onProgress)
        let positions = try session.snapshot().positions
        var stats = session.statisticsSnapshot()
        stats.optimizeSeconds = optimizationStarted.duration(to: clock.now).asSeconds
        stats.totalSeconds = started.duration(to: clock.now).asSeconds
        statistics = stats
        return TSNEModel(
            context: problem.context,
            parameters: problem.parameters,
            embedding: positions,
            referenceWork: problem.referenceWork,
            workDimensions: problem.workDimensions,
            inputDimensions: problem.inputDimensions,
            pcaBasis: problem.pcaBasis,
            fitStatistics: stats)
    }

    /// Rescales an embedding into the unit square [0,1]×[0,1] (handy for mapping
    /// straight to a viewport). Bounds are taken from the 0.5–99.5 percentile of
    /// each axis so that a handful of t-SNE outliers don't crush the bulk of the
    /// points into a corner; results are clamped to [0,1].
    public static func normalized(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        normalizer(for: points).apply(points)
    }

    /// Captures the [0,1] rescaling derived from `points`, so the *same* mapping
    /// can be replayed on other point sets.
    ///
    /// Use this when drawing transformed points alongside the reference map:
    /// normalizing each set on its own would derive different bounds and pull
    /// the two apart.
    ///
    /// ```swift
    /// let toViewport = TSNE.normalizer(for: model.embedding)
    /// let base = toViewport.apply(model.embedding)
    /// let placed = toViewport.apply(try model.transform(data: newVectors))
    /// ```
    public static func normalizer(for points: [SIMD2<Float>]) -> TSNENormalizer {
        guard !points.isEmpty else { return TSNENormalizer(lo: .zero, hi: SIMD2(1, 1)) }
        func bounds(_ values: [Float]) -> (lo: Float, hi: Float) {
            let sorted = values.sorted()
            let n = sorted.count
            if n < 20 { return (sorted.first!, sorted.last!) } // too few to trim
            let loIdx = Int(Double(n - 1) * 0.005)
            let hiIdx = Int(Double(n - 1) * 0.995)
            return (sorted[loIdx], sorted[hiIdx])
        }
        let (loX, hiX) = bounds(points.map { $0.x })
        let (loY, hiY) = bounds(points.map { $0.y })
        return TSNENormalizer(lo: SIMD2(loX, loY), hi: SIMD2(hiX, hiY))
    }

    // MARK: - KNN

    /// Test hook: exposes the GPU KNN result directly.
    func _debugKNN(flat: [Float], count: Int, dim: Int, k: Int) throws -> (dist: [Float], idx: [UInt32]) {
        try computeKNN(data: flat, count: count, dim: dim, k: k)
    }

    private struct KNNParams { var n: UInt32; var dim: UInt32; var k: UInt32; var tile: UInt32 }
    private struct NNDParams {
        var n: UInt32; var dim: UInt32; var k: UInt32; var sampleK: UInt32; var seed: UInt32
    }

    /// Whether `.auto`/`.approximate` should use NN-Descent for `count` points.
    private func resolveUseApproxKNN(count n: Int) -> Bool {
        resolveUseApproxKNN(count: n, search: parameters.neighborSearch)
    }

    private func resolveUseApproxKNN(
        count n: Int,
        search: TSNENeighborSearch
    ) -> Bool {
        switch search {
        case .exact: return false
        case .approximate: return true
        case .auto: return n > parameters.autoFastThreshold
        }
    }

    /// Approximate KNN via GPU NN-Descent. Seeds a random neighbor graph, then
    /// refines it for a few rounds by pulling neighbor-of-neighbor candidates.
    /// Each round touches only k·sampleK candidates per point, avoiding the
    /// O(N²) brute-force scan.
    func computeApproxKNN(data: [Float], count n: Int, dim: Int, k: Int)
        throws -> (dist: [Float], idx: [UInt32])
    {
        let initPipe = try context.pipeline("nnd_init")
        let stepPipe = try context.pipeline("nnd_step")
        let dataBuf = try context.makeBuffer(Float.self, count: n * dim, from: data)
        var distA = try context.makeBuffer(Float.self, count: n * k)
        var idxA = try context.makeBuffer(UInt32.self, count: n * k)
        var distB = try context.makeBuffer(Float.self, count: n * k)
        var idxB = try context.makeBuffer(UInt32.self, count: n * k)

        var params = NNDParams(n: UInt32(n), dim: UInt32(dim), k: UInt32(k),
                               sampleK: UInt32(min(k, 12)), seed: UInt32(truncatingIfNeeded: parameters.seed))

        let tgSize = 128
        let grid = MTLSize(width: (n + tgSize - 1) / tgSize, height: 1, depth: 1)
        let tg = MTLSize(width: tgSize, height: 1, depth: 1)

        func dispatch(_ pipe: MTLComputePipelineState, _ setup: (MTLComputeCommandEncoder) -> Void) throws {
            guard let cb = context.queue.makeCommandBuffer(),
                  let enc = cb.makeComputeCommandEncoder() else { throw TSNEError.bufferAllocationFailed }
            enc.setComputePipelineState(pipe)
            setup(enc)
            enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
            enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        }

        // Seed the random graph in A.
        try dispatch(initPipe) { enc in
            enc.setBuffer(dataBuf, offset: 0, index: 0)
            enc.setBuffer(distA, offset: 0, index: 1)
            enc.setBuffer(idxA, offset: 0, index: 2)
            enc.setBytes(&params, length: MemoryLayout<NNDParams>.stride, index: 3)
        }

        // Refine: read A (snapshot) → write B, then swap.
        let rounds = 3
        for _ in 0..<rounds {
            try dispatch(stepPipe) { enc in
                enc.setBuffer(dataBuf, offset: 0, index: 0)
                enc.setBuffer(distA, offset: 0, index: 1)
                enc.setBuffer(idxA, offset: 0, index: 2)
                enc.setBuffer(distB, offset: 0, index: 3)
                enc.setBuffer(idxB, offset: 0, index: 4)
                enc.setBytes(&params, length: MemoryLayout<NNDParams>.stride, index: 5)
            }
            swap(&distA, &distB)
            swap(&idxA, &idxB)
        }
        return (distA.array(Float.self, count: n * k), idxA.array(UInt32.self, count: n * k))
    }

    private func computeKNN(data: [Float], count n: Int, dim: Int, k: Int)
        throws -> (dist: [Float], idx: [UInt32])
    {
        let pipeline = try context.pipeline("knn_brute_force")
        let dataBuf = try context.makeBuffer(Float.self, count: n * dim, from: data)
        let distBuf = try context.makeBuffer(Float.self, count: n * k)
        let idxBuf = try context.makeBuffer(UInt32.self, count: n * k)

        // Candidate tile sized to fit comfortably in threadgroup memory (<=16KB).
        let maxTileFloats = 4096
        let tile = max(1, min(1024, maxTileFloats / max(1, dim)))
        var params = KNNParams(n: UInt32(n), dim: UInt32(dim), k: UInt32(k), tile: UInt32(tile))

        let tgSize = min(256, pipeline.maxTotalThreadsPerThreadgroup)
        let groups = (n + tgSize - 1) / tgSize

        guard let cb = context.queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else {
            throw TSNEError.bufferAllocationFailed
        }
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(dataBuf, offset: 0, index: 0)
        enc.setBuffer(distBuf, offset: 0, index: 1)
        enc.setBuffer(idxBuf, offset: 0, index: 2)
        enc.setBytes(&params, length: MemoryLayout<KNNParams>.stride, index: 3)
        enc.setThreadgroupMemoryLength(tile * dim * MemoryLayout<Float>.stride, index: 0)
        enc.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: tgSize, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        return (distBuf.array(Float.self, count: n * k), idxBuf.array(UInt32.self, count: n * k))
    }

    // MARK: - Initialization

    private func makeInitialEmbedding(work: [Float], count n: Int, dim: Int) -> [SIMD2<Float>] {
        switch parameters.initialization {
        case .random:
            var rng = SplitMix64(seed: parameters.seed)
            return (0..<n).map { _ in SIMD2(rng.nextGaussian() * 1e-4, rng.nextGaussian() * 1e-4) }
        case .pca:
            let comps = min(2, dim)
            let proj = PCA.project(data: work, count: n, dim: dim, components: comps, seed: parameters.seed)
            var pts = [SIMD2<Float>](repeating: .zero, count: n)
            // Scale so the embedding starts small (std ~1e-4), following the
            // openTSNE/sklearn convention; early exaggeration then expands it.
            var mean0: Float = 0
            for i in 0..<n { mean0 += proj[i * comps] }
            mean0 /= Float(n)
            var var0: Float = 0
            for i in 0..<n { let d = proj[i * comps] - mean0; var0 += d * d }
            let std0 = max(sqrt(var0 / Float(n)), 1e-12)
            let scale = 1e-4 / std0
            for i in 0..<n {
                let x = proj[i * comps] * scale
                let y = (comps > 1 ? proj[i * comps + 1] : 0) * scale
                pts[i] = SIMD2(x, y)
            }
            return pts
        }
    }

    // MARK: - Optimization

    private struct ApplyParams {
        var n: UInt32
        var learningRate: Float
        var momentum: Float
        var exaggeration: Float
        var minGain: Float
    }

    private func optimize(
        initial: [SIMD2<Float>],
        affinities: SparseAffinities,
        count n: Int,
        onProgress: (@Sendable (TSNEProgress) -> Void)?
    ) throws -> [SIMD2<Float>] {
        let repPipe = try context.pipeline("tsne_repulsive")
        let attrPipe = try context.pipeline("tsne_attractive")
        let applyPipe = try context.pipeline("tsne_apply")
        let clearPipe = try context.pipeline("tsne_clear_scalar")

        let posBuf = try context.makeBuffer(SIMD2<Float>.self, count: n, from: initial)
        let velBuf = try context.makeBuffer(SIMD2<Float>.self, count: n,
                                            from: [SIMD2<Float>](repeating: .zero, count: n))
        let gainBuf = try context.makeBuffer(SIMD2<Float>.self, count: n,
                                             from: [SIMD2<Float>](repeating: SIMD2(1, 1), count: n))
        let attrBuf = try context.makeBuffer(SIMD2<Float>.self, count: n)
        let repBuf = try context.makeBuffer(SIMD2<Float>.self, count: n)
        let zBuf = try context.makeBuffer(Float.self, count: 1)

        let pValBuf = try context.makeBuffer(Float.self, count: affinities.values.count,
                                             from: affinities.values)
        let colBuf = try context.makeBuffer(UInt32.self, count: affinities.colIndex.count,
                                            from: affinities.colIndex)
        let rowBuf = try context.makeBuffer(UInt32.self, count: affinities.rowStart.count,
                                            from: affinities.rowStart)

        var nVar = UInt32(n)
        let lr = Float(parameters.resolvedLearningRate(pointCount: n))
        let earlyIters = parameters.earlyExaggerationIterations
        let totalIters = parameters.iterations

        let tgSize = 256
        let groups = (n + tgSize - 1) / tgSize
        let gridGroups = MTLSize(width: groups, height: 1, depth: 1)
        let tgGroup = MTLSize(width: tgSize, height: 1, depth: 1)
        // The repulsive kernel processes `bodiesPerThread` points per thread.
        let bodiesPerThread = 4
        let repThreads = (n + bodiesPerThread - 1) / bodiesPerThread
        let repGroups = MTLSize(width: (repThreads + tgSize - 1) / tgSize, height: 1, depth: 1)

        let reportEvery = max(1, min(25, totalIters))
        var iter = 0
        while iter < totalIters {
            let batchEnd = min(iter + reportEvery, totalIters)
            guard let cb = context.queue.makeCommandBuffer(),
                  let enc = cb.makeComputeCommandEncoder() else {
                throw TSNEError.bufferAllocationFailed
            }
            for it in iter..<batchEnd {
                let inEarly = it < earlyIters
                var apply = ApplyParams(
                    n: UInt32(n),
                    learningRate: lr,
                    momentum: Float(inEarly ? parameters.initialMomentum : parameters.finalMomentum),
                    exaggeration: Float(inEarly ? parameters.earlyExaggeration : 1.0),
                    minGain: 0.01)

                // (a) zero Z
                enc.setComputePipelineState(clearPipe)
                enc.setBuffer(zBuf, offset: 0, index: 0)
                enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))

                // (b) repulsive + Z
                enc.setComputePipelineState(repPipe)
                enc.setBuffer(posBuf, offset: 0, index: 0)
                enc.setBuffer(repBuf, offset: 0, index: 1)
                enc.setBuffer(zBuf, offset: 0, index: 2)
                enc.setBytes(&nVar, length: MemoryLayout<UInt32>.stride, index: 3)
                enc.setThreadgroupMemoryLength(tgSize * MemoryLayout<SIMD2<Float>>.stride, index: 0)
                enc.setThreadgroupMemoryLength(tgSize * MemoryLayout<Float>.stride, index: 1)
                enc.dispatchThreadgroups(repGroups, threadsPerThreadgroup: tgGroup)

                // (c) attractive
                enc.setComputePipelineState(attrPipe)
                enc.setBuffer(posBuf, offset: 0, index: 0)
                enc.setBuffer(pValBuf, offset: 0, index: 1)
                enc.setBuffer(colBuf, offset: 0, index: 2)
                enc.setBuffer(rowBuf, offset: 0, index: 3)
                enc.setBuffer(attrBuf, offset: 0, index: 4)
                enc.setBytes(&nVar, length: MemoryLayout<UInt32>.stride, index: 5)
                enc.dispatchThreadgroups(gridGroups, threadsPerThreadgroup: tgGroup)

                // (d) apply
                enc.setComputePipelineState(applyPipe)
                enc.setBuffer(posBuf, offset: 0, index: 0)
                enc.setBuffer(velBuf, offset: 0, index: 1)
                enc.setBuffer(gainBuf, offset: 0, index: 2)
                enc.setBuffer(attrBuf, offset: 0, index: 3)
                enc.setBuffer(repBuf, offset: 0, index: 4)
                enc.setBuffer(zBuf, offset: 0, index: 5)
                enc.setBytes(&apply, length: MemoryLayout<ApplyParams>.stride, index: 6)
                enc.dispatchThreadgroups(gridGroups, threadsPerThreadgroup: tgGroup)

                _ = it
            }
            enc.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            iter = batchEnd

            if let onProgress {
                let pts = posBuf.array(SIMD2<Float>.self, count: n)
                onProgress(TSNEProgress(iteration: iter, totalIterations: totalIters, positions: pts))
            }
        }

        return posBuf.array(SIMD2<Float>.self, count: n)
    }

    // MARK: - Field-splatting optimizer

    /// Whether `.auto`/`.field` should use the field method for `count` points.
    private func resolveUseField(count n: Int) -> Bool {
        switch parameters.optimizer {
        case .exact: return false
        case .field: return true
        case .auto: return n > parameters.autoFastThreshold
        }
    }

    /// Linear-time optimizer: replaces the N-body repulsive pass with kernel
    /// splatting into a field + bilinear sampling. Reuses the attractive and
    /// apply kernels unchanged.
    private func optimizeField(
        initial: [SIMD2<Float>],
        affinities: SparseAffinities,
        count n: Int,
        onProgress: (@Sendable (TSNEProgress) -> Void)?
    ) throws -> [SIMD2<Float>] {
        let reduce1 = try context.pipeline("tsne_reduce_bounds_stage1")
        let reduce2 = try context.pipeline("tsne_reduce_bounds_stage2")
        let samplePipe = try context.pipeline("tsne_field_sample")
        let attrPipe = try context.pipeline("tsne_attractive")
        let applyPipe = try context.pipeline("tsne_apply")
        let clearPipe = try context.pipeline("tsne_clear_scalar")
        let splatPipe = try context.renderPipeline(vertex: "splat_vertex",
                                                   fragment: "splat_fragment",
                                                   pixelFormat: .rgba16Float)

        let posBuf = try context.makeBuffer(SIMD2<Float>.self, count: n, from: initial)
        let velBuf = try context.makeBuffer(SIMD2<Float>.self, count: n,
                                            from: [SIMD2<Float>](repeating: .zero, count: n))
        let gainBuf = try context.makeBuffer(SIMD2<Float>.self, count: n,
                                             from: [SIMD2<Float>](repeating: SIMD2(1, 1), count: n))
        let attrBuf = try context.makeBuffer(SIMD2<Float>.self, count: n)
        let repBuf = try context.makeBuffer(SIMD2<Float>.self, count: n)
        let zBuf = try context.makeBuffer(Float.self, count: 1)
        let pValBuf = try context.makeBuffer(Float.self, count: affinities.values.count, from: affinities.values)
        let colBuf = try context.makeBuffer(UInt32.self, count: affinities.colIndex.count, from: affinities.colIndex)
        let rowBuf = try context.makeBuffer(UInt32.self, count: affinities.rowStart.count, from: affinities.rowStart)

        let tgSize = 256
        let groups = (n + tgSize - 1) / tgSize
        let gridGroups = MTLSize(width: groups, height: 1, depth: 1)
        let tgGroup = MTLSize(width: tgSize, height: 1, depth: 1)

        // Field resources.
        let R = MetalContext.fieldResolution(count: n)
        let kernelTex = try context.makeKernelTexture()
        let fieldTex = try context.makeFieldTexture(resolution: R)
        let reduceGroups = groups
        let partialsBuf = try context.makeBuffer(SIMD4<Float>.self, count: reduceGroups)
        let transformBuf = try context.makeBuffer(SIMD4<Float>.self, count: 1)
        var resVar = UInt32(R)
        var numPartialsVar = UInt32(reduceGroups)
        var nVar = UInt32(n)

        let fieldPass = MTLRenderPassDescriptor()
        fieldPass.colorAttachments[0].texture = fieldTex
        fieldPass.colorAttachments[0].loadAction = .clear
        fieldPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        fieldPass.colorAttachments[0].storeAction = .store

        let lr = Float(parameters.resolvedLearningRate(pointCount: n))
        let earlyIters = parameters.earlyExaggerationIterations
        let totalIters = parameters.iterations
        // Stream ~every 25 iters when a progress handler is set; otherwise batch
        // larger to cut GPU/CPU sync overhead.
        let reportEvery = max(1, min(onProgress == nil ? 150 : 25, totalIters))

        var iter = 0
        while iter < totalIters {
            let batchEnd = min(iter + reportEvery, totalIters)
            guard let cb = context.queue.makeCommandBuffer() else {
                throw TSNEError.bufferAllocationFailed
            }
            for it in iter..<batchEnd {
                let inEarly = it < earlyIters
                var apply = ApplyParams(
                    n: UInt32(n),
                    learningRate: lr,
                    momentum: Float(inEarly ? parameters.initialMomentum : parameters.finalMomentum),
                    exaggeration: Float(inEarly ? parameters.earlyExaggeration : 1.0),
                    minGain: 0.01)

                // --- compute: bounds reduction (→ transform) + clear Z ---
                guard let ce1 = cb.makeComputeCommandEncoder() else { throw TSNEError.bufferAllocationFailed }
                ce1.setComputePipelineState(reduce1)
                ce1.setBuffer(posBuf, offset: 0, index: 0)
                ce1.setBuffer(partialsBuf, offset: 0, index: 1)
                ce1.setBytes(&nVar, length: MemoryLayout<UInt32>.stride, index: 2)
                ce1.setThreadgroupMemoryLength(tgSize * MemoryLayout<SIMD2<Float>>.stride, index: 0)
                ce1.setThreadgroupMemoryLength(tgSize * MemoryLayout<SIMD2<Float>>.stride, index: 1)
                ce1.dispatchThreadgroups(MTLSize(width: reduceGroups, height: 1, depth: 1), threadsPerThreadgroup: tgGroup)

                ce1.setComputePipelineState(reduce2)
                ce1.setBuffer(partialsBuf, offset: 0, index: 0)
                ce1.setBuffer(transformBuf, offset: 0, index: 1)
                ce1.setBytes(&numPartialsVar, length: MemoryLayout<UInt32>.stride, index: 2)
                ce1.setBytes(&resVar, length: MemoryLayout<UInt32>.stride, index: 3)
                ce1.setThreadgroupMemoryLength(tgSize * MemoryLayout<SIMD4<Float>>.stride, index: 0)
                ce1.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: tgGroup)

                ce1.setComputePipelineState(clearPipe)
                ce1.setBuffer(zBuf, offset: 0, index: 0)
                ce1.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
                ce1.endEncoding()

                // --- render: splat kernel field (clears via loadAction) ---
                guard let re = cb.makeRenderCommandEncoder(descriptor: fieldPass) else { throw TSNEError.bufferAllocationFailed }
                re.setRenderPipelineState(splatPipe)
                re.setVertexBuffer(posBuf, offset: 0, index: 0)
                re.setVertexBuffer(transformBuf, offset: 0, index: 1)
                re.setVertexBytes(&resVar, length: MemoryLayout<UInt32>.stride, index: 2)
                re.setFragmentTexture(kernelTex, index: 0)
                re.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: n)
                re.endEncoding()

                // --- compute: sample field → repForce + Z, then attractive + apply ---
                guard let ce2 = cb.makeComputeCommandEncoder() else { throw TSNEError.bufferAllocationFailed }
                ce2.setComputePipelineState(samplePipe)
                ce2.setBuffer(posBuf, offset: 0, index: 0)
                ce2.setBuffer(repBuf, offset: 0, index: 1)
                ce2.setBuffer(zBuf, offset: 0, index: 2)
                ce2.setBuffer(transformBuf, offset: 0, index: 3)
                ce2.setBytes(&resVar, length: MemoryLayout<UInt32>.stride, index: 4)
                ce2.setBytes(&nVar, length: MemoryLayout<UInt32>.stride, index: 5)
                ce2.setTexture(fieldTex, index: 0)
                ce2.setThreadgroupMemoryLength(tgSize * MemoryLayout<Float>.stride, index: 0)
                ce2.dispatchThreadgroups(gridGroups, threadsPerThreadgroup: tgGroup)

                ce2.setComputePipelineState(attrPipe)
                ce2.setBuffer(posBuf, offset: 0, index: 0)
                ce2.setBuffer(pValBuf, offset: 0, index: 1)
                ce2.setBuffer(colBuf, offset: 0, index: 2)
                ce2.setBuffer(rowBuf, offset: 0, index: 3)
                ce2.setBuffer(attrBuf, offset: 0, index: 4)
                ce2.setBytes(&nVar, length: MemoryLayout<UInt32>.stride, index: 5)
                ce2.dispatchThreadgroups(gridGroups, threadsPerThreadgroup: tgGroup)

                ce2.setComputePipelineState(applyPipe)
                ce2.setBuffer(posBuf, offset: 0, index: 0)
                ce2.setBuffer(velBuf, offset: 0, index: 1)
                ce2.setBuffer(gainBuf, offset: 0, index: 2)
                ce2.setBuffer(attrBuf, offset: 0, index: 3)
                ce2.setBuffer(repBuf, offset: 0, index: 4)
                ce2.setBuffer(zBuf, offset: 0, index: 5)
                ce2.setBytes(&apply, length: MemoryLayout<ApplyParams>.stride, index: 6)
                ce2.dispatchThreadgroups(gridGroups, threadsPerThreadgroup: tgGroup)
                ce2.endEncoding()
            }
            cb.commit()
            cb.waitUntilCompleted()
            iter = batchEnd

            if let onProgress {
                let pts = posBuf.array(SIMD2<Float>.self, count: n)
                onProgress(TSNEProgress(iteration: iter, totalIterations: totalIters, positions: pts))
            }
        }

        return posBuf.array(SIMD2<Float>.self, count: n)
    }
}
