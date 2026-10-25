import Accelerate
import Foundation
import GRDB

public struct SearchHit: Equatable, Sendable {
    public let id: Int64
    /// Cosine similarity with the query.
    public let score: Float
}

public enum VectorIndexError: Error, Equatable, LocalizedError {
    case wrongDimension(Int)

    public var errorDescription: String? {
        switch self {
        case .wrongDimension(let n): return "Expected a \(VectorIndex.dimension)-d vector, got \(n)."
        }
    }
}

/// All embeddings of the library in one contiguous Float32 buffer (N × 512), for brute-force
/// cosine search. At 250k samples that is 512 MB and a query is one matrix-vector product.
///
/// Stored vectors are expected to be unit length (the models and ``EmbeddingCodec`` keep them
/// so); queries are normalised here. Removal moves the last row into the freed slot, so row
/// order is not stable.
public actor VectorIndex {
    public static let dimension = EmbeddingService.embeddingSize

    nonisolated(unsafe) private var buffer: UnsafeMutablePointer<Float>
    private var capacity: Int
    private var ids: [Int64] = []
    private var rowOfID: [Int64: Int] = [:]

    public init(capacity: Int = 1024) {
        self.capacity = max(capacity, 16)
        buffer = .allocate(capacity: self.capacity * Self.dimension)
    }

    deinit { buffer.deallocate() }

    public var count: Int { ids.count }

    public func contains(_ id: Int64) -> Bool { rowOfID[id] != nil }

    public func vector(for id: Int64) -> [Float]? {
        guard let row = rowOfID[id] else { return nil }
        return Array(UnsafeBufferPointer(start: buffer + row * Self.dimension, count: Self.dimension))
    }

    // MARK: Changing contents

    /// Adds a vector, or replaces the one stored for `id`.
    public func append(id: Int64, vector: [Float]) throws {
        guard vector.count == Self.dimension else { throw VectorIndexError.wrongDimension(vector.count) }
        let row: Int
        if let existing = rowOfID[id] {
            row = existing
        } else {
            reserve(ids.count + 1)
            row = ids.count
            ids.append(id)
            rowOfID[id] = row
        }
        vector.withUnsafeBufferPointer { (buffer + row * Self.dimension).update(from: $0.baseAddress!, count: Self.dimension) }
    }

    /// Removes `id`. Returns false if it was not in the index.
    @discardableResult
    public func remove(id: Int64) -> Bool {
        guard let row = rowOfID.removeValue(forKey: id) else { return false }
        let last = ids.count - 1
        if row != last {
            (buffer + row * Self.dimension).update(from: buffer + last * Self.dimension, count: Self.dimension)
            ids[row] = ids[last]
            rowOfID[ids[row]] = row
        }
        ids.removeLast()
        return true
    }

    /// Replaces the contents with every finished, present sample of the database.
    public func load(from database: LibraryDatabase) async throws {
        let loaded = try await database.writer.read { try Loaded(db: $0) }
        buffer.deallocate()
        buffer = loaded.takeBuffer()
        capacity = loaded.capacity
        ids = loaded.ids
        rowOfID = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
    }

    /// Vectors read from the database into a fresh buffer, handed over to the actor.
    private final class Loaded: @unchecked Sendable {
        private var buffer: UnsafeMutablePointer<Float>?
        let capacity: Int
        private(set) var ids: [Int64] = []

        init(db: Database) throws {
            let sql = """
                FROM embeddings JOIN samples ON samples.id = sample_id
                WHERE embed_state = 'done' AND missing = 0
                """
            let total = try Int.fetchOne(db, sql: "SELECT count(*) " + sql)!
            capacity = max(total + total / 8, 1024)
            let memory = UnsafeMutablePointer<Float>.allocate(capacity: capacity * VectorIndex.dimension)
            buffer = memory
            ids.reserveCapacity(total)
            do {
                let cursor = try Row.fetchCursor(db, sql: "SELECT sample_id, vector " + sql)
                while let row = try cursor.next(), ids.count < capacity {
                    let data: Data = row["vector"]
                    if EmbeddingCodec.decode(data, into: memory + ids.count * VectorIndex.dimension) {
                        ids.append(row["sample_id"])
                    }
                }
            } catch {
                memory.deallocate()
                buffer = nil
                throw error
            }
        }

        func takeBuffer() -> UnsafeMutablePointer<Float> {
            defer { buffer = nil }
            return buffer!
        }
    }

    private func reserve(_ needed: Int) {
        guard needed > capacity else { return }
        let newCapacity = max(needed, capacity * 2)
        let newBuffer = UnsafeMutablePointer<Float>.allocate(capacity: newCapacity * Self.dimension)
        newBuffer.update(from: buffer, count: ids.count * Self.dimension)
        buffer.deallocate()
        buffer = newBuffer
        capacity = newCapacity
    }

    // MARK: Search

    /// The `k` most similar vectors, best first.
    ///
    /// - Parameters:
    ///   - allowed: If given, only these ids can be returned.
    ///   - excluding: An id to leave out (the query sample itself).
    public func topK(_ query: [Float], k: Int, allowed: Set<Int64>? = nil, excluding: Int64? = nil)
        throws -> [SearchHit]
    {
        guard query.count == Self.dimension else { throw VectorIndexError.wrongDimension(query.count) }
        let n = ids.count
        guard k > 0, n > 0 else { return [] }

        let norm = vDSP.rootMeanSquare(query) * Float(Self.dimension).squareRoot()
        guard norm > 0 else { return [] }
        let unit = vDSP.divide(query, norm)

        var scores = [Float](repeating: 0, count: n)
        cblas_sgemv(
            CblasRowMajor, CblasNoTrans, Int32(n), Int32(Self.dimension), 1, buffer, Int32(Self.dimension),
            unit, 1, 0, &scores, 1)

        var best: [SearchHit] = []  // sorted, best first, at most k
        best.reserveCapacity(k + 1)
        for row in 0..<n {
            let score = scores[row]
            if best.count == k, score <= best[k - 1].score { continue }
            let id = ids[row]
            if id == excluding { continue }
            if let allowed, !allowed.contains(id) { continue }
            var position = best.count
            while position > 0, best[position - 1].score < score { position -= 1 }
            best.insert(SearchHit(id: id, score: score), at: position)
            if best.count > k { best.removeLast() }
        }
        return best
    }
}
