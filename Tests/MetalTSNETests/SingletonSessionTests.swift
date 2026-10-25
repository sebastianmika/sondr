import Testing
@testable import MetalTSNE

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"))
func singletonPreparedSessionSupportsSnapshotsAndBoundedSteps() async throws {
    let problem = try TSNE().prepare(data: [[42, -3]])
    let session = try problem.makeSession()

    let initial = try session.snapshot()
    #expect(initial.positions == [.zero])
    #expect(initial.completedIterations == 0)
    #expect(initial.rmsStep == 0)
    #expect(initial.maximumStep == 0)

    let zeroIteration = try await session.step(iterations: 0)
    #expect(zeroIteration.positions == initial.positions)
    #expect(zeroIteration.completedIterations == 0)

    let maximumStepNorm: Float = 0.01
    let stepped = try await session.step(
        iterations: 2,
        options: TSNEStepOptions(
            learningRate: 1,
            momentum: 0.5,
            exaggeration: 1,
            maximumStepNorm: maximumStepNorm,
            dynamicsPolicy: .preserve,
            commandBufferIterations: 1))

    #expect(stepped.positions.count == 1)
    #expect(stepped.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    #expect(stepped.completedIterations == 2)
    #expect(stepped.rmsStep.isFinite)
    #expect(stepped.maximumStep.isFinite)
    #expect(stepped.maximumStep <= maximumStepNorm)

    let fitted = try await problem.makeFittedSession()
    let fittedSnapshot = try fitted.snapshot()
    #expect(fittedSnapshot.positions == [.zero])
    #expect(fittedSnapshot.completedIterations == 0)
}
