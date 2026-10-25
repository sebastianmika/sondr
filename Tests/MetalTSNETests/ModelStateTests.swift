// Not part of upstream: tests for the state/restore API added in this repository
// (see ThirdParty/MetalTSNE/VENDORED.md).
import Foundation
import Testing
import simd
@testable import MetalTSNE

private func clusteredVectors(clusters: Int, perCluster: Int, dim: Int, seed: UInt64) -> [[Float]] {
    var state = seed | 1
    func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: state >> 11) % 2000 - 1000) / 1000
    }
    let centres = (0..<clusters).map { _ in (0..<dim).map { _ in next() * 5 } }
    return (0..<clusters * perCluster).map { i in centres[i % clusters].map { $0 + next() * 0.4 } }
}

private func fittedModel(pca: Int? = 12) throws -> (TSNEModel, [[Float]], [[Float]]) {
    let data = clusteredVectors(clusters: 4, perCluster: 120, dim: 32, seed: 5)
    let extra = clusteredVectors(clusters: 4, perCluster: 10, dim: 32, seed: 99)
    var parameters = TSNEParameters()
    parameters.iterations = 300
    parameters.pcaDimensions = pca
    return (try TSNE(parameters: parameters).fit(data: data), data, extra)
}

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"), arguments: [12 as Int?, nil])
func restoredModelPlacesNewPointsExactlyLikeTheOriginal(pca: Int?) throws {
    let (model, _, extra) = try fittedModel(pca: pca)
    let restored = try TSNE().restoreModel(model.state)  // a new TSNE: as after a restart
    #expect(restored.embedding == model.embedding)
    #expect(restored.inputDimensions == model.inputDimensions)
    #expect(try restored.project(data: extra) == model.project(data: extra))
    #expect(try restored.transform(data: extra) == model.transform(data: extra))
}

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"))
func stateKeepsEveryNumberNeededToRebuildTheModel() throws {
    let (model, data, _) = try fittedModel()
    let state = model.state
    #expect(state.embedding.count == data.count)
    #expect(state.inputDimensions == 32)
    #expect(state.workDimensions == 12)
    #expect(state.referenceWork.count == data.count * 12)
    let pca = try #require(state.pca)
    #expect(pca.mean.count == 32)
    #expect(pca.components.count == 32 * 12)
}

@Test(.enabled(if: metalIsAvailable, "Requires a Metal GPU"))
func inconsistentStateIsRejected() throws {
    let (model, _, _) = try fittedModel()
    let tsne = try TSNE()

    var shortReferences = model.state
    shortReferences.referenceWork.removeLast()
    #expect(throws: TSNEError.self) { try tsne.restoreModel(shortReferences) }

    var wrongBasis = model.state
    wrongBasis.pca?.components.removeLast()
    #expect(throws: TSNEError.self) { try tsne.restoreModel(wrongBasis) }

    var noPoints = model.state
    noPoints.embedding = []
    noPoints.referenceWork = []
    #expect(throws: TSNEError.self) { try tsne.restoreModel(noPoints) }
}
