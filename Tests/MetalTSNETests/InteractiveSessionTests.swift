import Foundation
import Testing
import simd
@testable import MetalTSNE

private let squarePositions: [SIMD2<Float>] = [
    SIMD2(-1, -1),
    SIMD2(-1, 1),
    SIMD2(1, -1),
    SIMD2(1, 1),
]

private func fixtureData(count: Int) -> [[Float]] {
    (0..<count).map { index in
        let value = Float(index)
        return [
            sin(value * 0.37),
            cos(value * 0.23),
            Float((index * 7) % 17) / 17,
            Float((index * 11) % 19) / 19,
        ]
    }
}

private func fixturePositions(count: Int) -> [SIMD2<Float>] {
    (0..<count).map { index in
        let angle = 2 * Float.pi * Float(index) / Float(count)
        let radius = 0.75 + 0.2 * Float(index % 5) / 4
        return SIMD2(cos(angle) * radius, sin(angle) * radius)
    }
}

private func makeProblem(
    count: Int = 4,
    optimizer: TSNEOptimizer = .exact
) throws -> (tsne: TSNE, problem: TSNEProblem) {
    var parameters = TSNEParameters()
    parameters.pcaDimensions = nil
    parameters.perplexity = count <= 4 ? 2 : 8
    parameters.neighborCount = min(max(1, count - 1), 24)
    parameters.optimizer = optimizer
    parameters.neighborSearch = .exact
    parameters.initialization = .random
    parameters.seed = 991
    let tsne = try TSNE(parameters: parameters)
    return (tsne, try tsne.prepare(data: fixtureData(count: count)))
}

/// Two disjoint normalized graphs over the corners of a square. The base graph
/// connects vertical pairs, while the guided graph connects horizontal pairs.
private func squareAffinityPair() throws -> (base: TSNEAffinityGraph, guided: TSNEAffinityGraph) {
    let base = try TSNEAffinityGraph(
        pointCount: 4,
        rowOffsets: [0, 1, 2, 3, 4],
        columnIndices: [1, 0, 3, 2],
        values: [0.25, 0.25, 0.25, 0.25])
    let guided = try TSNEAffinityGraph(
        pointCount: 4,
        rowOffsets: [0, 1, 2, 3, 4],
        columnIndices: [2, 3, 0, 1],
        values: [0.25, 0.25, 0.25, 0.25])
    return (base, guided)
}

private func maximumDistance(
    _ lhs: [SIMD2<Float>],
    _ rhs: [SIMD2<Float>]
) -> Float {
    zip(lhs, rhs).map { simd_distance($0, $1) }.max() ?? 0
}

private func rmsDistance(
    _ lhs: [SIMD2<Float>],
    _ rhs: [SIMD2<Float>]
) -> Float {
    guard !lhs.isEmpty else { return 0 }
    let meanSquared = zip(lhs, rhs).reduce(Float.zero) {
        $0 + simd_distance_squared($1.0, $1.1)
    } / Float(lhs.count)
    return sqrt(meanSquared)
}

private func oneStepOptions(
    learningRate: Double = 0.1,
    maximumStepNorm: Float? = nil
) -> TSNEStepOptions {
    TSNEStepOptions(
        learningRate: learningRate,
        momentum: 0,
        exaggeration: 1,
        maximumStepNorm: maximumStepNorm,
        dynamicsPolicy: .preserve,
        commandBufferIterations: 1)
}

/// A deterministic test gate: the session's serial execution queue stops after
/// one completed command buffer while the test cancels the real Swift task.
private final class SessionBoundaryGate: @unchecked Sendable {
    let reached = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var hasStopped = false
    private var boundaryStorage: Int?

    var boundary: Int? {
        lock.lock()
        defer { lock.unlock() }
        return boundaryStorage
    }

    func stopAtFirstBoundary(_ completedIterations: Int) {
        lock.lock()
        guard !hasStopped else {
            lock.unlock()
            return
        }
        hasStopped = true
        boundaryStorage = completedIterations
        lock.unlock()

        reached.signal()
        _ = resume.wait(timeout: .now() + 10)
    }

    func release() {
        resume.signal()
    }

    func waitUntilReached() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [reached] in
                continuation.resume(returning: reached.wait(timeout: .now() + 5) == .success)
            }
        }
    }
}

/// Deterministically observes the scheduling events that happen while the
/// serial Metal queue is intentionally stopped at a command-buffer boundary.
private final class SessionSchedulingProbe: @unchecked Sendable {
    private let stepScheduled = DispatchSemaphore(value: 0)
    private let objectiveCancelled = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var cancelledStepCountStorage: Int?

    var cancelledStepCount: Int? {
        lock.lock()
        defer { lock.unlock() }
        return cancelledStepCountStorage
    }

    func didScheduleStep(_: Int) {
        stepScheduled.signal()
    }

    func didCancelSteps(_ count: Int) {
        lock.lock()
        cancelledStepCountStorage = count
        lock.unlock()
        objectiveCancelled.signal()
    }

    func waitForScheduledSteps(_ count: Int) async -> Bool {
        await waitForSignals(stepScheduled, count: count)
    }

    func waitForObjectiveCancellation() async -> Bool {
        await waitForSignals(objectiveCancelled, count: 1)
    }

    private func waitForSignals(
        _ semaphore: DispatchSemaphore,
        count: Int
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                for _ in 0..<count {
                    guard semaphore.wait(timeout: .now() + 5) == .success else {
                        continuation.resume(returning: false)
                        return
                    }
                }
                continuation.resume(returning: true)
            }
        }
    }
}

@Suite(.serialized, .enabled(if: metalIsAvailable, "Requires a Metal GPU"))
struct InteractiveSessionTests {
    @Test func testSplitOptimizationMatchesContinuousOptimization() async throws {
        let (_, problem) = try makeProblem(count: 16)
        let initial = fixturePositions(count: problem.pointCount)
        let split = try problem.makeSession(initialPositions: initial)
        let continuous = try problem.makeSession(initialPositions: initial)
        let options = TSNEStepOptions(
            learningRate: 0.2,
            momentum: 0.5,
            exaggeration: 1,
            maximumStepNorm: 0.05,
            dynamicsPolicy: .preserve,
            commandBufferIterations: 4)

        _ = try await split.step(iterations: 20, options: options)
        let splitResult = try await split.step(iterations: 20, options: options)
        let continuousResult = try await continuous.step(iterations: 40, options: options)

        #expect(splitResult.completedIterations == 40)
        #expect(continuousResult.completedIterations == 40)
        #expect(maximumDistance(splitResult.positions, continuousResult.positions) < 1e-5)
        #expect(abs(splitResult.rmsStep - continuousResult.rmsStep) < 1e-5)
        #expect(abs(splitResult.maximumStep - continuousResult.maximumStep) < 1e-5)
    }

    @Test func testSuppliedInitialPositionsAreUsed() throws {
        let (_, problem) = try makeProblem()
        let session = try problem.makeSession(initialPositions: squarePositions)
        let snapshot = try session.snapshot()

        #expect(snapshot.positions == squarePositions)
        #expect(snapshot.completedIterations == 0)
        #expect(snapshot.rmsStep == 0)
        #expect(snapshot.maximumStep == 0)
    }

    @Test func testAffinityMixEndpoints() async throws {
        let (_, problem) = try makeProblem()
        let graphs = try squareAffinityPair()
        let options = oneStepOptions(learningRate: 0.2)

        let alphaZero = try problem.makeSession(initialPositions: squarePositions)
        try alphaZero.setAffinityPair(base: graphs.base, guided: graphs.guided)
        try alphaZero.setAffinityMix(0)

        let baseOnly = try problem.makeSession(initialPositions: squarePositions)
        try baseOnly.setAffinityPair(base: graphs.base, guided: graphs.base)
        try baseOnly.setAffinityMix(0.5)

        let alphaOne = try problem.makeSession(initialPositions: squarePositions)
        try alphaOne.setAffinityPair(base: graphs.base, guided: graphs.guided)
        try alphaOne.setAffinityMix(1)

        let guidedOnly = try problem.makeSession(initialPositions: squarePositions)
        try guidedOnly.setAffinityPair(base: graphs.guided, guided: graphs.guided)
        try guidedOnly.setAffinityMix(0.5)

        let zeroResult = try await alphaZero.step(iterations: 1, options: options)
        let baseResult = try await baseOnly.step(iterations: 1, options: options)
        let oneResult = try await alphaOne.step(iterations: 1, options: options)
        let guidedResult = try await guidedOnly.step(iterations: 1, options: options)

        #expect(maximumDistance(zeroResult.positions, baseResult.positions) < 1e-6)
        #expect(maximumDistance(oneResult.positions, guidedResult.positions) < 1e-6)
    }

    @Test func testChangingMixDoesNotMovePositions() throws {
        let (_, problem) = try makeProblem()
        let graphs = try squareAffinityPair()
        let session = try problem.makeSession(initialPositions: squarePositions)
        try session.setAffinityPair(base: graphs.base, guided: graphs.guided)
        let before = try session.snapshot()
        let diagnosticsBefore = session._debugDiagnostics

        try session.setAffinityMix(0.73)

        let after = try session.snapshot()
        let diagnosticsAfter = session._debugDiagnostics
        #expect(after.positions == before.positions)
        #expect(after.completedIterations == before.completedIterations)
        #expect(diagnosticsAfter.largeResourceGeneration == diagnosticsBefore.largeResourceGeneration)
        #expect(diagnosticsAfter.affinityUnionBuildCount == diagnosticsBefore.affinityUnionBuildCount)
        #expect(diagnosticsAfter.mixUpdateCount == diagnosticsBefore.mixUpdateCount + 1)
    }

    @Test func testAffinityUnionIncludesEdgesFromBothGraphs() async throws {
        let (_, problem) = try makeProblem()
        let graphs = try squareAffinityPair()
        let options = oneStepOptions(learningRate: 0.2)

        func session(alpha: Float) throws -> TSNEEmbeddingSession {
            let result = try problem.makeSession(initialPositions: squarePositions)
            try result.setAffinityPair(base: graphs.base, guided: graphs.guided)
            try result.setAffinityMix(alpha)
            return result
        }

        let base = try session(alpha: 0)
        let mixed = try session(alpha: 0.5)
        let guided = try session(alpha: 1)
        #expect(mixed._debugDiagnostics.affinityEdgeCount == 8)

        let baseResult = try await base.step(iterations: 1, options: options)
        let mixedResult = try await mixed.step(iterations: 1, options: options)
        let guidedResult = try await guided.step(iterations: 1, options: options)

        #expect(maximumDistance(mixedResult.positions, baseResult.positions) > 1e-5)
        #expect(maximumDistance(mixedResult.positions, guidedResult.positions) > 1e-5)
    }

    @Test func testPositionPriorReducesDisplacement() async throws {
        let (_, problem) = try makeProblem()
        let graphs = try squareAffinityPair()
        let unconstrained = try problem.makeSession(initialPositions: squarePositions)
        let stabilized = try problem.makeSession(initialPositions: squarePositions)
        try unconstrained.setAffinityPair(base: graphs.base, guided: graphs.guided)
        try stabilized.setAffinityPair(base: graphs.base, guided: graphs.guided)
        try stabilized.setPositionPrior(TSNEPositionPrior(
            targets: squarePositions,
            weights: [Float](repeating: 1, count: 4),
            strength: 20))
        let options = TSNEStepOptions(
            learningRate: 0.05,
            momentum: 0,
            exaggeration: 1,
            maximumStepNorm: 0.05,
            dynamicsPolicy: .preserve,
            commandBufferIterations: 4)

        let freeResult = try await unconstrained.step(iterations: 16, options: options)
        let stableResult = try await stabilized.step(iterations: 16, options: options)

        #expect(rmsDistance(stableResult.positions, squarePositions)
            < rmsDistance(freeResult.positions, squarePositions))
    }

    @Test func testPositionPriorStrengthCanFadeResidentTargets() async throws {
        let (_, problem) = try makeProblem()
        let graphs = try squareAffinityPair()
        let control = try problem.makeSession(initialPositions: squarePositions)
        let faded = try problem.makeSession(initialPositions: squarePositions)
        let guided = try problem.makeSession(initialPositions: squarePositions)
        for session in [control, faded, guided] {
            try session.setAffinityPair(base: graphs.base, guided: graphs.guided)
        }

        var targets = squarePositions
        targets[0] += SIMD2<Float>(1, 0)
        let prior = TSNEPositionPrior(
            targets: targets,
            weights: [10, 0, 0, 0],
            strength: 100)
        try faded.setPositionPrior(prior)
        try faded.setPositionPriorStrength(0)
        try guided.setPositionPrior(prior)
        let options = oneStepOptions(learningRate: 0.01, maximumStepNorm: 0.2)

        let controlResult = try await control.step(iterations: 1, options: options)
        let fadedResult = try await faded.step(iterations: 1, options: options)
        let guidedResult = try await guided.step(iterations: 1, options: options)

        #expect(maximumDistance(controlResult.positions, fadedResult.positions) < 1e-6)
        #expect(simd_distance(guidedResult.positions[0], targets[0])
            < simd_distance(controlResult.positions[0], targets[0]))
    }

    @Test func testZeroWeightPointsAreUnconstrained() async throws {
        let (_, problem) = try makeProblem()
        let graphs = try squareAffinityPair()
        let control = try problem.makeSession(initialPositions: squarePositions)
        let priorSession = try problem.makeSession(initialPositions: squarePositions)
        try control.setAffinityPair(base: graphs.base, guided: graphs.guided)
        try priorSession.setAffinityPair(base: graphs.base, guided: graphs.guided)

        var targets = squarePositions
        targets[0] += SIMD2(100, 100) // Must have no direct effect because weight is zero.
        targets[1] += SIMD2(1, 0)
        try priorSession.setPositionPrior(TSNEPositionPrior(
            targets: targets,
            weights: [0, 10, 0, 0],
            strength: 100))
        let options = oneStepOptions(learningRate: 0.01, maximumStepNorm: 0.2)

        let controlResult = try await control.step(iterations: 1, options: options)
        let priorResult = try await priorSession.step(iterations: 1, options: options)

        #expect(simd_distance(controlResult.positions[0], priorResult.positions[0]) < 1e-6)
        #expect(simd_distance(controlResult.positions[1], priorResult.positions[1]) > 1e-3)
    }

    @Test func testAnchoredPointApproachesTarget() async throws {
        let (_, problem) = try makeProblem()
        let graphs = try squareAffinityPair()
        let session = try problem.makeSession(initialPositions: squarePositions)
        try session.setAffinityPair(base: graphs.base, guided: graphs.guided)
        var targets = squarePositions
        targets[0] += SIMD2(1, 0)
        try session.setPositionPrior(TSNEPositionPrior(
            targets: targets,
            weights: [10, 0, 0, 0],
            strength: 100))

        let before = simd_distance(squarePositions[0], targets[0])
        let result = try await session.step(
            iterations: 1,
            options: oneStepOptions(learningRate: 0.01, maximumStepNorm: 0.2))

        #expect(simd_distance(result.positions[0], targets[0]) < before)
    }

    @Test func testMaximumStepNormIsRespected() async throws {
        let (_, problem) = try makeProblem()
        let graphs = try squareAffinityPair()
        let session = try problem.makeSession(initialPositions: squarePositions)
        try session.setAffinityPair(base: graphs.base, guided: graphs.guided)
        let cap: Float = 0.03

        let result = try await session.step(
            iterations: 1,
            options: oneStepOptions(learningRate: 1_000, maximumStepNorm: cap))
        let movements = zip(result.positions, squarePositions).map { simd_distance($0, $1) }
        let measuredMaximum = movements.max() ?? 0
        let measuredRMS = sqrt(
            movements.reduce(Float.zero) { $0 + $1 * $1 } / Float(movements.count))

        #expect(measuredMaximum <= cap + 1e-5)
        #expect(measuredMaximum > cap * 0.95)
        #expect(result.maximumStep <= cap + 1e-5)
        #expect(abs(result.maximumStep - measuredMaximum) < 1e-5)
        #expect(abs(result.rmsStep - measuredRMS) < 1e-5)
    }

    @Test func testCancellationLeavesValidSnapshot() async throws {
        let (_, problem) = try makeProblem(count: 64)
        let initial = fixturePositions(count: problem.pointCount)
        let session = try problem.makeSession(initialPositions: initial)
        let gate = SessionBoundaryGate()
        session._debugAfterCommandBufferBoundary = { gate.stopAtFirstBoundary($0) }
        let options = TSNEStepOptions(
            learningRate: 0.1,
            momentum: 0.5,
            exaggeration: 1,
            maximumStepNorm: 0.05,
            dynamicsPolicy: .preserve,
            commandBufferIterations: 3)

        let task = Task.detached {
            try await session.step(iterations: 30, options: options)
        }
        guard await gate.waitUntilReached() else {
            task.cancel()
            gate.release()
            _ = try? await task.value
            Issue.record("session did not report a command-buffer boundary")
            return
        }

        #expect(gate.boundary == 3)
        task.cancel()
        gate.release()

        var observedCancellation = false
        do {
            _ = try await task.value
        } catch is CancellationError {
            observedCancellation = true
        } catch {
            Issue.record("unexpected cancellation error: \(error)")
        }
        session._debugAfterCommandBufferBoundary = nil

        #expect(observedCancellation)
        let partial = try session.snapshot()
        #expect(partial.completedIterations == 3)
        #expect(partial.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        #expect(session._debugDiagnostics.commandBufferBatchSizes == [3])

        let resumed = try await session.step(iterations: 2, options: options)
        #expect(resumed.completedIterations == 5)
        #expect(resumed.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    @Test func testObjectiveMutationCancelsActiveAndAllQueuedSteps() async throws {
        let (_, problem) = try makeProblem(count: 64)
        let initial = fixturePositions(count: problem.pointCount)
        let session = try problem.makeSession(initialPositions: initial)
        let boundary = SessionBoundaryGate()
        let scheduling = SessionSchedulingProbe()
        session._debugAfterCommandBufferBoundary = { boundary.stopAtFirstBoundary($0) }
        session._debugAfterStepScheduled = { scheduling.didScheduleStep($0) }
        session._debugAfterObjectiveMutationCancellation = {
            scheduling.didCancelSteps($0)
        }
        let options = TSNEStepOptions(
            learningRate: 0.1,
            momentum: 0.5,
            exaggeration: 1,
            maximumStepNorm: 0.05,
            dynamicsPolicy: .preserve,
            commandBufferIterations: 3)

        let active = Task.detached {
            try await session.step(iterations: 30, options: options)
        }
        guard await boundary.waitUntilReached() else {
            active.cancel()
            boundary.release()
            _ = try? await active.value
            Issue.record("active step did not report a command-buffer boundary")
            return
        }

        let queuedOne = Task.detached {
            try await session.step(iterations: 30, options: options)
        }
        let queuedTwo = Task.detached {
            try await session.step(iterations: 30, options: options)
        }
        guard await scheduling.waitForScheduledSteps(3) else {
            active.cancel()
            queuedOne.cancel()
            queuedTwo.cancel()
            boundary.release()
            _ = try? await active.value
            _ = try? await queuedOne.value
            _ = try? await queuedTwo.value
            Issue.record("all three steps were not registered before the mutation")
            return
        }

        let setter = Task.detached {
            try session.setAffinityMix(1)
        }
        guard await scheduling.waitForObjectiveCancellation() else {
            active.cancel()
            queuedOne.cancel()
            queuedTwo.cancel()
            boundary.release()
            _ = try? await setter.value
            _ = try? await active.value
            _ = try? await queuedOne.value
            _ = try? await queuedTwo.value
            Issue.record("objective mutation did not request step cancellation")
            return
        }

        #expect(scheduling.cancelledStepCount == 3)
        boundary.release()
        try await setter.value

        var cancellationCount = 0
        for task in [active, queuedOne, queuedTwo] {
            do {
                _ = try await task.value
            } catch is CancellationError {
                cancellationCount += 1
            } catch {
                Issue.record("unexpected objective-mutation cancellation error: \(error)")
            }
        }
        session._debugAfterCommandBufferBoundary = nil
        session._debugAfterStepScheduled = nil
        session._debugAfterObjectiveMutationCancellation = nil

        #expect(cancellationCount == 3)
        let stopped = try session.snapshot()
        #expect(stopped.completedIterations == 3)
        #expect(session._debugDiagnostics.commandBufferBatchSizes == [3])
        #expect(session._debugDiagnostics.mixUpdateCount == 1)

        // The setter returns only after all earlier queued work has exited, so a
        // fresh one-iteration step must be the sole subsequent movement.
        let resumed = try await session.step(iterations: 1, options: options)
        #expect(resumed.completedIterations == 4)
        #expect(session._debugDiagnostics.commandBufferBatchSizes == [3, 1])
    }

    @Test func testEveryObjectiveSetterCancelsAtCurrentBoundary() async throws {
        enum Mutation: CaseIterable {
            case affinityPair
            case affinityMix
            case positionPrior
            case positionPriorStrength
        }

        for mutation in Mutation.allCases {
            let (_, problem) = try makeProblem(count: 32)
            let initial = fixturePositions(count: problem.pointCount)
            let session = try problem.makeSession(initialPositions: initial)
            let boundary = SessionBoundaryGate()
            let scheduling = SessionSchedulingProbe()
            session._debugAfterCommandBufferBoundary = { boundary.stopAtFirstBoundary($0) }
            session._debugAfterObjectiveMutationCancellation = {
                scheduling.didCancelSteps($0)
            }
            let options = TSNEStepOptions(
                learningRate: 0.1,
                momentum: 0.5,
                exaggeration: 1,
                maximumStepNorm: 0.05,
                dynamicsPolicy: .preserve,
                commandBufferIterations: 2)
            let step = Task.detached {
                try await session.step(iterations: 20, options: options)
            }
            guard await boundary.waitUntilReached() else {
                step.cancel()
                boundary.release()
                _ = try? await step.value
                Issue.record("\(mutation) did not reach the first boundary")
                return
            }

            let setter = Task.detached {
                switch mutation {
                case .affinityPair:
                    try session.setAffinityPair(
                        base: problem.affinities, guided: problem.affinities)
                case .affinityMix:
                    try session.setAffinityMix(0.75)
                case .positionPrior:
                    try session.setPositionPrior(TSNEPositionPrior(
                        targets: initial,
                        weights: [Float](repeating: 1, count: problem.pointCount),
                        strength: 2))
                case .positionPriorStrength:
                    try session.setPositionPriorStrength(0.5)
                }
            }
            guard await scheduling.waitForObjectiveCancellation() else {
                step.cancel()
                boundary.release()
                _ = try? await setter.value
                _ = try? await step.value
                Issue.record("\(mutation) did not request cancellation")
                return
            }

            #expect(scheduling.cancelledStepCount == 1)
            boundary.release()
            try await setter.value
            do {
                _ = try await step.value
                Issue.record("\(mutation) allowed stale optimization to continue")
            } catch is CancellationError {
                // Expected: objective mutation invalidates the active step.
            } catch {
                Issue.record("\(mutation) produced unexpected error: \(error)")
            }

            session._debugAfterCommandBufferBoundary = nil
            session._debugAfterObjectiveMutationCancellation = nil
            #expect(session.completedIterations == 2)
            #expect(session._debugDiagnostics.commandBufferBatchSizes == [2])
        }
    }

    @Test func testRepeatedStepsReuseResources() async throws {
        let (_, problem) = try makeProblem(count: 16)
        let session = try problem.makeSession(
            initialPositions: fixturePositions(count: problem.pointCount))
        try session.setAffinityPair(base: problem.affinities, guided: problem.affinities)
        let before = session._debugDiagnostics
        let options = TSNEStepOptions(
            learningRate: 0.1,
            momentum: 0.5,
            exaggeration: 1,
            maximumStepNorm: 0.05,
            dynamicsPolicy: .preserve,
            commandBufferIterations: 2)

        for alpha: Float in [0, 0.25, 0.75, 1] {
            try session.setAffinityMix(alpha)
            _ = try await session.step(iterations: 2, options: options)
        }

        let after = session._debugDiagnostics
        #expect(after.largeResourceGeneration == before.largeResourceGeneration)
        #expect(after.affinityUnionBuildCount == before.affinityUnionBuildCount)
        #expect(after.affinityEdgeCount == before.affinityEdgeCount)
        #expect(after.mixUpdateCount == before.mixUpdateCount + 4)
        #expect(after.positionReadbackCount == before.positionReadbackCount + 4)
    }

    @Test func testExactAndFieldSessionsRemainFinite() async throws {
        for (optimizer, expectsField) in [
            (TSNEOptimizer.exact, false),
            (TSNEOptimizer.field, true),
        ] {
            let (tsne, problem) = try makeProblem(count: 96, optimizer: optimizer)
            let initial = fixturePositions(count: problem.pointCount)
            let guidedData = (0..<problem.pointCount).flatMap { index -> [Float] in
                let value = Float((index * 37) % problem.pointCount)
                return [sin(value * 0.17), cos(value * 0.31)]
            }
            let guided = try tsne.makeAffinityGraph(
                flatData: guidedData,
                count: problem.pointCount,
                dimensions: 2,
                perplexity: 8,
                neighborCount: 24,
                neighborSearch: .exact)
            let session = try problem.makeSession(initialPositions: initial)
            try session.setAffinityPair(base: problem.affinities, guided: guided)
            try session.setAffinityMix(0.4)
            try session.setPositionPrior(TSNEPositionPrior(
                targets: initial,
                weights: [Float](repeating: 1, count: problem.pointCount),
                strength: 2))

            let result = try await session.step(
                iterations: 4,
                options: TSNEStepOptions(
                    learningRate: 0.1,
                    momentum: 0.5,
                    exaggeration: 1,
                    maximumStepNorm: 0.05,
                    dynamicsPolicy: .preserve,
                    commandBufferIterations: 2))

            #expect(session._debugDiagnostics.usesFieldOptimizer == expectsField)
            #expect(result.completedIterations == 4)
            #expect(result.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite })
            #expect(result.rmsStep.isFinite)
            #expect(result.maximumStep.isFinite)
        }
    }
}
