import Foundation
import GRDB
import Metal

@testable import SondrCore

let metalAvailable = MTLCreateSystemDefaultDevice() != nil

/// Unit-length 512-d vectors in `clusters` well separated groups; sample `i` belongs to cluster `i % clusters`.
func clusterVector(_ i: Int, clusters: Int = 4) -> [Float] {
    var centreState = (UInt64(i % clusters) + 1) &* 0x9E37_79B9_7F4A_7C15 | 1  // `| 1` of neighbouring seeds would collide
    var noiseState = UInt64(i) &* 7919 | 1
    func next(_ state: inout UInt64) -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: state >> 11) % 2000 - 1000) / 1000
    }
    var v = [Float](repeating: 0, count: 512)
    for d in 0..<512 { v[d] = next(&centreState) * 3 + next(&noiseState) * 0.35 }
    let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return v.map { $0 / norm }
}

func makeLibrary(samples: Int, from start: Int = 0, into database: LibraryDatabase? = nil) throws -> (LibraryDatabase, [Int64]) {
    let database = try database ?? LibraryDatabase(inMemory: ())
    let ids = try database.writer.write { db -> [Int64] in
        try (start..<(start + samples)).map { i in
            try db.execute(
                sql: """
                    INSERT INTO samples (content_hash, canonical_path, filename, rel_path, duration,
                        sample_rate, channels, format, file_size, file_mtime, scanned_at, embed_state)
                    VALUES (?, ?, ?, ?, 1, 48000, 1, 'wav', 1, 0, 0, 'done')
                    """, arguments: ["h\(i)", "/\(i).wav", "\(i).wav", "\(i).wav"])
            let id = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO embeddings (sample_id, vector) VALUES (?, ?)",
                arguments: [id, EmbeddingCodec.encode(clusterVector(i))])
            return id
        }
    }
    return (database, ids)
}

