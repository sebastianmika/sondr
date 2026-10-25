import Foundation
import Testing
import simd
@testable import MetalTSNE

private func fittedSessionFixture(count: Int) -> [[Float]] {
    (0..<count).map { index in
        let value = Float(index)
        return [
            sin(value * 0.31),
            cos(value * 0.19),
            Float((index * 5) % 13) / 13,
            Float((index * 11) % 17) / 17,
        ]
    }
}

private func fittedSessionParameters(iterations: Int = 37) -> TSNEParameters {
    var parameters = TSNEParameters()
    parameters.pcaDimensions = nil
    parameters.perplexity = 5
    parameters.neighborCount = 15
    parameters.iterations = iterations
    parameters.earlyExaggeration = 6
    parameters.earlyExaggerationIterations = 12
    parameters.learningRate = 20
    parameters.initialMomentum = 0.4
    parameters.finalMomentum = 0.7
    parameters.initialization = .random
    parameters.optimizer = .exact
    parameters.neighborSearch = .exact
    parameters.seed = 1_337
    return parameters
}

private func fittedSessionMaximumDistance(
    _ lhs: [SIMD2<Float>],
    _ rhs: [SIMD2<Float>]
) -> Float {
    zip(lhs, rhs).map { simd_distance($0, $1) }.max() ?? 0
}

private final class FittedSessionProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TSNEProgress] = []

    func append(_ progress: TSNEProgress) {
        lock.lock()
        values.append(progress)
        lock.unlock()
    }

    var snapshots: [TSNEProgress] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@Suite(.serialized, .enabled(if: metalIsAvailable, "Requires a Metal GPU"))
struct FittedSessionTests {
    @Test func fittedSessionMatchesLegacyFit() async throws {
        let data = fittedSessionFixture(count: 24)
        let parameters = fittedSessionParameters()

        let legacy = try TSNE(parameters: parameters).fit(data: data)
        let tsne = try TSNE(parameters: parameters)
        let problem = try tsne.prepare(data: data)
        let session = try await problem.makeFittedSession()
        let fitted = try session.makeModel()

        #expect(session.completedIterations == parameters.iterations)
        #expect(fittedSessionMaximumDistance(legacy.embedding, fitted.embedding) < 1e-5)
    }

    @Test func fittedSessionReportsPhaseBoundaryAndCompletion() async throws {
        let data = fittedSessionFixture(count: 24)
        let parameters = fittedSessionParameters()
        let problem = try TSNE(parameters: parameters).prepare(data: data)
        let recorder = FittedSessionProgressRecorder()

        let session = try await problem.makeFittedSession { progress in
            recorder.append(progress)
        }

        let progress = recorder.snapshots
        #expect(progress.map(\.iteration) == [12, 37])
        #expect(progress.allSatisfy { $0.totalIterations == parameters.iterations })
        #expect(progress.allSatisfy { $0.positions.count == data.count })
        #expect(session.completedIterations == parameters.iterations)
        #expect(try session.snapshot().positions == progress.last?.positions)
    }

    @Test func fittedSessionObservesCancellationBetweenBatches() async throws {
        let data = fittedSessionFixture(count: 32)
        var parameters = fittedSessionParameters(iterations: 100)
        parameters.earlyExaggerationIterations = 50
        let problem = try TSNE(parameters: parameters).prepare(data: data)
        let recorder = FittedSessionProgressRecorder()

        let task = Task.detached {
            try await problem.makeFittedSession { progress in
                recorder.append(progress)
                withUnsafeCurrentTask { current in
                    current?.cancel()
                }
            }
        }

        var observedCancellation = false
        do {
            _ = try await task.value
        } catch is CancellationError {
            observedCancellation = true
        } catch {
            Issue.record("unexpected cancellation error: \(error)")
        }

        #expect(observedCancellation)
        #expect(recorder.snapshots.map(\.iteration) == [25])
    }
}
