import Foundation
import GRDB
import Testing

@testable import SondrCore

@Test func clusterCountsUseTheUnsortedThreshold() throws {
    let database = try LibraryDatabase(inMemory: ())
    let (clusters, unsorted) = try database.writer.write { db in
        for k in 0..<3 { try db.execute(sql: "INSERT INTO clusters (id, name, color) VALUES (?, ?, 'x')", arguments: [k, "c\(k)"]) }
        // id, state, missing, cluster, score
        let rows: [(Int, String, Int, Int?, Double?)] = [
            (1, "done", 0, 0, 0.6), (2, "done", 0, 0, 0.1), (3, "done", 0, 1, 0.5), (4, "pending", 0, nil, nil),
            (5, "failed", 0, nil, nil), (6, "done", 1, 2, 0.9), (7, "done", 0, nil, nil),
        ]
        for (id, state, missing, cluster, score) in rows {
            try db.execute(
                sql: """
                    INSERT INTO samples (id, content_hash, canonical_path, filename, rel_path, duration, sample_rate,
                        channels, format, file_size, file_mtime, scanned_at, embed_state, missing, cluster_id, cluster_score)
                    VALUES (?, ?, ?, 'f.wav', 'f.wav', 1, 48000, 1, 'wav', 1, 0, 0, ?, ?, ?, ?)
                    """, arguments: [id, "h\(id)", "/a/\(id).wav", state, missing, cluster, score])
        }
        return try LibraryInfo.clusters(db)
    }
    #expect(clusters.map(\.count) == [1, 1, 0])  // sample 2 is too weak, 6 is missing
    #expect(clusters.map(\.name) == ["c0", "c1", "c2"])
    #expect(unsorted == 2)  // 2 (weak) and 7 (no cluster); pending/failed are not "unsorted"
}
