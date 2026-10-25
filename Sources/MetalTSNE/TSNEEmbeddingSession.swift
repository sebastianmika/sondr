import Foundation
import Metal
import simd

/// A quadratic soft constraint that stabilizes an embedding around reference
/// coordinates or gives selected points stronger landmark behavior.
public struct TSNEPositionPrior: Sendable {
    public var targets: [SIMD2<Float>]
    public var weights: [Float]
    public var strength: Float

    public init(
        targets: [SIMD2<Float>],
        weights: [Float],
        strength: Float
    ) {
        self.targets = targets
        self.weights = weights
        self.strength = strength
    }
}

/// How retained momentum and adaptive gains are treated at the start of a
/// bounded optimization call.
public enum TSNEDynamicsPolicy: Sendable {
    case preserve
    case resetVelocity
    case resetAll
}

/// Controls one bounded call to ``TSNEEmbeddingSession/step(iterations:options:)``.
public struct TSNEStepOptions: Sendable {
    /// `nil` uses the learning rate captured from the prepared problem.
    public var learningRate: Double?
    public var momentum: Double
    public var exaggeration: Double
    /// A cap on each point's final momentum update. `nil` disables clipping;
    /// zero freezes positions while still updating adaptive gains.
    public var maximumStepNorm: Float?
    public var dynamicsPolicy: TSNEDynamicsPolicy
    /// Maximum optimizer iterations encoded into one Metal command buffer and
    /// therefore the upper bound between cancellation checks.
    public var commandBufferIterations: Int

    public init(
        learningRate: Double? = nil,
        momentum: Double = 0.8,
        exaggeration: Double = 1,
        maximumStepNorm: Float? = 1,
        dynamicsPolicy: TSNEDynamicsPolicy = .preserve,
        commandBufferIterations: Int = 10
    ) {
        self.learningRate = learningRate
        self.momentum = momentum
        self.exaggeration = exaggeration
        self.maximumStepNorm = maximumStepNorm
        self.dynamicsPolicy = dynamicsPolicy
        self.commandBufferIterations = commandBufferIterations
    }

    /// Defaults for responsive re-optimization: no early exaggeration,
    /// retained dynamics, per-point update clipping, and short GPU batches.
    public static var interactive: Self { Self() }
}

/// A CPU-visible, internally consistent view of a session at a completed Metal
/// command-buffer boundary.
public struct TSNESnapshot: Sendable {
    public let positions: [SIMD2<Float>]
    public let completedIterations: Int
    /// Root-mean-square point update in the most recently completed iteration.
    public let rmsStep: Float
    /// Largest point update in the most recently completed iteration.
    public let maximumStep: Float

    public init(
        positions: [SIMD2<Float>],
        completedIterations: Int,
        rmsStep: Float,
        maximumStep: Float
    ) {
        self.positions = positions
        self.completedIterations = completedIterations
        self.rmsStep = rmsStep
        self.maximumStep = maximumStep
    }
}

private final class StepCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled: Bool

    init(cancelled: Bool) {
        self.cancelled = cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        let result = cancelled
        lock.unlock()
        return result
    }
}

/// Bridges a synchronous objective setter across the session's serial queue.
/// The semaphore establishes the happens-before edge for the protected result;
/// the lock keeps the storage race-free under Swift's strict concurrency model.
private final class ObjectiveMutationCompletion: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<Void, Error>?

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
        semaphore.signal()
    }

    func wait() throws {
        semaphore.wait()
        lock.lock()
        let result = self.result
        lock.unlock()
        try result!.get()
    }
}

private struct SessionAffinityResources {
    let rowOffsets: MTLBuffer
    let columnIndices: MTLBuffer
    let edgeValues: MTLBuffer
    let edgeCount: Int
}

private struct SessionFieldResources {
    let reduceBoundsStage1: MTLComputePipelineState
    let reduceBoundsStage2: MTLComputePipelineState
    let sampleField: MTLComputePipelineState
    let splat: MTLRenderPipelineState
    let kernelTexture: MTLTexture
    let fieldTexture: MTLTexture
    let partials: MTLBuffer
    let transform: MTLBuffer
    let renderPass: MTLRenderPassDescriptor
    let resolution: Int
    let partialCount: Int
}

private struct SessionApplyParams {
    var n: UInt32
    var learningRate: Float
    var momentum: Float
    var exaggeration: Float
    var minGain: Float
    var priorStrengthOverN: Float
    var maximumStepNorm: Float
    var flags: UInt32
}

private struct SessionResetParams {
    var n: UInt32
    var resetGains: UInt32
}

/// Internal instrumentation used by acceptance tests to prove that bounded
/// steps and mix changes do not rebuild session-sized resources.
struct TSNESessionDebugDiagnostics: Sendable {
    let largeResourceGeneration: Int
    let affinityUnionBuildCount: Int
    let affinityEdgeCount: Int
    let mixUpdateCount: Int
    let positionReadbackCount: Int
    let commandBufferBatchSizes: [Int]
    let usesFieldOptimizer: Bool
}

/// A mutable, single-writer t-SNE optimizer that retains its Metal buffers and
/// dynamics across bounded calls.
///
/// Mutable Metal operations are serialized on a private queue. Changing the
/// objective with ``setAffinityPair(base:guided:)``, ``setAffinityMix(_:)``,
/// ``setPositionPrior(_:)``, or ``setPositionPriorStrength(_:)`` invalidates
/// every `step` call scheduled before that mutation. An active step stops after
/// its current command-buffer boundary, queued steps stop before encoding work,
/// and the setter applies the new objective only after those calls have exited.
public final class TSNEEmbeddingSession: @unchecked Sendable {
    public let pointCount: Int

    private let problem: TSNEProblem
    private let context: MetalContext
    private let executionQueue: DispatchQueue
    /// Linearizes step registration with objective-mutation barriers without
    /// waiting for the Metal execution queue.
    private let schedulingLock = NSLock()
    private let usesFieldOptimizer: Bool

    private let clearScalarPipeline: MTLComputePipelineState
    private let clearMetricsPipeline: MTLComputePipelineState
    private let attractivePipeline: MTLComputePipelineState
    private let applyPipeline: MTLComputePipelineState
    private let resetPipeline: MTLComputePipelineState
    private let exactRepulsivePipeline: MTLComputePipelineState?
    private let fieldResources: SessionFieldResources?

    private let positionBuffer: MTLBuffer
    private let velocityBuffer: MTLBuffer
    private let gainBuffer: MTLBuffer
    private let attractiveForceBuffer: MTLBuffer
    private let repulsiveForceBuffer: MTLBuffer
    private let normalizationBuffer: MTLBuffer
    private let alphaBuffer: MTLBuffer
    private let priorTargetBuffer: MTLBuffer
    private let priorWeightBuffer: MTLBuffer
    private let squaredStepSumBuffer: MTLBuffer
    private let maximumStepBitsBuffer: MTLBuffer

    private var affinityResources: SessionAffinityResources
    private var priorStrength: Float = 0
    private var completedIterationsStorage = 0
    private var statisticsStorage: TSNEStatistics
    private var terminalError: TSNEError?
    private var pendingStepTokens: [UUID: StepCancellationToken] = [:]

    private var largeResourceGeneration = 1
    private var affinityUnionBuildCount = 1
    private var mixUpdateCount = 0
    private var positionReadbackCount = 0
    private var commandBufferBatchSizes: [Int] = []
    private var debugBoundaryHook: (@Sendable (Int) -> Void)?
    private var debugStepScheduledHook: (@Sendable (Int) -> Void)?
    private var debugObjectiveMutationCancellationHook: (@Sendable (Int) -> Void)?

    init(problem: TSNEProblem, initialPositions: [SIMD2<Float>]) throws {
        self.problem = problem
        self.context = problem.context
        self.pointCount = problem.pointCount
        self.usesFieldOptimizer = problem.useFieldOptimizer
        self.executionQueue = DispatchQueue(
            label: "MetalTSNE.embedding-session.\(UUID().uuidString)")
        self.statisticsStorage = problem.preparationStatistics

        clearScalarPipeline = try context.pipeline("tsne_clear_scalar")
        clearMetricsPipeline = try context.pipeline("tsne_clear_step_metrics")
        attractivePipeline = try context.pipeline("tsne_attractive_blended")
        applyPipeline = try context.pipeline("tsne_apply_interactive")
        resetPipeline = try context.pipeline("tsne_reset_dynamics")

        positionBuffer = try context.makeBuffer(
            SIMD2<Float>.self, count: pointCount, from: initialPositions)
        velocityBuffer = try context.makeBuffer(
            SIMD2<Float>.self, count: pointCount,
            from: [SIMD2<Float>](repeating: .zero, count: pointCount))
        gainBuffer = try context.makeBuffer(
            SIMD2<Float>.self, count: pointCount,
            from: [SIMD2<Float>](repeating: SIMD2(1, 1), count: pointCount))
        attractiveForceBuffer = try context.makeBuffer(SIMD2<Float>.self, count: pointCount)
        repulsiveForceBuffer = try context.makeBuffer(SIMD2<Float>.self, count: pointCount)
        normalizationBuffer = try context.makeBuffer(Float.self, count: 1, from: [0])
        alphaBuffer = try context.makeBuffer(Float.self, count: 1, from: [0])
        priorTargetBuffer = try context.makeBuffer(
            SIMD2<Float>.self, count: pointCount,
            from: [SIMD2<Float>](repeating: .zero, count: pointCount))
        priorWeightBuffer = try context.makeBuffer(
            Float.self, count: pointCount,
            from: [Float](repeating: 0, count: pointCount))
        squaredStepSumBuffer = try context.makeBuffer(Float.self, count: 1, from: [0])
        maximumStepBitsBuffer = try context.makeBuffer(UInt32.self, count: 1, from: [0])
        affinityResources = try Self.makeAffinityResources(
            context: context, base: problem.affinities, guided: problem.affinities)

        if usesFieldOptimizer {
            exactRepulsivePipeline = nil
            fieldResources = try Self.makeFieldResources(context: context, pointCount: pointCount)
        } else {
            exactRepulsivePipeline = try context.pipeline("tsne_repulsive")
            fieldResources = nil
        }
    }

    public var completedIterations: Int {
        executionQueue.sync { completedIterationsStorage }
    }

    /// Returns the most recently completed optimizer state. If a step is in
    /// flight, this call serializes behind its current bounded work.
    public func snapshot() throws -> TSNESnapshot {
        try executionQueue.sync {
            try ensureUsable()
            return try makeSnapshot()
        }
    }

    /// Advances the retained embedding without rebuilding preparation state or
    /// reallocating session-sized resources.
    ///
    /// Cancellation is observed before the first command buffer and after every
    /// completed command-buffer boundary. A cancelled call throws
    /// `CancellationError`; call ``snapshot()`` to retrieve the valid partial
    /// result. Changing the affinity pair, affinity mix, or position prior also
    /// cancels this call if the change is scheduled before this call finishes.
    public func step(
        iterations: Int,
        options: TSNEStepOptions = .interactive
    ) async throws -> TSNESnapshot {
        let identifier = UUID()
        let token = StepCancellationToken(cancelled: Task.isCancelled)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                schedulingLock.lock()
                pendingStepTokens[identifier] = token
                let pendingCount = pendingStepTokens.count
                let scheduledHook = debugStepScheduledHook
                executionQueue.async { [self, identifier, token] in
                    defer { unregisterStep(identifier) }
                    do {
                        continuation.resume(returning: try runInteractiveStep(
                            iterations: iterations, options: options,
                            cancellation: token))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                schedulingLock.unlock()
                scheduledHook?(pendingCount)
            }
        } onCancel: {
            token.cancel()
        }
    }

    /// Replaces the two graphs whose union supplies attractive forces. Union
    /// compilation and allocation happen once here; later alpha updates are
    /// constant-time scalar writes. A valid call cancels every active or queued
    /// `step` scheduled before it and waits at most for the active step's current
    /// command-buffer boundary before beginning the replacement.
    public func setAffinityPair(
        base: TSNEAffinityGraph,
        guided: TSNEAffinityGraph
    ) throws {
        guard base.pointCount == pointCount, guided.pointCount == pointCount else {
            throw TSNEError.invalidInput(
                "both affinity graphs must contain exactly \(pointCount) points")
        }
        try performObjectiveMutation { [self] in
            try ensureUsable()
            affinityResources = try Self.makeAffinityResources(
                context: context, base: base, guided: guided)
            affinityUnionBuildCount += 1
            largeResourceGeneration += 1
        }
    }

    /// Sets the affinity mixture weight. Values outside `0...1`, including NaN,
    /// are rejected. This performs one scalar write and no CSR work. A valid call
    /// cancels every active or queued `step` scheduled before it and applies the
    /// new value after the active step's current command-buffer boundary.
    public func setAffinityMix(_ alpha: Float) throws {
        guard alpha.isFinite, (0...1).contains(alpha) else {
            throw TSNEError.invalidInput("affinity alpha must be finite and within 0...1")
        }
        try performObjectiveMutation { [self] in
            try ensureUsable()
            alphaBuffer.pointer(Float.self).pointee = alpha
            mixUpdateCount += 1
        }
    }

    /// Installs or removes a raw-coordinate position prior. Buffers are retained
    /// and updated in place; removing a prior only sets its strength to zero. A
    /// valid call cancels every active or queued `step` scheduled before it and
    /// applies the prior after the active step's current command-buffer boundary.
    public func setPositionPrior(_ prior: TSNEPositionPrior?) throws {
        if let prior {
            guard prior.targets.count == pointCount else {
                throw TSNEError.invalidInput(
                    "position-prior targets must contain exactly \(pointCount) coordinates")
            }
            guard prior.weights.count == pointCount else {
                throw TSNEError.invalidInput(
                    "position-prior weights must contain exactly \(pointCount) values")
            }
            guard prior.targets.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
                throw TSNEError.invalidInput("position-prior targets must be finite")
            }
            guard prior.weights.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                throw TSNEError.invalidInput(
                    "position-prior weights must be finite and nonnegative")
            }
            guard prior.strength.isFinite, prior.strength >= 0 else {
                throw TSNEError.invalidInput(
                    "position-prior strength must be finite and nonnegative")
            }
        }
        try performObjectiveMutation { [self] in
            try ensureUsable()
            guard let prior else {
                priorStrength = 0
                return
            }
            Self.copy(prior.targets, to: priorTargetBuffer)
            Self.copy(prior.weights, to: priorWeightBuffer)
            priorStrength = prior.strength
        }
    }

    /// Changes only the scalar strength of the currently installed position
    /// prior. Targets and weights remain resident, so interactive applications
    /// can fade geometric guidance without uploading `O(pointCount)` buffers.
    /// A valid call cancels every active or queued `step` scheduled before it
    /// and applies after the active command-buffer boundary.
    public func setPositionPriorStrength(_ strength: Float) throws {
        guard strength.isFinite, strength >= 0 else {
            throw TSNEError.invalidInput(
                "position-prior strength must be finite and nonnegative")
        }
        try performObjectiveMutation { [self] in
            try ensureUsable()
            priorStrength = strength
        }
    }

    /// Clears velocity and restores all adaptive gains to one.
    public func resetDynamics() {
        executionQueue.sync {
            guard terminalError == nil else { return }
            Self.fillDynamics(
                velocity: velocityBuffer, gains: gainBuffer,
                count: pointCount, resetGains: true)
            squaredStepSumBuffer.pointer(Float.self).pointee = 0
            maximumStepBitsBuffer.pointer(UInt32.self).pointee = 0
        }
    }

    /// Freezes the session's current positions into a normal immutable model.
    public func makeModel() throws -> TSNEModel {
        try executionQueue.sync {
            try ensureUsable()
            let positions = try readPositions()
            return TSNEModel(
                context: context,
                parameters: problem.parameters,
                embedding: positions,
                referenceWork: problem.referenceWork,
                workDimensions: problem.workDimensions,
                inputDimensions: problem.inputDimensions,
                pcaBasis: problem.pcaBasis,
                fitStatistics: statisticsStorage)
        }
    }

    // MARK: - One-shot compatibility

    /// Synchronous initial schedule shared by the legacy `fit` APIs.
    func runInitialSchedule(
        onProgress: (@Sendable (TSNEProgress) -> Void)?
    ) throws {
        try executionQueue.sync {
            try ensureUsable()
            let parameters = problem.parameters
            try Self.validateInitialSchedule(parameters, pointCount: pointCount)

            // Preserve the existing singleton fast path: no optimizer resources
            // need to run to know its only possible coordinate.
            guard pointCount > 1, parameters.iterations > 0 else { return }

            let clock = ContinuousClock()
            let started = clock.now
            defer {
                let elapsed = started.duration(to: clock.now)
                let seconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) * 1e-18
                statisticsStorage.optimizeSeconds += seconds
                statisticsStorage.totalSeconds = problem.preparationStatistics.totalSeconds
                    + statisticsStorage.optimizeSeconds
            }

            let batchLimit = usesFieldOptimizer && onProgress == nil ? 150 : 25
            let total = parameters.iterations
            let learningRate = Float(parameters.resolvedLearningRate(pointCount: pointCount))
            var iteration = 0

            while iteration < total {
                let batchCount = min(batchLimit, total - iteration)
                var applyParameters: [SessionApplyParams] = []
                applyParameters.reserveCapacity(batchCount)
                for offset in 0..<batchCount {
                    let absolute = iteration + offset
                    let inEarly = absolute < parameters.earlyExaggerationIterations
                    applyParameters.append(SessionApplyParams(
                        n: UInt32(pointCount),
                        learningRate: learningRate,
                        momentum: Float(inEarly
                            ? parameters.initialMomentum : parameters.finalMomentum),
                        exaggeration: Float(inEarly
                            ? parameters.earlyExaggeration : 1),
                        minGain: 0.01,
                        priorStrengthOverN: 0,
                        maximumStepNorm: 0,
                        flags: 0))
                }

                let commandBuffer = try makeCommandBuffer()
                try encodeBatch(
                    applyParameters: applyParameters,
                    dynamicsPolicy: .preserve,
                    commandBuffer: commandBuffer)
                try commitAndWait(commandBuffer)
                completedIterationsStorage += batchCount
                recordBatchSize(batchCount)
                iteration += batchCount

                if let onProgress {
                    let positions = try readPositions()
                    onProgress(TSNEProgress(
                        iteration: iteration,
                        totalIterations: total,
                        positions: positions))
                }
            }
        }
    }

    func statisticsSnapshot() -> TSNEStatistics {
        executionQueue.sync { statisticsStorage }
    }

    var _debugDiagnostics: TSNESessionDebugDiagnostics {
        executionQueue.sync {
            TSNESessionDebugDiagnostics(
                largeResourceGeneration: largeResourceGeneration,
                affinityUnionBuildCount: affinityUnionBuildCount,
                affinityEdgeCount: affinityResources.edgeCount,
                mixUpdateCount: mixUpdateCount,
                positionReadbackCount: positionReadbackCount,
                commandBufferBatchSizes: commandBufferBatchSizes,
                usesFieldOptimizer: usesFieldOptimizer)
        }
    }

    var _debugAfterCommandBufferBoundary: (@Sendable (Int) -> Void)? {
        get { executionQueue.sync { debugBoundaryHook } }
        set { executionQueue.sync { debugBoundaryHook = newValue } }
    }

    /// Reports the number of registered active/queued steps after each step is
    /// atomically placed on the execution queue.
    var _debugAfterStepScheduled: (@Sendable (Int) -> Void)? {
        get {
            schedulingLock.lock()
            defer { schedulingLock.unlock() }
            return debugStepScheduledHook
        }
        set {
            schedulingLock.lock()
            debugStepScheduledHook = newValue
            schedulingLock.unlock()
        }
    }

    /// Reports how many registered steps an objective mutation invalidated.
    var _debugAfterObjectiveMutationCancellation: (@Sendable (Int) -> Void)? {
        get {
            schedulingLock.lock()
            defer { schedulingLock.unlock() }
            return debugObjectiveMutationCancellationHook
        }
        set {
            schedulingLock.lock()
            debugObjectiveMutationCancellationHook = newValue
            schedulingLock.unlock()
        }
    }

    // MARK: - Interactive runner

    /// Atomically orders an objective change against step registration. The
    /// scheduling lock is never held while waiting for Metal work, so active
    /// work can observe cancellation at its next bounded boundary.
    private func performObjectiveMutation(
        _ mutation: @escaping @Sendable () throws -> Void
    ) throws {
        let completion = ObjectiveMutationCompletion()

        schedulingLock.lock()
        let tokens = Array(pendingStepTokens.values)
        for token in tokens { token.cancel() }
        let cancellationHook = debugObjectiveMutationCancellationHook
        executionQueue.async {
            do {
                try mutation()
                completion.finish(.success(()))
            } catch {
                completion.finish(.failure(error))
            }
        }
        schedulingLock.unlock()

        cancellationHook?(tokens.count)
        try completion.wait()
    }

    private func unregisterStep(_ identifier: UUID) {
        schedulingLock.lock()
        pendingStepTokens.removeValue(forKey: identifier)
        schedulingLock.unlock()
    }

    private func runInteractiveStep(
        iterations: Int,
        options: TSNEStepOptions,
        cancellation: StepCancellationToken
    ) throws -> TSNESnapshot {
        try ensureUsable()
        let apply = try validatedApplyParameters(iterations: iterations, options: options)
        if cancellation.isCancelled { throw CancellationError() }
        if iterations == 0 {
            let result = try makeSnapshot()
            if cancellation.isCancelled { throw CancellationError() }
            return result
        }

        let clock = ContinuousClock()
        let started = clock.now
        defer {
            let elapsed = started.duration(to: clock.now)
            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) * 1e-18
            statisticsStorage.optimizeSeconds += seconds
            statisticsStorage.totalSeconds = problem.preparationStatistics.totalSeconds
                + statisticsStorage.optimizeSeconds
        }

        var remaining = iterations
        var firstBatch = true
        while remaining > 0 {
            if cancellation.isCancelled { throw CancellationError() }
            let batchCount = min(remaining, options.commandBufferIterations)
            let commandBuffer = try makeCommandBuffer()
            try encodeBatch(
                applyParameters: [SessionApplyParams](repeating: apply, count: batchCount),
                dynamicsPolicy: firstBatch ? options.dynamicsPolicy : .preserve,
                commandBuffer: commandBuffer)
            try commitAndWait(commandBuffer)

            completedIterationsStorage += batchCount
            recordBatchSize(batchCount)
            remaining -= batchCount
            firstBatch = false

            debugBoundaryHook?(completedIterationsStorage)
            if cancellation.isCancelled { throw CancellationError() }
        }

        let result = try makeSnapshot()
        if cancellation.isCancelled { throw CancellationError() }
        return result
    }

    private func validatedApplyParameters(
        iterations: Int,
        options: TSNEStepOptions
    ) throws -> SessionApplyParams {
        guard iterations >= 0 else {
            throw TSNEError.invalidInput("step iterations must be nonnegative")
        }
        guard options.commandBufferIterations > 0 else {
            throw TSNEError.invalidInput("commandBufferIterations must be greater than zero")
        }
        guard options.momentum.isFinite, (0...1).contains(options.momentum) else {
            throw TSNEError.invalidInput("step momentum must be finite and within 0...1")
        }
        guard options.exaggeration.isFinite, options.exaggeration >= 0 else {
            throw TSNEError.invalidInput("step exaggeration must be finite and nonnegative")
        }

        let resolvedLearningRate = options.learningRate
            ?? problem.parameters.resolvedLearningRate(pointCount: pointCount)
        guard resolvedLearningRate.isFinite, resolvedLearningRate > 0,
              Float(resolvedLearningRate).isFinite else {
            throw TSNEError.invalidInput("step learningRate must be finite and greater than zero")
        }

        var maximumStepNorm: Float = 0
        var flags: UInt32 = 0
        if let maximum = options.maximumStepNorm {
            guard maximum.isFinite, maximum >= 0 else {
                throw TSNEError.invalidInput(
                    "maximumStepNorm must be finite and nonnegative when supplied")
            }
            maximumStepNorm = maximum
            flags |= 1
        }

        return SessionApplyParams(
            n: UInt32(pointCount),
            learningRate: Float(resolvedLearningRate),
            momentum: Float(options.momentum),
            exaggeration: Float(options.exaggeration),
            minGain: 0.01,
            priorStrengthOverN: priorStrength / Float(pointCount),
            maximumStepNorm: maximumStepNorm,
            flags: flags)
    }

    private static func validateInitialSchedule(
        _ parameters: TSNEParameters,
        pointCount: Int
    ) throws {
        guard parameters.iterations >= 0 else {
            throw TSNEError.invalidInput("iterations must be nonnegative")
        }
        guard parameters.earlyExaggerationIterations >= 0 else {
            throw TSNEError.invalidInput("earlyExaggerationIterations must be nonnegative")
        }
        guard parameters.earlyExaggeration.isFinite, parameters.earlyExaggeration >= 0,
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

    // MARK: - Command encoding

    private func makeCommandBuffer() throws -> MTLCommandBuffer {
        guard let commandBuffer = context.queue.makeCommandBuffer() else {
            throw TSNEError.bufferAllocationFailed
        }
        return commandBuffer
    }

    private func commitAndWait(_ commandBuffer: MTLCommandBuffer) throws {
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            let detail = commandBuffer.error?.localizedDescription
                ?? "command buffer ended with status \(commandBuffer.status.rawValue)"
            let failure = TSNEError.metalExecutionFailed(detail)
            terminalError = failure
            throw failure
        }
    }

    private func encodeBatch(
        applyParameters: [SessionApplyParams],
        dynamicsPolicy: TSNEDynamicsPolicy,
        commandBuffer: MTLCommandBuffer
    ) throws {
        var measuredParameters = applyParameters
        if !measuredParameters.isEmpty {
            measuredParameters[measuredParameters.count - 1].flags |= 2
        }
        if let fieldResources {
            try encodeFieldBatch(
                applyParameters: measuredParameters,
                dynamicsPolicy: dynamicsPolicy,
                commandBuffer: commandBuffer,
                field: fieldResources)
        } else {
            try encodeExactBatch(
                applyParameters: measuredParameters,
                dynamicsPolicy: dynamicsPolicy,
                commandBuffer: commandBuffer)
        }
    }

    private func encodeExactBatch(
        applyParameters: [SessionApplyParams],
        dynamicsPolicy: TSNEDynamicsPolicy,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard let repulsivePipeline = exactRepulsivePipeline,
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw TSNEError.bufferAllocationFailed
        }

        let threadgroupSize = 256
        let pointGroups = MTLSize(
            width: (pointCount + threadgroupSize - 1) / threadgroupSize,
            height: 1, depth: 1)
        let threads = MTLSize(width: threadgroupSize, height: 1, depth: 1)
        let bodiesPerThread = 4
        let repulsiveThreads = (pointCount + bodiesPerThread - 1) / bodiesPerThread
        let repulsiveGroups = MTLSize(
            width: (repulsiveThreads + threadgroupSize - 1) / threadgroupSize,
            height: 1, depth: 1)
        var n = UInt32(pointCount)

        encodeDynamicsReset(dynamicsPolicy, with: encoder, groups: pointGroups, threads: threads)

        for var apply in applyParameters {
            encoder.setComputePipelineState(clearScalarPipeline)
            encoder.setBuffer(normalizationBuffer, offset: 0, index: 0)
            encoder.dispatchThreadgroups(
                MTLSize(width: 1, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))

            if (apply.flags & 2) != 0 {
                encoder.setComputePipelineState(clearMetricsPipeline)
                encoder.setBuffer(squaredStepSumBuffer, offset: 0, index: 0)
                encoder.setBuffer(maximumStepBitsBuffer, offset: 0, index: 1)
                encoder.dispatchThreadgroups(
                    MTLSize(width: 1, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            }

            encoder.setComputePipelineState(repulsivePipeline)
            encoder.setBuffer(positionBuffer, offset: 0, index: 0)
            encoder.setBuffer(repulsiveForceBuffer, offset: 0, index: 1)
            encoder.setBuffer(normalizationBuffer, offset: 0, index: 2)
            encoder.setBytes(&n, length: MemoryLayout<UInt32>.stride, index: 3)
            encoder.setThreadgroupMemoryLength(
                threadgroupSize * MemoryLayout<SIMD2<Float>>.stride, index: 0)
            encoder.setThreadgroupMemoryLength(
                threadgroupSize * MemoryLayout<Float>.stride, index: 1)
            encoder.dispatchThreadgroups(repulsiveGroups, threadsPerThreadgroup: threads)

            encodeAttraction(with: encoder, groups: pointGroups, threads: threads, n: &n)
            encodeApply(&apply, with: encoder, groups: pointGroups, threads: threads)
        }
        encoder.endEncoding()
    }

    private func encodeFieldBatch(
        applyParameters: [SessionApplyParams],
        dynamicsPolicy: TSNEDynamicsPolicy,
        commandBuffer: MTLCommandBuffer,
        field: SessionFieldResources
    ) throws {
        let threadgroupSize = 256
        let pointGroups = MTLSize(
            width: (pointCount + threadgroupSize - 1) / threadgroupSize,
            height: 1, depth: 1)
        let threads = MTLSize(width: threadgroupSize, height: 1, depth: 1)
        var n = UInt32(pointCount)
        var resolution = UInt32(field.resolution)
        var partialCount = UInt32(field.partialCount)

        if dynamicsPolicy != .preserve {
            guard let resetEncoder = commandBuffer.makeComputeCommandEncoder() else {
                throw TSNEError.bufferAllocationFailed
            }
            encodeDynamicsReset(
                dynamicsPolicy, with: resetEncoder,
                groups: pointGroups, threads: threads)
            resetEncoder.endEncoding()
        }

        for var apply in applyParameters {
            guard let firstCompute = commandBuffer.makeComputeCommandEncoder() else {
                throw TSNEError.bufferAllocationFailed
            }
            firstCompute.setComputePipelineState(field.reduceBoundsStage1)
            firstCompute.setBuffer(positionBuffer, offset: 0, index: 0)
            firstCompute.setBuffer(field.partials, offset: 0, index: 1)
            firstCompute.setBytes(&n, length: MemoryLayout<UInt32>.stride, index: 2)
            firstCompute.setThreadgroupMemoryLength(
                threadgroupSize * MemoryLayout<SIMD2<Float>>.stride, index: 0)
            firstCompute.setThreadgroupMemoryLength(
                threadgroupSize * MemoryLayout<SIMD2<Float>>.stride, index: 1)
            firstCompute.dispatchThreadgroups(
                MTLSize(width: field.partialCount, height: 1, depth: 1),
                threadsPerThreadgroup: threads)

            firstCompute.setComputePipelineState(field.reduceBoundsStage2)
            firstCompute.setBuffer(field.partials, offset: 0, index: 0)
            firstCompute.setBuffer(field.transform, offset: 0, index: 1)
            firstCompute.setBytes(
                &partialCount, length: MemoryLayout<UInt32>.stride, index: 2)
            firstCompute.setBytes(
                &resolution, length: MemoryLayout<UInt32>.stride, index: 3)
            firstCompute.setThreadgroupMemoryLength(
                threadgroupSize * MemoryLayout<SIMD4<Float>>.stride, index: 0)
            firstCompute.dispatchThreadgroups(
                MTLSize(width: 1, height: 1, depth: 1),
                threadsPerThreadgroup: threads)

            firstCompute.setComputePipelineState(clearScalarPipeline)
            firstCompute.setBuffer(normalizationBuffer, offset: 0, index: 0)
            firstCompute.dispatchThreadgroups(
                MTLSize(width: 1, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))

            if (apply.flags & 2) != 0 {
                firstCompute.setComputePipelineState(clearMetricsPipeline)
                firstCompute.setBuffer(squaredStepSumBuffer, offset: 0, index: 0)
                firstCompute.setBuffer(maximumStepBitsBuffer, offset: 0, index: 1)
                firstCompute.dispatchThreadgroups(
                    MTLSize(width: 1, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            }
            firstCompute.endEncoding()

            guard let render = commandBuffer.makeRenderCommandEncoder(
                descriptor: field.renderPass) else {
                throw TSNEError.bufferAllocationFailed
            }
            render.setRenderPipelineState(field.splat)
            render.setVertexBuffer(positionBuffer, offset: 0, index: 0)
            render.setVertexBuffer(field.transform, offset: 0, index: 1)
            render.setVertexBytes(
                &resolution, length: MemoryLayout<UInt32>.stride, index: 2)
            render.setFragmentTexture(field.kernelTexture, index: 0)
            render.drawPrimitives(
                type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                instanceCount: pointCount)
            render.endEncoding()

            guard let secondCompute = commandBuffer.makeComputeCommandEncoder() else {
                throw TSNEError.bufferAllocationFailed
            }
            secondCompute.setComputePipelineState(field.sampleField)
            secondCompute.setBuffer(positionBuffer, offset: 0, index: 0)
            secondCompute.setBuffer(repulsiveForceBuffer, offset: 0, index: 1)
            secondCompute.setBuffer(normalizationBuffer, offset: 0, index: 2)
            secondCompute.setBuffer(field.transform, offset: 0, index: 3)
            secondCompute.setBytes(
                &resolution, length: MemoryLayout<UInt32>.stride, index: 4)
            secondCompute.setBytes(&n, length: MemoryLayout<UInt32>.stride, index: 5)
            secondCompute.setTexture(field.fieldTexture, index: 0)
            secondCompute.setThreadgroupMemoryLength(
                threadgroupSize * MemoryLayout<Float>.stride, index: 0)
            secondCompute.dispatchThreadgroups(pointGroups, threadsPerThreadgroup: threads)

            encodeAttraction(
                with: secondCompute, groups: pointGroups, threads: threads, n: &n)
            encodeApply(
                &apply, with: secondCompute, groups: pointGroups, threads: threads)
            secondCompute.endEncoding()
        }
    }

    private func encodeDynamicsReset(
        _ policy: TSNEDynamicsPolicy,
        with encoder: MTLComputeCommandEncoder,
        groups: MTLSize,
        threads: MTLSize
    ) {
        guard policy != .preserve else { return }
        var reset = SessionResetParams(
            n: UInt32(pointCount),
            resetGains: policy == .resetAll ? 1 : 0)
        encoder.setComputePipelineState(resetPipeline)
        encoder.setBuffer(velocityBuffer, offset: 0, index: 0)
        encoder.setBuffer(gainBuffer, offset: 0, index: 1)
        encoder.setBytes(
            &reset, length: MemoryLayout<SessionResetParams>.stride, index: 2)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
    }

    private func encodeAttraction(
        with encoder: MTLComputeCommandEncoder,
        groups: MTLSize,
        threads: MTLSize,
        n: inout UInt32
    ) {
        encoder.setComputePipelineState(attractivePipeline)
        encoder.setBuffer(positionBuffer, offset: 0, index: 0)
        encoder.setBuffer(affinityResources.edgeValues, offset: 0, index: 1)
        encoder.setBuffer(affinityResources.columnIndices, offset: 0, index: 2)
        encoder.setBuffer(affinityResources.rowOffsets, offset: 0, index: 3)
        encoder.setBuffer(attractiveForceBuffer, offset: 0, index: 4)
        encoder.setBytes(&n, length: MemoryLayout<UInt32>.stride, index: 5)
        encoder.setBuffer(alphaBuffer, offset: 0, index: 6)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
    }

    private func encodeApply(
        _ apply: inout SessionApplyParams,
        with encoder: MTLComputeCommandEncoder,
        groups: MTLSize,
        threads: MTLSize
    ) {
        encoder.setComputePipelineState(applyPipeline)
        encoder.setBuffer(positionBuffer, offset: 0, index: 0)
        encoder.setBuffer(velocityBuffer, offset: 0, index: 1)
        encoder.setBuffer(gainBuffer, offset: 0, index: 2)
        encoder.setBuffer(attractiveForceBuffer, offset: 0, index: 3)
        encoder.setBuffer(repulsiveForceBuffer, offset: 0, index: 4)
        encoder.setBuffer(normalizationBuffer, offset: 0, index: 5)
        encoder.setBuffer(priorTargetBuffer, offset: 0, index: 6)
        encoder.setBuffer(priorWeightBuffer, offset: 0, index: 7)
        encoder.setBytes(
            &apply, length: MemoryLayout<SessionApplyParams>.stride, index: 8)
        encoder.setBuffer(squaredStepSumBuffer, offset: 0, index: 9)
        encoder.setBuffer(maximumStepBitsBuffer, offset: 0, index: 10)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
    }

    // MARK: - Snapshots and state

    private func makeSnapshot() throws -> TSNESnapshot {
        let positions = try readPositions()
        let squaredSum = squaredStepSumBuffer.pointer(Float.self).pointee
        let maximumBits = maximumStepBitsBuffer.pointer(UInt32.self).pointee
        let rms = sqrt(max(0, squaredSum) / Float(pointCount))
        let maximum = Float(bitPattern: maximumBits)
        guard rms.isFinite, maximum.isFinite else {
            let failure = TSNEError.metalExecutionFailed(
                "optimizer step metrics are not finite")
            terminalError = failure
            throw failure
        }
        return TSNESnapshot(
            positions: positions,
            completedIterations: completedIterationsStorage,
            rmsStep: rms,
            maximumStep: maximum)
    }

    private func readPositions() throws -> [SIMD2<Float>] {
        let positions = positionBuffer.array(SIMD2<Float>.self, count: pointCount)
        guard positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            let failure = TSNEError.metalExecutionFailed(
                "embedding positions are not finite")
            terminalError = failure
            throw failure
        }
        positionReadbackCount += 1
        return positions
    }

    private func ensureUsable() throws {
        if let terminalError { throw terminalError }
    }

    private func recordBatchSize(_ size: Int) {
        // A bounded history is sufficient for acceptance diagnostics without
        // giving a long-lived production session test-only memory growth.
        if commandBufferBatchSizes.count < 256 {
            commandBufferBatchSizes.append(size)
        }
    }

    // MARK: - Persistent resource construction

    private static func makeAffinityResources(
        context: MetalContext,
        base: TSNEAffinityGraph,
        guided: TSNEAffinityGraph
    ) throws -> SessionAffinityResources {
        guard base.pointCount == guided.pointCount else {
            throw TSNEError.invalidInput("affinity graphs must have the same point count")
        }

        var rowOffsets: [UInt32] = [0]
        rowOffsets.reserveCapacity(base.pointCount + 1)
        var columns: [UInt32] = []
        var edgeValues: [SIMD2<Float>] = []
        columns.reserveCapacity(base.columnIndices.count + guided.columnIndices.count)
        edgeValues.reserveCapacity(columns.capacity)

        for row in 0..<base.pointCount {
            var baseRow: [UInt32: Double] = [:]
            var guidedRow: [UInt32: Double] = [:]
            for index in Int(base.rowOffsets[row])..<Int(base.rowOffsets[row + 1]) {
                baseRow[base.columnIndices[index], default: 0] += Double(base.values[index])
            }
            for index in Int(guided.rowOffsets[row])..<Int(guided.rowOffsets[row + 1]) {
                guidedRow[guided.columnIndices[index], default: 0] += Double(guided.values[index])
            }
            let unionColumns = Set(baseRow.keys).union(guidedRow.keys).sorted()
            guard columns.count <= Int(UInt32.max) - unionColumns.count else {
                throw TSNEError.invalidInput("affinity union contains too many stored edges")
            }
            for column in unionColumns {
                columns.append(column)
                edgeValues.append(SIMD2(
                    Float(baseRow[column, default: 0]),
                    Float(guidedRow[column, default: 0])))
            }
            rowOffsets.append(UInt32(columns.count))
        }

        return SessionAffinityResources(
            rowOffsets: try context.makeBuffer(
                UInt32.self, count: rowOffsets.count, from: rowOffsets),
            columnIndices: try context.makeBuffer(
                UInt32.self, count: columns.count, from: columns),
            edgeValues: try context.makeBuffer(
                SIMD2<Float>.self, count: edgeValues.count, from: edgeValues),
            edgeCount: columns.count)
    }

    private static func makeFieldResources(
        context: MetalContext,
        pointCount: Int
    ) throws -> SessionFieldResources {
        let reduce1 = try context.pipeline("tsne_reduce_bounds_stage1")
        let reduce2 = try context.pipeline("tsne_reduce_bounds_stage2")
        let sample = try context.pipeline("tsne_field_sample")
        let splat = try context.renderPipeline(
            vertex: "splat_vertex", fragment: "splat_fragment",
            pixelFormat: .rgba16Float)
        let resolution = MetalContext.fieldResolution(count: pointCount)
        let kernelTexture = try context.makeKernelTexture()
        let fieldTexture = try context.makeFieldTexture(resolution: resolution)
        let partialCount = (pointCount + 255) / 256
        let partials = try context.makeBuffer(SIMD4<Float>.self, count: partialCount)
        let transform = try context.makeBuffer(SIMD4<Float>.self, count: 1)

        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = fieldTexture
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        renderPass.colorAttachments[0].storeAction = .store

        return SessionFieldResources(
            reduceBoundsStage1: reduce1,
            reduceBoundsStage2: reduce2,
            sampleField: sample,
            splat: splat,
            kernelTexture: kernelTexture,
            fieldTexture: fieldTexture,
            partials: partials,
            transform: transform,
            renderPass: renderPass,
            resolution: resolution,
            partialCount: partialCount)
    }

    private static func copy<T>(_ values: [T], to buffer: MTLBuffer) {
        guard !values.isEmpty else { return }
        values.withUnsafeBytes { bytes in
            buffer.contents().copyMemory(
                from: bytes.baseAddress!,
                byteCount: values.count * MemoryLayout<T>.stride)
        }
    }

    private static func fillDynamics(
        velocity: MTLBuffer,
        gains: MTLBuffer,
        count: Int,
        resetGains: Bool
    ) {
        let velocityPointer = velocity.contents().bindMemory(
            to: SIMD2<Float>.self, capacity: count)
        let gainPointer = gains.contents().bindMemory(
            to: SIMD2<Float>.self, capacity: count)
        for index in 0..<count {
            velocityPointer[index] = .zero
            if resetGains { gainPointer[index] = SIMD2(1, 1) }
        }
    }
}
