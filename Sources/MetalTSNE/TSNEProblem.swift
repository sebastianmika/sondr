import Foundation
import simd

/// A t-SNE input whose dimensionality reduction, neighbor search, and
/// affinity calibration have already been completed.
///
/// A prepared problem can create multiple independent optimization sessions
/// without repeating PCA, KNN, or affinity construction.
public final class TSNEProblem: @unchecked Sendable {
    public let pointCount: Int
    public let affinities: TSNEAffinityGraph

    let context: MetalContext
    let parameters: TSNEParameters
    let defaultPositions: [SIMD2<Float>]
    let referenceWork: [Float]
    let workDimensions: Int
    let inputDimensions: Int
    let pcaBasis: PCABasis?
    let preparationStatistics: TSNEStatistics
    let useFieldOptimizer: Bool

    init(
        context: MetalContext,
        parameters: TSNEParameters,
        affinities: TSNEAffinityGraph,
        defaultPositions: [SIMD2<Float>],
        referenceWork: [Float],
        workDimensions: Int,
        inputDimensions: Int,
        pcaBasis: PCABasis?,
        preparationStatistics: TSNEStatistics,
        useFieldOptimizer: Bool
    ) {
        self.context = context
        self.parameters = parameters
        self.pointCount = affinities.pointCount
        self.affinities = affinities
        self.defaultPositions = defaultPositions
        self.referenceWork = referenceWork
        self.workDimensions = workDimensions
        self.inputDimensions = inputDimensions
        self.pcaBasis = pcaBasis
        self.preparationStatistics = preparationStatistics
        self.useFieldOptimizer = useFieldOptimizer
    }

    /// Creates an independently mutable optimizer using this problem's already
    /// prepared affinities and working-space data.
    ///
    /// When `initialPositions` is omitted, the initialization configured in the
    /// source ``TSNEParameters`` is used. Supplied coordinates are raw
    /// MetalTSNE embedding coordinates, not viewport-normalized positions.
    public func makeSession(
        initialPositions: [SIMD2<Float>]? = nil
    ) throws -> TSNEEmbeddingSession {
        let positions = initialPositions ?? defaultPositions
        guard positions.count == pointCount else {
            throw TSNEError.invalidInput(
                "initialPositions must contain exactly \(pointCount) coordinates")
        }
        guard positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw TSNEError.invalidInput("initialPositions must contain only finite coordinates")
        }
        return try TSNEEmbeddingSession(problem: self, initialPositions: positions)
    }

    /// Creates a live session and runs the full initial t-SNE schedule captured
    /// when this problem was prepared.
    ///
    /// Unlike calling ``TSNE/fit(data:onProgress:)`` and then preparing the
    /// same data again, this method reuses this problem's PCA, KNN, and affinity
    /// results. The returned session retains its positions, momentum, adaptive
    /// gains, and Metal resources, so it can immediately be guided with
    /// ``TSNEEmbeddingSession/setAffinityPair(base:guided:)`` or advanced with
    /// ``TSNEEmbeddingSession/step(iterations:options:)``.
    ///
    /// The initial optimization uses the same learning rate, early
    /// exaggeration, and momentum phases as the one-shot fitting APIs. Work is
    /// submitted in short batches so Swift task cancellation is observed at a
    /// bounded command-buffer boundary. Cancellation throws
    /// `CancellationError` and does not return a partially fitted session.
    ///
    /// - Parameter onProgress: Receives a snapshot after each optimization
    ///   batch.
    /// - Returns: A fully optimized, still-mutable embedding session.
    public func makeFittedSession(
        onProgress: (@Sendable (TSNEProgress) -> Void)? = nil
    ) async throws -> TSNEEmbeddingSession {
        try Task.checkCancellation()
        try validateInitialSchedule()

        let session = try makeSession()
        try Task.checkCancellation()

        let total = parameters.iterations
        guard pointCount > 1, total > 0 else { return session }

        let learningRate = parameters.resolvedLearningRate(pointCount: pointCount)
        let earlyEnd = min(total, parameters.earlyExaggerationIterations)
        let progressBatchSize = 25
        let commandBufferBatchSize = 10
        var iteration = 0

        while iteration < total {
            try Task.checkCancellation()

            let inEarlyPhase = iteration < earlyEnd
            let phaseEnd = inEarlyPhase ? earlyEnd : total
            let batchCount = min(progressBatchSize, phaseEnd - iteration)
            let options = TSNEStepOptions(
                learningRate: learningRate,
                momentum: inEarlyPhase
                    ? parameters.initialMomentum : parameters.finalMomentum,
                exaggeration: inEarlyPhase ? parameters.earlyExaggeration : 1,
                maximumStepNorm: nil,
                dynamicsPolicy: .preserve,
                commandBufferIterations: min(commandBufferBatchSize, batchCount))

            let snapshot = try await session.step(
                iterations: batchCount,
                options: options)
            iteration += batchCount

            try Task.checkCancellation()
            onProgress?(TSNEProgress(
                iteration: iteration,
                totalIterations: total,
                positions: snapshot.positions))
            try Task.checkCancellation()
        }

        return session
    }

    private func validateInitialSchedule() throws {
        guard parameters.iterations >= 0 else {
            throw TSNEError.invalidInput("iterations must be nonnegative")
        }
        guard parameters.earlyExaggerationIterations >= 0 else {
            throw TSNEError.invalidInput("earlyExaggerationIterations must be nonnegative")
        }
        guard parameters.earlyExaggeration.isFinite,
              parameters.earlyExaggeration >= 0,
              Float(parameters.earlyExaggeration).isFinite else {
            throw TSNEError.invalidInput("earlyExaggeration must be finite and nonnegative")
        }
        guard parameters.initialMomentum.isFinite,
              (0...1).contains(parameters.initialMomentum),
              parameters.finalMomentum.isFinite,
              (0...1).contains(parameters.finalMomentum) else {
            throw TSNEError.invalidInput("optimizer momentum must be finite and within 0...1")
        }
        let learningRate = parameters.resolvedLearningRate(pointCount: pointCount)
        guard learningRate.isFinite, learningRate > 0, Float(learningRate).isFinite else {
            throw TSNEError.invalidInput("learningRate must resolve to a finite positive value")
        }
    }
}
