import Foundation
import GRDB
import Testing

@testable import SondrCore

private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathComponent("library.sqlite")
}

private func schema(_ writer: any DatabaseWriter) throws -> [String] {
    try writer.read { db in
        try String.fetchAll(db, sql: "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name")
    }
}

private func insertSample(_ db: Database, hash: String = "h1") throws -> Int64 {
    try db.execute(
        sql: """
            INSERT INTO samples (content_hash, canonical_path, filename, rel_path, duration,
                sample_rate, channels, format, file_size, file_mtime, scanned_at)
            VALUES (?, '/a/kick.wav', 'kick.wav', 'kick.wav', 1, 48000, 1, 'wav', 10, 0, 0)
            """, arguments: [hash])
    return db.lastInsertedRowID
}

@Test func freshDatabaseHasAllTables() throws {
    let database = try LibraryDatabase(inMemory: ())
    let tables = try database.writer.read { db in
        try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
    }
    for name in [
        "locations", "samples", "sample_paths", "embeddings", "tags", "sample_tags",
        "removed_auto_tags", "clusters", "cluster_centres", "dim_stats", "meta", "sample_groups", "maps",
        "map_points",
    ] {
        #expect(tables.contains(name), "missing table \(name)")
    }
}

@Test func reopeningAFileDatabaseKeepsItsDataAndSchema() throws {
    let url = temporaryDatabaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let first = try LibraryDatabase(url: url)
    try first.writer.write { db in _ = try insertSample(db) }
    let before = try schema(first.writer)

    let second = try LibraryDatabase(url: url)
    #expect(try second.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM samples") } == 1)
    #expect(try schema(second.writer) == before)
}

@Test func fileDatabaseUsesWalAndForeignKeys() throws {
    let url = temporaryDatabaseURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let database = try LibraryDatabase(url: url)
    let (mode, foreignKeys) = try database.writer.read { db in
        (try String.fetchOne(db, sql: "PRAGMA journal_mode"), try Int.fetchOne(db, sql: "PRAGMA foreign_keys"))
    }
    #expect(mode == "wal")
    #expect(foreignKeys == 1)
}

@Test func foreignKeyViolationsRaise() throws {
    let database = try LibraryDatabase(inMemory: ())
    #expect(throws: DatabaseError.self) {
        try database.writer.write { db in
            try db.execute(sql: "INSERT INTO sample_paths (sample_id, path) VALUES (999, '/x.wav')")
        }
    }
    #expect(throws: DatabaseError.self) {
        try database.writer.write { db in
            try db.execute(sql: "INSERT INTO embeddings (sample_id, vector) VALUES (999, x'00')")
        }
    }
}

@Test func uniqueConstraintsRaise() throws {
    let database = try LibraryDatabase(inMemory: ())
    try database.writer.write { db in _ = try insertSample(db, hash: "same") }
    #expect(throws: DatabaseError.self) {
        try database.writer.write { db in _ = try insertSample(db, hash: "same") }
    }
}

@Test func invalidEmbedStateOrTagSourceIsRejected() throws {
    let database = try LibraryDatabase(inMemory: ())
    #expect(throws: DatabaseError.self) {
        try database.writer.write { db in
            let id = try insertSample(db)
            try db.execute(sql: "UPDATE samples SET embed_state = 'weird' WHERE id = ?", arguments: [id])
        }
    }
    #expect(throws: DatabaseError.self) {
        try database.writer.write { db in
            let id = try insertSample(db)
            try db.execute(sql: "INSERT INTO tags (name) VALUES ('kick')")
            try db.execute(
                sql: "INSERT INTO sample_tags (sample_id, tag_id, source) VALUES (?, ?, 'robot')",
                arguments: [id, db.lastInsertedRowID])
        }
    }
}

@Test func deletingASampleRemovesItsDependentRows() throws {
    let database = try LibraryDatabase(inMemory: ())
    try database.writer.write { db in
        let id = try insertSample(db)
        try db.execute(sql: "INSERT INTO sample_paths (sample_id, path) VALUES (?, '/a/kick.wav')", arguments: [id])
        try db.execute(sql: "INSERT INTO embeddings (sample_id, vector) VALUES (?, x'00')", arguments: [id])
        try db.execute(sql: "INSERT INTO tags (name) VALUES ('kick')")
        let tag = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO sample_tags (sample_id, tag_id, source) VALUES (?, ?, 'auto')", arguments: [id, tag])
        try db.execute(sql: "INSERT INTO removed_auto_tags (sample_id, tag_id) VALUES (?, ?)", arguments: [id, tag])
        try db.execute(sql: "DELETE FROM samples WHERE id = ?", arguments: [id])
    }
    for table in ["sample_paths", "embeddings", "sample_tags", "removed_auto_tags"] {
        let count = try database.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM \(table)") }
        #expect(count == 0, "\(table) not cleaned up")
    }
}

@Test func unwritablePathReportsAnError() {
    #expect(throws: LibraryDatabaseError.self) {
        try LibraryDatabase(url: URL(fileURLWithPath: "/dev/null/nope/library.sqlite"))
    }
}

@Test func defaultPathIsInApplicationSupport() {
    if ProcessInfo.processInfo.environment["SONDR_DB"] == nil {
        #expect(LibraryDatabase.defaultURL().path.hasSuffix("Application Support/Sondr/library.sqlite"))
    }
}

@Test func deletingASampleRemovesItsMapPoints() throws {
    let database = try LibraryDatabase(inMemory: ())
    try database.writer.write { db in
        let id = try insertSample(db)
        try db.execute(
            sql: """
                INSERT INTO maps (created_at, model_version, parameters, fitted_count, input_dims, work_dims,
                    ref_embedding, ref_work) VALUES (0, 'm', '{}', 1, 512, 50, x'00', x'00')
                """)
        try db.execute(
            sql: "INSERT INTO map_points (map_id, sample_id, x, y, fitted) VALUES (?, ?, 0, 0, 1)",
            arguments: [db.lastInsertedRowID, id])
        try db.execute(sql: "DELETE FROM samples WHERE id = ?", arguments: [id])
    }
    #expect(try database.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM map_points") } == 0)
}
