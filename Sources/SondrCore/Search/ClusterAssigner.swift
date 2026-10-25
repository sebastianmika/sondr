import Accelerate
import GRDB

/// Assigns samples to the nearest cluster centre by cosine similarity.
///
/// The nearest cluster is always stored, together with the similarity (`cluster_score`). Whether
/// a weak match is shown as "unsorted" is decided when reading, with ``unsortedThreshold``.
public enum ClusterAssigner {
    /// Scores below this are shown as "unsorted". Provisional: chosen on the synthetic fixtures
    /// only, see docs/DECISIONS.md (Story 3.3).
    public static let unsortedThreshold: Float = 0.30

    /// Samples per transaction when assigning in bulk.
    public static let chunkSize = 2048

    /// True if a sample's stored score is too weak to show its cluster (or it has none).
    public static func isUnsorted(score: Double?) -> Bool {
        guard let score else { return true }
        return Float(score) < unsortedThreshold
    }

    /// Centres normalised to unit length, in cluster-id order, ready for ``nearest(to:in:)``.
    public struct Centres: Sendable {
        let ids: [Int]
        let vectors: [[Float]]

        public init(_ centres: [Int: [Float]]) {
            ids = centres.keys.sorted()
            vectors = ids.map { id in
                let v = centres[id]!
                let norm = max(vDSP.rootMeanSquare(v) * Float(v.count).squareRoot(), 1e-12)
                return vDSP.divide(v, norm)
            }
        }
    }

    /// Cluster id and cosine similarity of the closest centre.
    public static func nearest(to vector: [Float], in centres: Centres) -> (cluster: Int, score: Float) {
        let norm = max(vDSP.rootMeanSquare(vector) * Float(vector.count).squareRoot(), 1e-12)
        var best = (cluster: centres.ids[0], score: -Float.infinity)
        for (id, centre) in zip(centres.ids, centres.vectors) {
            let score = vDSP.dot(vector, centre) / norm
            if score > best.score { best = (id, score) }
        }
        return best
    }

    /// Assigns the given sample's cluster inside an open transaction.
    static func assign(_ db: Database, sampleID: Int64, vector: [Float], centres: Centres) throws {
        let (cluster, score) = nearest(to: vector, in: centres)
        try db.execute(
            sql: "UPDATE samples SET cluster_id = ?, cluster_score = ? WHERE id = ?",
            arguments: [cluster, Double(score), sampleID])
    }

    /// Assigns up to `limit` finished samples with an id above `after` that have no cluster yet.
    /// Returns how many, and the last id looked at (nil when nothing was left).
    static func assignChunk(
        _ db: Database, centres: Centres, after: Int64, limit: Int
    ) throws -> (count: Int, last: Int64?) {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT samples.id AS id, vector FROM samples JOIN embeddings ON sample_id = samples.id
                WHERE embed_state = 'done' AND cluster_id IS NULL AND samples.id > ?
                ORDER BY samples.id LIMIT ?
                """, arguments: [after, limit])
        var count = 0
        for row in rows {
            guard let vector = EmbeddingCodec.decode(row["vector"]) else { continue }
            try assign(db, sampleID: row["id"], vector: vector, centres: centres)
            count += 1
        }
        return (count, rows.last?["id"])
    }

    /// Assigns every finished sample that has no cluster yet. Returns how many.
    @discardableResult
    public static func assignMissing(_ db: Database, centres: Centres) throws -> Int {
        var count = 0
        var last: Int64? = 0
        while let after = last {
            let chunk = try assignChunk(db, centres: centres, after: after, limit: chunkSize)
            count += chunk.count
            last = chunk.last
        }
        return count
    }

    /// Like ``assignMissing(_:centres:)`` but one transaction per chunk, so the database is not locked
    /// for a whole library (250k vectors). Stops early, between chunks, if the task is cancelled.
    /// - Parameter report: Called after each chunk with the number of samples assigned so far.
    @discardableResult
    public static func assignMissing(
        database: LibraryDatabase, centres: Centres, chunkSize: Int = ClusterAssigner.chunkSize,
        report: @Sendable (Int) -> Void = { _ in }
    ) async throws -> Int {
        var count = 0
        var last: Int64? = 0
        while let after = last, !Task.isCancelled {
            let chunk = try await database.writer.write {
                try assignChunk($0, centres: centres, after: after, limit: chunkSize)
            }
            count += chunk.count
            last = chunk.last
            if last != nil { report(count) }
        }
        return count
    }
}
