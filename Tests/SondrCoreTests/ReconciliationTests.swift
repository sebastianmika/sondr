import Foundation
import GRDB
import Testing

@testable import SondrCore

private func vector() -> Data { Data(count: 512 * 2) }  // Float16 x 512

/// Inserts a sample with a given state and optionally vector / derived data.
@discardableResult
private func insert(
    _ db: Database, hash: String, state: String, vector blob: Data?, derived: Bool, cluster: Int? = nil
) throws -> Int64 {
    try db.execute(
        sql: """
            INSERT INTO samples (content_hash, canonical_path, filename, rel_path, duration,
                sample_rate, channels, format, file_size, file_mtime, scanned_at, embed_state,
                wave_thumb, dim_brightness, dim_percussiveness, dim_energy, dim_tonality,
                dim_noisiness, dim_duration, cluster_id, cluster_score)
            VALUES (?, '/a.wav', 'a.wav', 'a.wav', 1, 48000, 1, 'wav', 1, 0, 0, ?,
                ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
        arguments: [
            hash, state, derived ? Data(count: 128) : nil, derived ? 0.1 : nil, derived ? 0.1 : nil,
            derived ? 0.1 : nil, derived ? 0.1 : nil, derived ? 0.1 : nil, derived ? 0.1 : nil, cluster,
            cluster == nil ? nil : 0.5,
        ])
    let id = db.lastInsertedRowID
    if let blob { try db.execute(sql: "INSERT INTO embeddings (sample_id, vector) VALUES (?, ?)", arguments: [id, blob]) }
    return id
}

private func state(_ db: Database, _ id: Int64) throws -> String {
    try String.fetchOne(db, sql: "SELECT embed_state FROM samples WHERE id = ?", arguments: [id])!
}

@Test func consistentDatabaseIsLeftAlone() throws {
    let database = try LibraryDatabase(inMemory: ())
    let report = try database.writer.write { db -> ReconciliationReport in
        try db.execute(sql: "INSERT INTO clusters (id, name) VALUES (1, 'c')")
        try insert(db, hash: "a", state: "done", vector: vector(), derived: true, cluster: 1)
        try insert(db, hash: "b", state: "pending", vector: nil, derived: false)
        try insert(db, hash: "c", state: "failed", vector: nil, derived: false)
        return try Reconciliation.run(db)
    }
    #expect(report.isClean)
    #expect(try database.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM embeddings") } == 1)
}

@Test func doneSampleWithoutVectorGoesBackToPending() throws {
    let database = try LibraryDatabase(inMemory: ())
    let (report, after) = try database.writer.write { db -> (ReconciliationReport, String) in
        let id = try insert(db, hash: "a", state: "done", vector: nil, derived: true)
        let report = try Reconciliation.run(db)
        return (report, try state(db, id))
    }
    #expect(report == ReconciliationReport(resetToPending: 1, removedVectors: 0))
    #expect(after == "pending")
    let leftovers = try database.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM samples WHERE wave_thumb IS NOT NULL OR dim_energy IS NOT NULL") }
    #expect(leftovers == 0)
}

@Test func vectorOfAnUnfinishedSampleIsRemoved() throws {
    let database = try LibraryDatabase(inMemory: ())
    let report = try database.writer.write { db -> ReconciliationReport in
        try insert(db, hash: "a", state: "pending", vector: vector(), derived: false)
        try insert(db, hash: "b", state: "failed", vector: vector(), derived: false)
        return try Reconciliation.run(db)
    }
    #expect(report == ReconciliationReport(resetToPending: 0, removedVectors: 2))
    #expect(try database.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM embeddings") } == 0)
}

@Test func truncatedVectorResetsItsSample() throws {
    let database = try LibraryDatabase(inMemory: ())
    let (report, after) = try database.writer.write { db -> (ReconciliationReport, String) in
        let id = try insert(db, hash: "a", state: "done", vector: Data(count: 100), derived: true)
        let report = try Reconciliation.run(db)
        return (report, try state(db, id))
    }
    #expect(report == ReconciliationReport(resetToPending: 1, removedVectors: 1))
    #expect(after == "pending")
}

@Test func doneSampleWithMissingDimsOrThumbnailGoesBackToPending() throws {
    let database = try LibraryDatabase(inMemory: ())
    let report = try database.writer.write { db -> ReconciliationReport in
        try insert(db, hash: "a", state: "done", vector: vector(), derived: false)
        return try Reconciliation.run(db)
    }
    #expect(report == ReconciliationReport(resetToPending: 1, removedVectors: 1))
    #expect(try database.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM embeddings") } == 0)
    #expect(try database.writer.write { try Reconciliation.run($0) }.isClean)
}

@Test func unfinishedSampleDoesNotKeepAClusterAndRunsAreIdempotent() throws {
    let database = try LibraryDatabase(inMemory: ())
    try database.writer.write { db in
        try db.execute(sql: "INSERT INTO clusters (id, name) VALUES (2, 'c')")
        try insert(db, hash: "a", state: "pending", vector: nil, derived: false, cluster: 2)
        _ = try Reconciliation.run(db)
    }
    #expect(try database.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM samples WHERE cluster_id IS NOT NULL") } == 0)
    #expect(try database.writer.write { try Reconciliation.run($0) }.isClean)
}
