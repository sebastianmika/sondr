import Foundation
import Testing
import simd
@testable import MetalTSNE

@Test func affinityGraphValidatesCSRAndAcceptsDuplicateEdges() throws {
    let canonical = try TSNEAffinityGraph(
        pointCount: 2,
        rowOffsets: [0, 1, 2],
        columnIndices: [1, 0],
        values: [0.5, 0.5])
    #expect(canonical.pointCount == 2)
    #expect(canonical.values.reduce(0, +) == 1)

    // Duplicate cells are mathematically summed for symmetry validation and
    // canonicalized later when a session compiles its union.
    let duplicates = try TSNEAffinityGraph(
        pointCount: 2,
        rowOffsets: [0, 2, 4],
        columnIndices: [1, 1, 0, 0],
        values: [0.25, 0.25, 0.25, 0.25])
    #expect(duplicates.values.count == 4)
}

@Test func affinityGraphRejectsMalformedInput() {
    #expect(throws: TSNEError.self) {
        try TSNEAffinityGraph(
            pointCount: 2, rowOffsets: [0, 2],
            columnIndices: [1, 0], values: [0.5, 0.5])
    }
    #expect(throws: TSNEError.self) {
        try TSNEAffinityGraph(
            pointCount: 2, rowOffsets: [0, 1, 2],
            columnIndices: [0, 0], values: [0.5, 0.5])
    }
    #expect(throws: TSNEError.self) {
        try TSNEAffinityGraph(
            pointCount: 2, rowOffsets: [0, 1, 2],
            columnIndices: [1, 0], values: [0.75, 0.25])
    }
    #expect(throws: TSNEError.self) {
        try TSNEAffinityGraph(
            pointCount: 2, rowOffsets: [0, 1, 2],
            columnIndices: [1, 0], values: [.nan, 1])
    }
    #expect(throws: TSNEError.self) {
        try TSNEAffinityGraph(
            pointCount: 2, rowOffsets: [0, 1, 2],
            columnIndices: [2, 0], values: [0.5, 0.5])
    }
}

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"))
func makeAffinityGraphProducesNormalizedSymmetricGraph() throws {
    var parameters = TSNEParameters()
    parameters.pcaDimensions = nil
    parameters.neighborSearch = .exact
    let tsne = try TSNE(parameters: parameters)
    let count = 12
    let dimensions = 3
    let data = (0..<count).flatMap { point in
        (0..<dimensions).map { dimension in
            sin(Float((point + 1) * (dimension + 2)))
        }
    }
    let graph = try tsne.makeAffinityGraph(
        flatData: data,
        count: count,
        dimensions: dimensions,
        perplexity: 3,
        neighborCount: 8,
        neighborSearch: .exact)

    #expect(graph.pointCount == count)
    #expect(graph.rowOffsets.count == count + 1)
    #expect(graph.columnIndices.count == graph.values.count)
    #expect(graph.values.allSatisfy { $0.isFinite && $0 >= 0 })
    #expect(abs(Double(graph.values.reduce(0, +)) - 1)
        <= TSNEAffinityGraph.normalizationTolerance)
}

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"))
func sessionRejectsInvalidInitialStateAndGuidance() throws {
    var parameters = TSNEParameters()
    parameters.pcaDimensions = nil
    parameters.perplexity = 2
    parameters.neighborCount = 3
    let problem = try TSNE(parameters: parameters).prepare(data: [
        [0, 0], [1, 0], [0, 1], [1, 1],
    ])

    #expect(throws: TSNEError.self) {
        try problem.makeSession(initialPositions: [.zero])
    }
    #expect(throws: TSNEError.self) {
        try problem.makeSession(initialPositions: [
            .zero, .zero, SIMD2(.nan, 0), .zero,
        ])
    }

    let session = try problem.makeSession()
    #expect(throws: TSNEError.self) { try session.setAffinityMix(-0.1) }
    #expect(throws: TSNEError.self) { try session.setAffinityMix(.nan) }
    #expect(throws: TSNEError.self) { try session.setPositionPriorStrength(-0.1) }
    #expect(throws: TSNEError.self) { try session.setPositionPriorStrength(.nan) }
    #expect(throws: TSNEError.self) {
        try session.setPositionPrior(TSNEPositionPrior(
            targets: [.zero], weights: [1], strength: 1))
    }
    #expect(throws: TSNEError.self) {
        try session.setPositionPrior(TSNEPositionPrior(
            targets: [.zero, .zero, .zero, .zero],
            weights: [1, -1, 1, 1],
            strength: 1))
    }
}

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"))
func singletonFitRetainsLegacyFastPathForIrrelevantParameters() throws {
    var parameters = TSNEParameters()
    parameters.perplexity = -1
    parameters.neighborCount = 0
    parameters.pcaDimensions = 0
    let model = try TSNE(parameters: parameters).fit(data: [[42]])
    #expect(model.embedding == [.zero])
    #expect(model.fitStatistics.optimizeSeconds == 0)
}
