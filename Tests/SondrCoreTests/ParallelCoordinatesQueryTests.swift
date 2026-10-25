import GRDB
import Testing

@testable import SondrCore

/// 40 indexed samples with known raw dims: brightness i, percussiveness 41 - i, energy constant,
/// tonality and noisiness by pattern, duration i / 10.
private func makeLibrary(count: Int = 40) throws -> LibraryDatabase {
    let database = try LibraryDatabase(inMemory: ())
    try database.writer.write { db in
        for i in 1...count {
            try db.execute(
                sql: """
                    INSERT INTO samples (id, content_hash, canonical_path, filename, rel_path, duration, sample_rate,
                        channels, format, file_size, file_mtime, scanned_at, embed_state,
                        dim_brightness, dim_percussiveness, dim_energy, dim_tonality, dim_noisiness, dim_duration)
                    VALUES (?, ?, '/a.wav', 'a.wav', 'a.wav', 1, 48000, 1, 'wav', 1, 0, 0, 'done', ?, ?, 0.3, ?, ?, ?)
                    """,
                arguments: [i, "h\(i)", Double(i), Double(count + 1 - i), Double(i % 4) / 4, Double(i % 7) / 7, Double(i) / 10])
        }
        // two samples that are not indexed yet: never match a brush
        for i in 1000..<1002 {
            try db.execute(
                sql: """
                    INSERT INTO samples (id, content_hash, canonical_path, filename, rel_path, duration, sample_rate,
                        channels, format, file_size, file_mtime, scanned_at, embed_state)
                    VALUES (?, ?, '/a.wav', 'a.wav', 'a.wav', 1, 48000, 1, 'wav', 1, 0, 0, 'pending')
                    """, arguments: [i, "h\(i)"])
        }
        try DimStats.recompute(db)
    }
    return database
}

private func expected(_ database: LibraryDatabase, _ brush: [Dim: ClosedRange<Double>]) throws -> [Int64] {
    try database.writer.read { db in
        let ranges = try DimStats.ranges(db)
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM samples WHERE dim_brightness IS NOT NULL ORDER BY id")
        return rows.filter { row in
            brush.allSatisfy { dim, range in
                guard let raw: Double = row[dim.column] else { return false }
                return range.contains(ranges[dim]!.normalise(raw))
            }
        }.map { $0["id"] }
    }
}

private func browsed(_ database: LibraryDatabase, _ brush: [Dim: ClosedRange<Double>]) throws -> [Int64] {
    var filter = SampleFilter()
    filter.dimRanges = brush
    return try database.writer.read { try SampleQuery.browse($0, filter: filter, sort: SampleSort(.added), limit: 1000).rows.map(\.id) }
}

@Test func brushingTwoAxesNarrowsTheTableToExactlyTheMatchingSamples() throws {
    let database = try makeLibrary()
    let brush: [Dim: ClosedRange<Double>] = [.brightness: 0.3...0.8, .percussiveness: 0.5...1.0]
    let ids = try browsed(database, brush)
    #expect(ids == (try expected(database, brush)))
    #expect(!ids.isEmpty && ids.count < 40)
    // each brush alone is wider than both together
    let one = try browsed(database, [.brightness: 0.3...0.8])
    let two = try browsed(database, [.percussiveness: 0.5...1.0])
    #expect(Set(ids) == Set(one).intersection(two))
    #expect(one.count > ids.count && two.count > ids.count)
}

@Test(arguments: [
    [Dim.brightness: 0.0...1.0],
    [.brightness: 0.0...0.25],
    [.brightness: 0.75...1.0],
    [.tonality: 0.5...0.5],
    [.duration: 0.4...0.6, .noisiness: 0.0...0.5],
    [.energy: 0.0...0.4],  // constant dim: everything is 0.5
    [.energy: 0.6...1.0],
    [.brightness: 0.9...0.95, .percussiveness: 0.9...0.95],  // no sample in both
])
func brushedQueriesAgreeWithAReferenceFilter(brush: [Dim: ClosedRange<Double>]) throws {
    let database = try makeLibrary()
    #expect(try browsed(database, brush) == (try expected(database, brush)))
}

@Test func fullRangeBrushStillExcludesSamplesWithoutDims() throws {
    let database = try makeLibrary()
    let ids = try browsed(database, [.brightness: 0...1])
    #expect(ids.count == 40)
    #expect(!ids.contains(1000))
}

@Test func brushIsAlsoAppliedToTextSearchSetsAndTagCounts() throws {
    let database = try makeLibrary()
    var filter = SampleFilter()
    filter.dimRanges = [.brightness: 0.0...0.1]
    let ids = try database.writer.read { try SampleQuery.ids($0, filter: filter) }
    #expect(Set(ids) == Set(try expected(database, filter.dimRanges)))
    _ = try database.writer.read { try SampleQuery.tagCounts($0, filter: filter) }
}

@Test func dimSampleIsBoundedRepeatableAndNormalised() throws {
    let database = try makeLibrary()
    let sample = try database.writer.read { try SampleQuery.dimSample($0, filter: SampleFilter(), limit: 10) }
    #expect(sample.lines.count == 10)
    #expect(sample.total == 40)
    #expect(sample.lines.allSatisfy { $0.count == 6 && $0.allSatisfy { (0...1).contains($0) } })
    let again = try database.writer.read { try SampleQuery.dimSample($0, filter: SampleFilter(), limit: 10) }
    #expect(sample == again)

    var filter = SampleFilter()
    filter.dimRanges = [.brightness: 0.5...1.0]
    let brushed = try database.writer.read { try SampleQuery.dimSample($0, filter: filter, limit: 1000) }
    #expect(brushed.total == brushed.lines.count && brushed.total < 40)
    #expect(brushed.lines.allSatisfy { $0[0] >= 0.5 })
}

@Test func dimSampleOfAnEmptyLibraryIsEmpty() throws {
    let database = try LibraryDatabase(inMemory: ())
    let sample = try database.writer.read { try SampleQuery.dimSample($0, filter: SampleFilter()) }
    #expect(sample == DimSample(lines: [], total: 0))
}

@Test func degenerateDimNormalisesToTheMiddle() throws {
    let database = try makeLibrary()
    #expect(try browsed(database, [.energy: 0.4...0.6]).count == 40)
    #expect(try browsed(database, [.energy: 0.0...0.3]).isEmpty)
}
