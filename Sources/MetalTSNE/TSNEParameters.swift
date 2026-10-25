import Foundation

/// Which repulsive-force backend the optimizer uses.
public enum TSNEOptimizer: Sendable {
    /// Pick automatically by dataset size: exact below ~10k points, field above.
    case auto
    /// Exact O(N²) N-body gradient. Highest fidelity; best for smaller sets.
    case exact
    /// Linear-time field-splatting approximation. Much faster at large N.
    case field
}

/// Which neighbor-search backend builds the affinity graph.
public enum TSNENeighborSearch: Sendable {
    /// Pick automatically by dataset size: exact below ~10k points, approximate above.
    case auto
    /// Exact brute-force KNN on the GPU.
    case exact
    /// Approximate KNN via GPU NN-Descent: instead of scanning all N candidates
    /// per point, it refines a random graph using neighbor-of-neighbor moves.
    /// Much faster at large N for a small, well-bounded recall loss.
    case approximate
}

/// Initialization strategy for the low-dimensional embedding.
public enum TSNEInitialization: Sendable {
    /// Small Gaussian noise. Fast, but gives less stable global structure.
    case random
    /// Project onto the top principal components of the (optionally PCA-reduced)
    /// input. Produces more reproducible, globally coherent layouts and is the
    /// recommended default.
    case pca
}

/// Tunable parameters for a t-SNE embedding.
///
/// The defaults are chosen to produce aesthetic, well-separated layouts for
/// collections up to ~50k points without manual tuning. The most impactful
/// knobs are ``perplexity`` (local vs. global emphasis) and ``iterations``.
public struct TSNEParameters: Sendable {
    /// Dimensionality of the output embedding. Only 2 is currently supported
    /// (the GPU gradient kernels are specialized for 2-D), which is the common
    /// case for visual exploration.
    public var outputDimensions: Int = 2

    /// Effective number of nearest neighbors each point is attracted to.
    /// Typical range 5–50. Higher values emphasize global structure; lower
    /// values emphasize tight local clusters.
    public var perplexity: Double = 30

    /// Number of nearest neighbors retained when building the affinity matrix.
    /// Should be at least `3 * perplexity`. Larger is more accurate but slower.
    public var neighborCount: Int = 90

    /// Total gradient-descent iterations. With the field optimizer and the
    /// short early-exaggeration phase, ~300 already gives clean, well-spread
    /// layouts; raise it for extra polish on difficult data.
    public var iterations: Int = 300

    /// During the first ``earlyExaggerationIterations`` steps the attractive
    /// forces are multiplied by this factor, which helps clusters form tight,
    /// well-separated blobs before they spread out.
    public var earlyExaggeration: Double = 12

    /// Number of leading iterations that use ``earlyExaggeration``.
    public var earlyExaggerationIterations: Int = 150

    /// Gradient-descent learning rate. When `nil`, an automatic value of
    /// `max(200, N / earlyExaggeration)` is used, following the heuristic from
    /// Belkina et al. (2019) that scales well to large N.
    public var learningRate: Double? = nil

    /// Momentum used during early exaggeration.
    public var initialMomentum: Double = 0.5

    /// Momentum used after early exaggeration ends.
    public var finalMomentum: Double = 0.8

    /// Optionally reduce the input to this many dimensions via PCA before
    /// computing neighbors. Strongly recommended for high-dimensional inputs
    /// (image/audio embeddings): it slashes KNN cost and denoises distances.
    /// `nil` disables PCA. A value of 50 is a common, robust choice.
    public var pcaDimensions: Int? = 50

    /// How the embedding is initialized.
    public var initialization: TSNEInitialization = .pca

    /// Repulsive-force backend. `.auto` uses the exact N-body gradient below
    /// `autoFastThreshold` points and the linear-time field method above it.
    public var optimizer: TSNEOptimizer = .auto

    /// Neighbor-search backend. `.auto` uses brute-force KNN below
    /// `autoFastThreshold` points and approximate NN-Descent above it.
    public var neighborSearch: TSNENeighborSearch = .auto

    /// Point count at/below which `.auto` backends stay exact (where exact is
    /// already fast and most faithful).
    public var autoFastThreshold: Int = 10_000

    /// Seed for all pseudo-random initialization, so runs are reproducible.
    public var seed: UInt64 = 42

    public init() {}

    /// The learning rate actually used for `pointCount` points, resolving the
    /// `nil` "auto" case.
    public func resolvedLearningRate(pointCount: Int) -> Double {
        if let lr = learningRate { return lr }
        return max(200.0, Double(pointCount) / earlyExaggeration)
    }
}
