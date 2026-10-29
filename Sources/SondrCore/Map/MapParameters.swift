import Foundation
import MetalTSNE

/// Which hardware-friendly approximations the fit may use.
public enum MapBackend: String, Codable, Sendable, CaseIterable {
    /// Exact for small samples, fast approximations above 10,000 points.
    case auto
    /// Always exact. Slower above about 10,000 points.
    case exact
    /// Always the approximate neighbour search and the field optimiser.
    case fast
}

public enum MapInitialization: String, Codable, Sendable, CaseIterable {
    /// Start from the top two principal components. Gives steadier layouts.
    case pca
    /// Start from small random noise.
    case random
}

/// Everything the user can change about how the 2D map is computed. Stored as JSON with each map
/// so that the settings a map was built with are known, and missing fields fall back to the defaults.
public struct MapParameters: Codable, Sendable, Equatable {
    /// What a fit accepts. A settings slider can offer a narrower range.
    public static let sampleSizeRange = 50...50_000
    public static let perplexityRange = 5.0...100.0
    public static let earlyExaggerationRange = 4.0...30.0
    public static let iterationsRange = 100...1_000
    public static let pcaRange = 10...100
    /// Fewer indexed samples than this: no map.
    public static let minimumSamples = 50

    /// How many randomly chosen samples the layout is computed from. The others are placed onto it.
    public var sampleSize = 30_000
    /// Roughly how many neighbours each point is attracted to. Low: many small tight groups. High: broader groups.
    public var perplexity = 30.0
    /// How strongly groups are pulled together during the first steps.
    public var earlyExaggeration = 12.0
    /// Gradient-descent steps in total.
    public var iterations = 300
    /// Reduce the vectors to this many dimensions first; nil to skip.
    public var pcaDimensions: Int? = 50
    /// Lay out each multisample group as one point (the mean of its members) and put every member at that
    /// point, so a group of 60 notes does not smear into a strand across the map.
    public var collapseMultisamples = false

    // Advanced
    /// Neighbours kept per point; nil means three times the perplexity.
    public var neighborCount: Int?
    /// How many of the first steps use `earlyExaggeration`.
    public var earlyExaggerationIterations = 150
    /// nil: chosen from the sample size.
    public var learningRate: Double?
    public var initialMomentum = 0.5
    public var finalMomentum = 0.8
    public var initialization = MapInitialization.pca
    public var backend = MapBackend.auto
    /// Seeds both the choice of samples and the layout.
    public var seed: UInt64 = 42

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case sampleSize, perplexity, earlyExaggeration, iterations, pcaDimensions, collapseMultisamples, neighborCount
        case earlyExaggerationIterations, learningRate, initialMomentum, finalMomentum
        case initialization, backend, seed
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sampleSize = try c.decodeIfPresent(Int.self, forKey: .sampleSize) ?? sampleSize
        perplexity = try c.decodeIfPresent(Double.self, forKey: .perplexity) ?? perplexity
        earlyExaggeration = try c.decodeIfPresent(Double.self, forKey: .earlyExaggeration) ?? earlyExaggeration
        iterations = try c.decodeIfPresent(Int.self, forKey: .iterations) ?? iterations
        // An explicit null means "off", a missing key means "default".
        if c.contains(.pcaDimensions) { pcaDimensions = try c.decodeIfPresent(Int.self, forKey: .pcaDimensions) }
        collapseMultisamples = try c.decodeIfPresent(Bool.self, forKey: .collapseMultisamples) ?? collapseMultisamples
        neighborCount = try c.decodeIfPresent(Int.self, forKey: .neighborCount)
        earlyExaggerationIterations =
            try c.decodeIfPresent(Int.self, forKey: .earlyExaggerationIterations) ?? earlyExaggerationIterations
        learningRate = try c.decodeIfPresent(Double.self, forKey: .learningRate)
        initialMomentum = try c.decodeIfPresent(Double.self, forKey: .initialMomentum) ?? initialMomentum
        finalMomentum = try c.decodeIfPresent(Double.self, forKey: .finalMomentum) ?? finalMomentum
        initialization = try c.decodeIfPresent(MapInitialization.self, forKey: .initialization) ?? initialization
        backend = try c.decodeIfPresent(MapBackend.self, forKey: .backend) ?? backend
        seed = try c.decodeIfPresent(UInt64.self, forKey: .seed) ?? seed
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sampleSize, forKey: .sampleSize)
        try c.encode(perplexity, forKey: .perplexity)
        try c.encode(earlyExaggeration, forKey: .earlyExaggeration)
        try c.encode(iterations, forKey: .iterations)
        if let pcaDimensions { try c.encode(pcaDimensions, forKey: .pcaDimensions) } else { try c.encodeNil(forKey: .pcaDimensions) }
        try c.encode(collapseMultisamples, forKey: .collapseMultisamples)
        try c.encodeIfPresent(neighborCount, forKey: .neighborCount)
        try c.encode(earlyExaggerationIterations, forKey: .earlyExaggerationIterations)
        try c.encodeIfPresent(learningRate, forKey: .learningRate)
        try c.encode(initialMomentum, forKey: .initialMomentum)
        try c.encode(finalMomentum, forKey: .finalMomentum)
        try c.encode(initialization, forKey: .initialization)
        try c.encode(backend, forKey: .backend)
        try c.encode(seed, forKey: .seed)
    }

    /// The same settings with every value moved into its documented range.
    public func clamped() -> MapParameters {
        var p = self
        p.sampleSize = min(max(sampleSize, Self.sampleSizeRange.lowerBound), Self.sampleSizeRange.upperBound)
        p.perplexity = min(max(perplexity, Self.perplexityRange.lowerBound), Self.perplexityRange.upperBound)
        p.earlyExaggeration = min(max(earlyExaggeration, Self.earlyExaggerationRange.lowerBound), Self.earlyExaggerationRange.upperBound)
        p.iterations = min(max(iterations, Self.iterationsRange.lowerBound), Self.iterationsRange.upperBound)
        p.pcaDimensions = pcaDimensions.map { min(max($0, Self.pcaRange.lowerBound), Self.pcaRange.upperBound) }
        p.earlyExaggerationIterations = min(max(earlyExaggerationIterations, 0), p.iterations)
        p.initialMomentum = min(max(initialMomentum, 0), 0.99)
        p.finalMomentum = min(max(finalMomentum, 0), 0.99)
        return p
    }

    /// Settings for the fitting library, adapted to the actual sample: the perplexity must stay below
    /// a third of the points, the neighbour count below the number of points, and PCA cannot keep more
    /// dimensions than the vectors have.
    public func tsne(pointCount: Int, inputDimensions: Int) -> TSNEParameters {
        let p = clamped()
        var t = TSNEParameters()
        t.perplexity = min(p.perplexity, Double(max((pointCount - 1) / 3, 2)))
        t.neighborCount = min(p.neighborCount ?? Int(3 * t.perplexity), max(pointCount - 1, 1))
        t.iterations = p.iterations
        t.earlyExaggeration = p.earlyExaggeration
        t.earlyExaggerationIterations = p.earlyExaggerationIterations
        t.learningRate = p.learningRate
        t.initialMomentum = p.initialMomentum
        t.finalMomentum = p.finalMomentum
        t.pcaDimensions = p.pcaDimensions.map { min($0, inputDimensions) }
        t.initialization = p.initialization == .pca ? .pca : .random
        switch p.backend {
        case .auto: (t.optimizer, t.neighborSearch) = (.auto, .auto)
        case .exact: (t.optimizer, t.neighborSearch) = (.exact, .exact)
        case .fast: (t.optimizer, t.neighborSearch) = (.field, .approximate)
        }
        t.seed = p.seed
        return t
    }
}
