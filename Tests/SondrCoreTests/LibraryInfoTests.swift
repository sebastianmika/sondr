import GRDB
import Testing

@testable import SondrCore

private func seed(_ db: Database) throws {
    try db.execute(sql: "INSERT INTO locations (id, path, added_at) VALUES (1, '/a', 0), (2, '/b', 0)")
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
    // 1-3 only in /a; 4 in both; 5 only in /b; 6 and 7 in /a
    let paths: [(Int, String, Int)] = [
        (1, "/a/1.wav", 1), (2, "/a/2.wav", 1), (3, "/a/3.wav", 1), (4, "/a/4.wav", 1), (4, "/b/4.wav", 2),
        (5, "/b/5.wav", 2), (6, "/a/6.wav", 1), (7, "/a/7.wav", 1),
    ]
    for (sample, path, location) in paths {
        try db.execute(sql: "INSERT INTO sample_paths (sample_id, path, location_id) VALUES (?, ?, ?)", arguments: [sample, path, location])
    }
    try db.execute(sql: "INSERT INTO tags (id, name) VALUES (1, 'kick')")
    try db.execute(sql: "INSERT INTO sample_tags (sample_id, tag_id, source) VALUES (1, 1, 'auto'), (4, 1, 'auto')")
}

@Test func statsCountEachStateOnce() throws {
    let database = try LibraryDatabase(inMemory: ())
    let stats = try database.writer.write { db in
        try seed(db)
        return try LibraryInfo.stats(db)
    }
    #expect(stats == LibraryStats(samples: 7, indexed: 4, pending: 1, failed: 1, missing: 1))
    #expect(try database.writer.read { try LibraryInfo.stats($0) } == stats)
    let empty = try LibraryDatabase(inMemory: ())
    #expect(try empty.writer.read { try LibraryInfo.stats($0) } == LibraryStats())
}

@Test func locationsListSampleCounts() throws {
    let database = try LibraryDatabase(inMemory: ())
    let locations = try database.writer.write { db -> [LocationInfo] in
        try seed(db)
        return try LibraryInfo.locations(db)
    }
    #expect(locations.map(\.path) == ["/a", "/b"])
    #expect(locations.map(\.sampleCount) == [6, 2])
}

@Test func removingALocationKeepsSamplesThatLiveElsewhere() throws {
    let database = try LibraryDatabase(inMemory: ())
    let (removed, left) = try database.writer.write { db -> ([Int64], [Int64]) in
        try seed(db)
        let removed = try LibraryInfo.removeLocation(db, id: 1)
        return (removed, try Int64.fetchAll(db, sql: "SELECT id FROM samples ORDER BY id"))
    }
    #expect(removed.sorted() == [1, 2, 3, 6, 7])
    #expect(left == [4, 5])  // 4 also has a path in /b
    let state = try database.writer.read { db in
        (try String.fetchAll(db, sql: "SELECT path FROM locations"),
         try String.fetchOne(db, sql: "SELECT canonical_path FROM samples WHERE id = 4"),
         try Int.fetchOne(db, sql: "SELECT count(*) FROM sample_tags"))
    }
    #expect(state.0 == ["/b"])
    #expect(state.1 == "/b/4.wav")  // canonical path moved off the removed location
    #expect(state.2 == 1)  // tags of deleted samples are gone, the survivor keeps its tag
}

@Test func removingALocationKeepsMissingSamplesWithoutPaths() throws {
    let database = try LibraryDatabase(inMemory: ())
    let (removed, left) = try database.writer.write { db -> ([Int64], [Int64]) in
        try seed(db)
        // A file that vanished: the scanner keeps the row, flagged missing, with no path.
        try db.execute(sql: "DELETE FROM sample_paths WHERE sample_id = 6")
        let removed = try LibraryInfo.removeLocation(db, id: 2)
        return (removed, try Int64.fetchAll(db, sql: "SELECT id FROM samples ORDER BY id"))
    }
    #expect(removed == [5])
    #expect(left == [1, 2, 3, 4, 6, 7])
}

@Test func removingTheLastLocationEmptiesTheLibrary() throws {
    let database = try LibraryDatabase(inMemory: ())
    try database.writer.write { db in
        try seed(db)
        _ = try LibraryInfo.removeLocation(db, id: 1)
        _ = try LibraryInfo.removeLocation(db, id: 2)
    }
    #expect(try database.writer.read { try LibraryInfo.stats($0) } == LibraryStats())
}
