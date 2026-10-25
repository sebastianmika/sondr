import GRDB
import Testing

@testable import SondrCore

private func insert(_ db: Database, hash: String, brightness: Double?) throws -> Int64 {
    try db.execute(
        sql: """
            INSERT INTO samples (content_hash, canonical_path, filename, rel_path, duration,
                sample_rate, channels, format, file_size, file_mtime, scanned_at, dim_brightness)
            VALUES (?, '/a.wav', 'a.wav', 'a.wav', 1, 48000, 1, 'wav', 1, 0, 0, ?)
            """, arguments: [hash, brightness])
    return db.lastInsertedRowID
}

@Test func percentilesMatchNumpy() {
    // numpy.percentile(range(1, 11), [5, 95]) == [1.45, 9.55]
    let values = (1...10).map(Double.init)
    #expect(abs(DimStats.percentile(values, 5) - 1.45) < 1e-12)
    #expect(abs(DimStats.percentile(values, 95) - 9.55) < 1e-12)
    #expect(DimStats.percentile([4], 5) == 4)
}

@Test func recomputeStoresP5AndP95OfEveryDimWithValues() throws {
    let database = try LibraryDatabase(inMemory: ())
    let ranges = try database.writer.write { db -> [Dim: DimStats.Range] in
        for i in 1...10 { _ = try insert(db, hash: "h\(i)", brightness: Double(i)) }
        _ = try insert(db, hash: "none", brightness: nil)  // ignored
        try DimStats.recompute(db)
        return try DimStats.ranges(db)
    }
    let brightness = try #require(ranges[.brightness])
    #expect(abs(brightness.low - 1.45) < 1e-12 && abs(brightness.high - 9.55) < 1e-12)
    #expect(ranges[.energy] == nil)  // no values for this dim
}

@Test func fewerThanFiveValuesUseMinAndMax() throws {
    let database = try LibraryDatabase(inMemory: ())
    let range = try database.writer.write { db -> DimStats.Range? in
        for (i, v) in [0.2, 0.9, 0.4].enumerated() { _ = try insert(db, hash: "h\(i)", brightness: v) }
        try DimStats.recompute(db)
        return try DimStats.ranges(db)[.brightness]
    }
    #expect(range == DimStats.Range(low: 0.2, high: 0.9))
}

@Test func recomputeIsRepeatableAndFollowsTheData() throws {
    let database = try LibraryDatabase(inMemory: ())
    try database.writer.write { db in
        for i in 1...10 { _ = try insert(db, hash: "h\(i)", brightness: Double(i)) }
        try DimStats.recompute(db)
        try db.execute(sql: "UPDATE samples SET dim_brightness = dim_brightness * 2")
        try DimStats.recompute(db)
        try DimStats.recompute(db)
    }
    let range = try database.writer.read { try DimStats.ranges($0)[.brightness] }
    #expect(abs(range!.low - 2.9) < 1e-12)
    #expect(try database.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM dim_stats") } == 1)
}

@Test func normalisationClipsAndRescales() {
    let range = DimStats.Range(low: 2, high: 6)
    #expect(range.normalise(2) == 0)
    #expect(range.normalise(4) == 0.5)
    #expect(range.normalise(6) == 1)
    #expect(range.normalise(-10) == 0)
    #expect(range.normalise(99) == 1)
}

@Test func degenerateCorpusNormalisesToOneHalf() throws {
    let database = try LibraryDatabase(inMemory: ())
    let range = try database.writer.write { db -> DimStats.Range? in
        for i in 0..<8 { _ = try insert(db, hash: "h\(i)", brightness: 0.37) }
        try DimStats.recompute(db)
        return try DimStats.ranges(db)[.brightness]
    }
    let r = try #require(range)
    #expect(r.low == r.high)
    #expect(r.normalise(0.37) == 0.5)
    #expect(r.normalise(5) == 0.5)
}

@Test func storeWritesAllSixDimColumns() throws {
    let database = try LibraryDatabase(inMemory: ())
    let dims = RawDims(values: [
        .brightness: 0.1, .percussiveness: 2, .energy: 0.3, .tonality: 0.4, .noisiness: 0.5, .duration: 0.6,
    ])
    let row = try database.writer.write { db -> [Double?] in
        let id = try insert(db, hash: "h", brightness: nil)
        try DimStats.store(db, sampleID: id, dims: dims)
        return try Dim.allCases.map { try Double.fetchOne(db, sql: "SELECT \($0.column) FROM samples WHERE id = ?", arguments: [id]) }
    }
    #expect(row == [0.1, 2, 0.3, 0.4, 0.5, 0.6])
}
