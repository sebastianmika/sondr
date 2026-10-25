// Not part of upstream: lets an application store a fitted model and rebuild it later
// (see ThirdParty/MetalTSNE/VENDORED.md).
import Foundation
import simd

/// The PCA projection a model applies to new points before searching for neighbours.
public struct TSNEPCAState: Sendable, Equatable {
    /// Column means of the training data, `dim` entries.
    public var mean: [Float]
    /// Principal directions, row-major `dim` × `componentCount`.
    public var components: [Float]
    public var dim: Int
    public var componentCount: Int

    public init(mean: [Float], components: [Float], dim: Int, componentCount: Int) {
        self.mean = mean
        self.components = components
        self.dim = dim
        self.componentCount = componentCount
    }
}

/// Everything a ``TSNEModel`` needs to place new points, as plain arrays that can be stored.
public struct TSNEModelState: Sendable, Equatable {
    /// One 2-D point per reference point.
    public var embedding: [SIMD2<Float>]
    /// Reference points in working space (after PCA), row-major `embedding.count` × `workDimensions`.
    public var referenceWork: [Float]
    public var workDimensions: Int
    /// Length of the vectors the model expects as input.
    public var inputDimensions: Int
    /// Nil if the model was fitted without PCA.
    public var pca: TSNEPCAState?

    public init(
        embedding: [SIMD2<Float>], referenceWork: [Float], workDimensions: Int, inputDimensions: Int,
        pca: TSNEPCAState?
    ) {
        self.embedding = embedding
        self.referenceWork = referenceWork
        self.workDimensions = workDimensions
        self.inputDimensions = inputDimensions
        self.pca = pca
    }
}

extension TSNEModel {
    /// The data to store so that ``TSNE/restoreModel(_:parameters:)`` can rebuild this model.
    public var state: TSNEModelState {
        TSNEModelState(
            embedding: embedding, referenceWork: referenceWork, workDimensions: workDimensions,
            inputDimensions: inputDimensions,
            pca: pcaBasis.map {
                TSNEPCAState(mean: $0.mean, components: $0.components, dim: $0.dim, componentCount: $0.componentCount)
            })
    }
}

extension TSNE {
    /// Rebuilds a model from stored state, for example after the app was restarted.
    ///
    /// The result places new points (`project`, `transform`) exactly like the model the state came from.
    ///
    /// - Parameter parameters: Fit parameters to record on the model; default: this object's.
    /// - Throws: ``TSNEError/invalidInput(_:)`` if the arrays do not fit together.
    public func restoreModel(_ state: TSNEModelState, parameters: TSNEParameters? = nil) throws -> TSNEModel {
        let count = state.embedding.count
        guard count > 0 else { throw TSNEError.invalidInput("a model needs at least one reference point") }
        guard state.workDimensions > 0, state.inputDimensions > 0 else {
            throw TSNEError.invalidInput("dimensions must be positive")
        }
        guard state.referenceWork.count == count * state.workDimensions else {
            throw TSNEError.invalidInput(
                "\(state.referenceWork.count) reference values for \(count) points of \(state.workDimensions) dimensions")
        }
        var basis: PCABasis?
        if let pca = state.pca {
            guard pca.dim == state.inputDimensions, pca.componentCount == state.workDimensions,
                pca.mean.count == pca.dim, pca.components.count == pca.dim * pca.componentCount
            else { throw TSNEError.invalidInput("the PCA basis does not match the model dimensions") }
            basis = PCABasis(mean: pca.mean, components: pca.components, dim: pca.dim, componentCount: pca.componentCount)
        } else if state.workDimensions != state.inputDimensions {
            throw TSNEError.invalidInput("without PCA the working and input dimensions must be equal")
        }
        var statistics = TSNEStatistics()
        statistics.pointCount = count
        statistics.inputDimensions = state.inputDimensions
        statistics.workingDimensions = state.workDimensions
        return TSNEModel(
            context: context, parameters: parameters ?? self.parameters, embedding: state.embedding,
            referenceWork: state.referenceWork, workDimensions: state.workDimensions,
            inputDimensions: state.inputDimensions, pcaBasis: basis, fitStatistics: statistics)
    }
}
