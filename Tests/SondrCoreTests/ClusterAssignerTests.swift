import Foundation
import GRDB
import Testing

@testable import SondrCore

private let dimension = EmbeddingService.embeddingSize

private func axis(_ i: Int, scale: Float = 1) -> [Float] {
    var v = [Float](repeating: 0, count: dimension)
    v[i] = scale
    return v
}

/// Eight orthogonal centres: cluster k points along axis k.
private func orthogonalCentres() -> ClusterAssigner.Centres {
    ClusterAssigner.Centres(Dictionary(uniqueKeysWithValues: (0..<8).map { ($0, axis($0, scale: 3)) }))
}

@Test func everyClusterIdCanBeAssigned() {
    let centres = orthogonalCentres()
    for k in 0..<8 {
        let result = ClusterAssigner.nearest(to: axis(k, scale: 0.5), in: centres)
        #expect(result.cluster == k)
        #expect(abs(result.score - 1) < 1e-6)  // cosine, not dot product: scale does not matter
    }
}

@Test func nearestPicksTheClosestCentreAndReportsTheCosine() {
    var v = axis(2)
    v[5] = 1  // 45 degrees between axes 2 and 5, slightly closer to 2
    v[2] = 1.2
    let result = ClusterAssigner.nearest(to: v, in: orthogonalCentres())
    #expect(result.cluster == 2)
    #expect(abs(result.score - 1.2 / (1.2 * 1.2 + 1).squareRoot()) < 1e-5)
}

@Test func unsortedThresholdSeparatesWeakScores() {
    #expect(ClusterAssigner.isUnsorted(score: nil))
    #expect(ClusterAssigner.isUnsorted(score: Double(ClusterAssigner.unsortedThreshold) - 0.01))
    #expect(!ClusterAssigner.isUnsorted(score: Double(ClusterAssigner.unsortedThreshold) + 0.01))
}

@Test func assignMissingFillsOnlyFinishedSamplesWithoutCluster() throws {
    let database = try LibraryDatabase(inMemory: ())
    let assigned = try database.writer.write { db -> Int in
        for (i, state) in ["done", "done", "pending"].enumerated() {
            try db.execute(
                sql: """
                    INSERT INTO samples (content_hash, canonical_path, filename, rel_path, duration,
                        sample_rate, channels, format, file_size, file_mtime, scanned_at, embed_state)
                    VALUES (?, '/a.wav', 'a.wav', 'a.wav', 1, 48000, 1, 'wav', 1, 0, 0, ?)
                    """, arguments: ["h\(i)", state])
            try db.execute(
                sql: "INSERT INTO embeddings (sample_id, vector) VALUES (?, ?)",
                arguments: [db.lastInsertedRowID, EmbeddingCodec.encode(axis(i == 0 ? 4 : 6))])
        }
        for k in 0..<8 { try db.execute(sql: "INSERT INTO clusters (id, name) VALUES (?, 'c')", arguments: [k]) }
        return try ClusterAssigner.assignMissing(db, centres: orthogonalCentres())
    }
    #expect(assigned == 2)
    let clusters = try database.writer.read { db in
        try Row.fetchAll(db, sql: "SELECT cluster_id FROM samples ORDER BY id").map { $0["cluster_id"] as Int? }
    }
    #expect(clusters == [4, 6, nil])
}

@Test func assignMissingCoversMoreSamplesThanOneChunk() throws {
    let database = try LibraryDatabase(inMemory: ())
    let vector = EmbeddingCodec.encode(axis(4))
    let assigned = try database.writer.write { db -> Int in
        for k in 0..<8 { try db.execute(sql: "INSERT INTO clusters (id, name) VALUES (?, 'c')", arguments: [k]) }
        for i in 0..<2100 {
            try db.execute(
                sql: """
                    INSERT INTO samples (content_hash, canonical_path, filename, rel_path, duration,
                        sample_rate, channels, format, file_size, file_mtime, scanned_at, embed_state)
                    VALUES (?, '/a.wav', 'a.wav', 'a.wav', 1, 48000, 1, 'wav', 1, 0, 0, 'done')
                    """, arguments: ["h\(i)"])
            try db.execute(sql: "INSERT INTO embeddings (sample_id, vector) VALUES (?, ?)", arguments: [db.lastInsertedRowID, vector])
        }
        return try ClusterAssigner.assignMissing(db, centres: orthogonalCentres())
    }
    #expect(assigned == 2100)
    #expect(try database.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM samples WHERE cluster_id = 4") } == 2100)
}
