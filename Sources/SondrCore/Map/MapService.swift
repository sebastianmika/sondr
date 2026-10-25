import Foundation
import GRDB
import MetalTSNE
import simd

public enum MapError: Error, Equatable, LocalizedError {
    case notEnoughSamples(have: Int, need: Int)

    public var errorDescription: String? {
        switch self {
        case .notEnoughSamples(let have, let need):
            return "A map needs at least \(need) indexed samples; the library has \(have)."
        }
    }
}

public struct MapProgress: Sendable {
    public enum Stage: Sendable { case loading, fitting, placing, saving }
    public let stage: Stage
    public let done: Int
    public let total: Int
    /// While fitting: where the fitted samples are right now, in the order of ``MapPreview/sampleIDs``.
    public let positions: [SIMD2<Float>]?
    /// While fitting: the samples `positions` belong to.
    public let sampleIDs: [Int64]?

    public init(stage: Stage, done: Int, total: Int, positions: [SIMD2<Float>]? = nil, sampleIDs: [Int64]? = nil) {
        self.stage = stage
        self.done = done
        self.total = total
        self.positions = positions
        self.sampleIDs = sampleIDs
    }
}

/// A finished fit that has not been saved. Keep it with ``MapService/keep(_:onProgress:)`` or drop it.
public struct MapPreview: Sendable {
    public let parameters: MapParameters
    public let modelVersion: String
    /// The samples the layout was computed from.
    public let sampleIDs: [Int64]
    /// Their positions, in the same order.
    public let positions: [SIMD2<Float>]
    let state: TSNEModelState
    public let seconds: Double
    /// True if the layout was rotated, flipped and scaled to match the map that was current at the time.
    public let isAligned: Bool
}

/// Computes, stores and extends the 2D map.
///
/// A map is a layout of a random sample of the library (``MapParameters/sampleSize``) plus every
/// other sample placed onto it, which is cheap. Fitting shows up as a ``MapPreview`` first, and
/// nothing is written until the preview is kept.
public actor MapService {
    private static let chunk = 20_000
    private let database: LibraryDatabase
    private var tsne: TSNE?
    private var cached: (mapID: Int64, model: TSNEModel)?

    public init(database: LibraryDatabase) {
        self.database = database
    }

    /// Fits a layout without saving anything. Cancel the calling task to stop it.
    ///
    /// - Parameter alignToCurrent: Rotate, flip and scale the result to match the current map (if it
    ///   comes from the same embedding model) over the samples they share.
    public func preview(
        parameters requested: MapParameters, modelVersion: String, alignToCurrent: Bool = true,
        onProgress: (@Sendable (MapProgress) -> Void)? = nil
    ) async throws -> MapPreview {
        let started = ContinuousClock.now
        let parameters = requested.clamped()
        onProgress?(MapProgress(stage: .loading, done: 0, total: 0, positions: nil))
        let available = try await indexedSampleIDs()
        guard available.count >= MapParameters.minimumSamples else {
            throw MapError.notEnoughSamples(have: available.count, need: MapParameters.minimumSamples)
        }
        let chosen = Self.randomSample(of: available, count: parameters.sampleSize, seed: parameters.seed)
        let (ids, vectors) = try await loadVectors(chosen)
        try Task.checkCancellation()
        guard ids.count >= MapParameters.minimumSamples else {
            throw MapError.notEnoughSamples(have: ids.count, need: MapParameters.minimumSamples)
        }

        let tsne = try fitter(parameters.tsne(pointCount: ids.count, inputDimensions: EmbeddingService.embeddingSize))
        let problem = try tsne.prepare(flatData: vectors, count: ids.count, dimensions: EmbeddingService.embeddingSize)
        try Task.checkCancellation()
        let session = try await problem.makeFittedSession { progress in
            onProgress?(
                MapProgress(
                    stage: .fitting, done: progress.iteration, total: progress.totalIterations, positions: progress.positions,
                    sampleIDs: ids))
        }
        let model = try session.makeModel()
        var state = model.state
        var positions = model.embedding
        var aligned = false
        if alignToCurrent, let transform = try await alignment(of: positions, ids: ids, modelVersion: modelVersion) {
            positions = positions.map(transform.apply)
            state.embedding = positions
            aligned = true
        }
        let seconds = started.duration(to: .now)
        return MapPreview(
            parameters: parameters, modelVersion: modelVersion, sampleIDs: ids, positions: positions, state: state,
            seconds: Double(seconds.components.seconds) + Double(seconds.components.attoseconds) * 1e-18, isAligned: aligned)
    }

    /// How to move `positions` onto the current map, if there is a current map of the same model with enough shared samples.
    private func alignment(of positions: [SIMD2<Float>], ids: [Int64], modelVersion: String) async throws -> MapAlignment.Transform? {
        let current = try await database.writer.read { db -> [Int64: SIMD2<Float>]? in
            guard let map = try MapStore.current(db), map.modelVersion == modelVersion else { return nil }
            return Dictionary(uniqueKeysWithValues: try MapStore.points(db, mapID: map.id).map { ($0.sampleID, SIMD2($0.x, $0.y)) })
        }
        guard let current else { return nil }
        var source: [SIMD2<Float>] = [], target: [SIMD2<Float>] = []
        for (id, position) in zip(ids, positions) {
            if let there = current[id] { source.append(position); target.append(there) }
        }
        return MapAlignment.transform(from: source, to: target)
    }

    /// Places every other indexed sample onto the previewed layout and saves it as the current map
    /// (the old current map becomes the previous one).
    @discardableResult
    public func keep(
        _ preview: MapPreview, onProgress: (@Sendable (MapProgress) -> Void)? = nil
    ) async throws -> StoredMap {
        let tsne = try fitter(preview.parameters.tsne(pointCount: preview.sampleIDs.count, inputDimensions: EmbeddingService.embeddingSize))
        let model = try tsne.restoreModel(preview.state)
        var points = zip(preview.sampleIDs, preview.positions).map {
            MapPoint(sampleID: $0, x: $1.x, y: $1.y, fitted: true)
        }
        let fitted = Set(preview.sampleIDs)
        let rest = try await indexedSampleIDs().filter { !fitted.contains($0) }
        for start in stride(from: 0, to: rest.count, by: Self.chunk) {
            try Task.checkCancellation()
            onProgress?(MapProgress(stage: .placing, done: start, total: rest.count, positions: nil))
            points += try await place(Array(rest[start..<min(start + Self.chunk, rest.count)]), with: model)
        }
        try Task.checkCancellation()
        onProgress?(MapProgress(stage: .saving, done: rest.count, total: rest.count, positions: nil))
        let id = try await database.writer.write { [points] db in
            // Samples removed since the preview (a removed location) would break the foreign key.
            let existing = Set(try Int64.fetchAll(db, sql: "SELECT id FROM samples"))
            return try MapStore.save(
                db, state: preview.state, parameters: preview.parameters, modelVersion: preview.modelVersion,
                points: points.filter { existing.contains($0.sampleID) })
        }
        cached = (id, model)
        let stored = try await database.writer.read { try MapStore.current($0) }
        return stored!
    }

    /// Places indexed samples that have no point on the current map yet. Returns how many.
    @discardableResult
    public func placeNewSamples(onProgress: (@Sendable (MapProgress) -> Void)? = nil) async throws -> Int {
        guard let map = try await database.writer.read({ try MapStore.current($0) }) else { return 0 }
        let model = try await model(for: map)
        var total = 0
        var after: Int64 = 0
        while true {
            try Task.checkCancellation()
            let cursor = after
            let ids = try await database.writer.read { try MapStore.unmappedSampleIDs($0, mapID: map.id, after: cursor, limit: Self.chunk) }
            guard let last = ids.last else { break }
            after = last
            let points = try await place(ids, with: model)
            try await database.writer.write { try MapStore.addPoints($0, mapID: map.id, points: points) }
            total += points.count
            onProgress?(MapProgress(stage: .placing, done: total, total: total, positions: nil))
        }
        return total
    }

    /// Makes the previous map current again. Returns false if there is none.
    public func restorePrevious() async throws -> Bool {
        cached = nil
        return try await database.writer.write { try MapStore.restorePrevious($0) }
    }

    // MARK: Helpers

    private func fitter(_ parameters: TSNEParameters) throws -> TSNE {
        if let tsne {
            tsne.parameters = parameters
            return tsne
        }
        let created = try TSNE(parameters: parameters)
        tsne = created
        return created
    }

    private func model(for map: StoredMap) async throws -> TSNEModel {
        if let cached, cached.mapID == map.id { return cached.model }
        let id = map.id
        guard let state = try await database.writer.read({ try MapStore.modelState($0, mapID: id) }) else {
            throw MapError.notEnoughSamples(have: 0, need: MapParameters.minimumSamples)
        }
        let model = try fitter(map.parameters.tsne(pointCount: map.fittedCount, inputDimensions: state.inputDimensions)).restoreModel(state)
        cached = (map.id, model)
        return model
    }

    private func place(_ ids: [Int64], with model: TSNEModel) async throws -> [MapPoint] {
        let (found, vectors) = try await loadVectors(ids)
        guard !found.isEmpty else { return [] }
        let positions = try model.project(flatData: vectors, count: found.count, dimensions: EmbeddingService.embeddingSize)
        return zip(found, positions).map { MapPoint(sampleID: $0, x: $1.x, y: $1.y, fitted: false) }
    }

    private func indexedSampleIDs() async throws -> [Int64] {
        try await database.writer.read {
            try Int64.fetchAll(
                $0,
                sql: """
                    SELECT samples.id FROM samples JOIN embeddings ON embeddings.sample_id = samples.id
                    WHERE samples.embed_state = 'done' AND samples.missing = 0 ORDER BY samples.id
                    """)
        }
    }

    /// Vectors of `ids` (in that order) as one flat array. Samples without a readable vector are left out.
    private func loadVectors(_ ids: [Int64]) async throws -> (ids: [Int64], vectors: [Float]) {
        let size = EmbeddingService.embeddingSize
        var kept: [Int64] = []
        var flat: [Float] = []
        flat.reserveCapacity(ids.count * size)
        for start in stride(from: 0, to: ids.count, by: 500) {
            try Task.checkCancellation()
            let batch = Array(ids[start..<min(start + 500, ids.count)])
            let blobs: [Int64: Data] = try await database.writer.read { db in
                let marks = batch.map { _ in "?" }.joined(separator: ",")
                var found: [Int64: Data] = [:]
                for row in try Row.fetchAll(
                    db, sql: "SELECT sample_id, vector FROM embeddings WHERE sample_id IN (\(marks))",
                    arguments: StatementArguments(batch))
                {
                    found[row["sample_id"]] = row["vector"]
                }
                return found
            }
            for id in batch {
                guard let blob = blobs[id], let vector = EmbeddingCodec.decode(blob) else { continue }
                kept.append(id)
                flat += vector
            }
        }
        return (kept, flat)
    }

    /// `count` of `ids`, chosen at random but the same for the same seed, in ascending order.
    static func randomSample(of ids: [Int64], count: Int, seed: UInt64) -> [Int64] {
        guard count < ids.count else { return ids }
        var generator = SplitMix(seed: seed)
        var pool = ids
        for i in 0..<count {
            let j = i + Int(generator.next() % UInt64(pool.count - i))
            pool.swapAt(i, j)
        }
        return pool.prefix(count).sorted()
    }

    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
