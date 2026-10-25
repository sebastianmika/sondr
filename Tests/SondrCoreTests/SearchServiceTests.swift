import Foundation
import GRDB
import Testing

@testable import SondrCore

private let dimension = EmbeddingService.embeddingSize

private func unit(_ axis: Int, _ other: Int? = nil, mix: Float = 0) -> [Float] {
    var v = [Float](repeating: 0, count: dimension)
    v[axis] = 1
    if let other { v[other] = mix }
    let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return v.map { $0 / norm }
}

private struct Spec {
    var id: Int64
    var filename: String
    var relPath: String
    var duration: Double
    var tags: [String] = []
    var cluster: Int? = nil
    var score: Double? = nil
    var missing = false
    var state = "done"
    var location: Int64 = 1
    var vector: [Float]? = nil
}

/// Twelve hand-made samples; vectors point along axis `id` unless given.
private let specs: [Spec] = [
    Spec(id: 1, filename: "Kick_Hard.wav", relPath: "Drums/Kicks/Kick_Hard.wav", duration: 0.3, tags: ["kick", "drum", "hard"], cluster: 0, score: 0.6),
    Spec(id: 2, filename: "kick_soft.wav", relPath: "Drums/Kicks/kick_soft.wav", duration: 0.5, tags: ["kick", "drum", "soft"], cluster: 0, score: 0.55),
    Spec(id: 3, filename: "snare_tight.wav", relPath: "Drums/Snares/snare_tight.wav", duration: 0.4, tags: ["snare", "drum", "tight"], cluster: 1, score: 0.5),
    Spec(id: 4, filename: "Hat_Open.wav", relPath: "Drums/Hats/Hat_Open.wav", duration: 1.2, tags: ["hat", "drum"], cluster: 2, score: 0.2),
    Spec(id: 5, filename: "bass_sub.wav", relPath: "Synth/Bass/bass_sub.wav", duration: 2.0, tags: ["bass", "sub"], cluster: 3, score: 0.62),
    Spec(id: 6, filename: "pad_warm.wav", relPath: "Synth/Pads/pad_warm.wav", duration: 6.0, tags: ["pad", "warm"], cluster: 4, score: 0.4),
    Spec(id: 7, filename: "lead_100%_saw.wav", relPath: "Synth/Leads/lead_100%_saw.wav", duration: 1.0, tags: ["lead", "saw"], cluster: 5, score: 0.31),
    Spec(id: 8, filename: "vox_ah.wav", relPath: "Vocals/vox_ah.wav", duration: 1.5, tags: ["vocal"], cluster: nil, score: nil),
    Spec(id: 9, filename: "riser_long.wav", relPath: "FX/riser_long.wav", duration: 8.0, tags: ["effect", "riser"], cluster: 7, score: 0.45, location: 2),
    Spec(id: 10, filename: "gone_kick.wav", relPath: "Drums/Kicks/gone_kick.wav", duration: 0.3, tags: ["kick"], cluster: 0, score: 0.6, missing: true),
    Spec(id: 11, filename: "broken.wav", relPath: "Broken/broken.wav", duration: 0.2, tags: [], state: "failed"),
    Spec(id: 12, filename: "pending.wav", relPath: "New/pending.wav", duration: 0.7, tags: ["kick"], state: "pending", location: 2),
]

private func makeSearch(_ specs: [Spec] = specs) async throws -> (LibraryDatabase, VectorIndex, SearchService) {
    let database = try LibraryDatabase(inMemory: ())
    let index = VectorIndex()
    try await database.writer.write { db in
        try db.execute(sql: "INSERT INTO locations (id, path, added_at) VALUES (1, '/lib1', 0), (2, '/lib2', 0)")
        for k in Set(specs.compactMap(\.cluster)) { try db.execute(sql: "INSERT INTO clusters (id, name) VALUES (?, 'c')", arguments: [k]) }
        for spec in specs {
            let derived = spec.state == "done"
            try db.execute(
                sql: """
                    INSERT INTO samples (id, content_hash, canonical_path, filename, rel_path, duration,
                        sample_rate, channels, format, file_size, file_mtime, scanned_at, missing, embed_state,
                        cluster_id, cluster_score, dim_brightness, dim_percussiveness, dim_energy, dim_tonality,
                        dim_noisiness, dim_duration)
                    VALUES (?, ?, ?, ?, ?, ?, 48000, 1, 'wav', 1, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    spec.id, "h\(spec.id)", "/lib/\(spec.relPath)", spec.filename, spec.relPath, spec.duration,
                    Double(spec.id), spec.missing ? 1 : 0, spec.state, spec.cluster, spec.score,
                    derived ? 0.1 * Double(spec.id) : nil, derived ? 1.0 : nil, derived ? 0.5 : nil, derived ? 0.5 : nil,
                    derived ? 0.5 : nil, derived ? 0.5 : nil,
                ])
            try db.execute(sql: "INSERT INTO sample_paths (sample_id, path, location_id) VALUES (?, ?, ?)",
                arguments: [spec.id, "/lib/\(spec.relPath)", spec.location])
            for tag in spec.tags {
                try db.execute(sql: "INSERT OR IGNORE INTO tags (name) VALUES (?)", arguments: [tag])
                try db.execute(
                    sql: "INSERT INTO sample_tags (sample_id, tag_id, source) SELECT ?, id, 'auto' FROM tags WHERE name = ?",
                    arguments: [spec.id, tag])
            }
        }
    }
    for spec in specs where spec.state == "done" && !spec.missing {
        try await index.append(id: spec.id, vector: spec.vector ?? unit(Int(spec.id)))
    }
    let embedder = AxisEmbedder()
    return (database, index, SearchService(database: database, index: index, embedder: embedder))
}

/// Text "axis N" embeds to the unit vector along axis N.
private struct AxisEmbedder: Embedder {
    func modelVersion() async throws -> String { "axis" }
    func embed(audio clips: [[Float]]) async throws -> [[Float]] { clips.map { _ in unit(0) } }
    func embed(text: String) async throws -> [Float] {
        let n = Int(text.split(separator: " ").last ?? "0") ?? 0
        return unit(n)
    }
}

private func browseIDs(_ database: LibraryDatabase, _ filter: SampleFilter, sort: SampleSort = SampleSort(.added)) async throws -> [Int64] {
    try await database.writer.read { try SampleQuery.browse($0, filter: filter, sort: sort).rows.map(\.id) }
}

private func filter(_ configure: (inout SampleFilter) -> Void) -> SampleFilter {
    var f = SampleFilter()
    configure(&f)
    return f
}

struct FilterCase: Sendable, CustomTestStringConvertible {
    let name: String
    let filter: SampleFilter
    let expected: [Int64]
    var testDescription: String { name }
}

let filterCases: [FilterCase] = {
    var cases: [FilterCase] = []
    func add(_ name: String, _ filter: SampleFilter, _ expected: [Int64]) {
        cases.append(FilterCase(name: name, filter: filter, expected: expected))
    }
    add("default hides missing", filter { _ in }, [1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12])
    add("include missing", filter { $0.includeMissing = true }, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])
    add("one tag", filter { $0.tags = ["kick"] }, [1, 2, 12])
    add("tags are ANDed", filter { $0.tags = ["kick", "hard"] }, [1])
    add("tags with no common sample", filter { $0.tags = ["kick", "pad"] }, [])
    add("unknown tag", filter { $0.tags = ["nope"] }, [])
    add("duplicate tag in filter", filter { $0.tags = ["kick", "kick"] }, [1, 2, 12])
    add("keyword in filename, any case", filter { $0.keyword = "KICK" }, [1, 2])
    add("keyword in folder", filter { $0.keyword = "snares" }, [3])
    add("keyword words are ANDed", filter { $0.keyword = "drums open" }, [4])
    add("percent is literal", filter { $0.keyword = "100%" }, [7])
    add("underscore is literal", filter { $0.keyword = "_ah" }, [8])
    add("min duration", filter { $0.minDuration = 2 }, [5, 6, 9])
    add("max duration", filter { $0.maxDuration = 0.4 }, [1, 3, 11])
    add("duration range", filter { $0.minDuration = 1; $0.maxDuration = 2 }, [4, 5, 7, 8])
    add("cluster", filter { $0.cluster = .cluster(0) }, [1, 2])
    add("weak assignment is not in its cluster", filter { $0.cluster = .cluster(2) }, [])
    add("unsorted", filter { $0.cluster = .unsorted }, [4, 8, 11, 12])
    add("location", filter { $0.locationID = 2 }, [9, 12])
    add("embed state", filter { $0.embedState = "failed" }, [11])
    add("combined", filter { $0.tags = ["drum"]; $0.maxDuration = 0.45; $0.cluster = .cluster(0) }, [1])
    add("combined, empty", filter { $0.tags = ["drum"]; $0.locationID = 2 }, [])
    return cases
}()

@Test(arguments: filterCases)
func filtersCombineCorrectly(testCase: FilterCase) async throws {
    let (database, _, _) = try await makeSearch()
    let ids = try await browseIDs(database, testCase.filter)
    let total = try await database.writer.read { try SampleQuery.browse($0, filter: testCase.filter).total }
    #expect(ids == testCase.expected, "\(testCase.name): \(ids)")
    #expect(total == ids.count)
}

@Test(arguments: [
    (SampleSort(.filename), [5, 11, 4, 1, 2, 7, 6, 12, 9, 3, 8]),
    (SampleSort(.filename, ascending: false), [8, 3, 9, 12, 6, 7, 2, 1, 4, 11, 5]),
    (SampleSort(.duration, ascending: false), [9, 6, 5, 8, 4, 7, 12, 2, 3, 1, 11]),
    (SampleSort(.added), [1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12]),
    (SampleSort(.brightness, ascending: false), [9, 8, 7, 6, 5, 4, 3, 2, 1, 11, 12]),  // not indexed: last
    (SampleSort(.clusterScore, ascending: false), [5, 1, 2, 3, 9, 6, 7, 4, 8, 11, 12]),
] as [(SampleSort, [Int64])])
func sortOrdersRowsAndKeepsUnindexedLast(sort: SampleSort, expected: [Int64]) async throws {
    let (database, _, _) = try await makeSearch()
    let ids = try await browseIDs(database, SampleFilter(), sort: sort)
    #expect(ids == expected)
}

@Test func pagesAreDisjointAndCoverTheResult() async throws {
    let (database, _, _) = try await makeSearch()
    let pages = try await database.writer.read { db in
        try (0..<4).map { try SampleQuery.browse(db, filter: SampleFilter(), sort: SampleSort(.duration), offset: $0 * 3, limit: 3) }
    }
    #expect(pages.allSatisfy { $0.total == 11 })
    let all = pages.flatMap(\.rows).map(\.id)
    let full = try await browseIDs(database, SampleFilter(), sort: SampleSort(.duration))
    #expect(all == full)
    #expect(Set(all).count == all.count)
}

@Test func rowsCarryTagsDimsAndCluster() async throws {
    let (database, _, _) = try await makeSearch()
    let rows = try await database.writer.read { try SampleQuery.rows($0, ids: [2, 11, 999]) }
    #expect(rows.map(\.id) == [2, 11])  // order kept, unknown id skipped
    #expect(rows[0].tags == ["drum", "kick", "soft"])
    #expect(rows[0].clusterID == 0 && rows[0].dims?.count == 6)
    #expect(rows[1].tags.isEmpty && rows[1].dims == nil)
}

@Test(arguments: [5, 100])
func pageQueryUsesAConstantNumberOfStatements(limit: Int) async throws {
    let many = (1...300).map { i in
        Spec(id: Int64(i), filename: "s\(i).wav", relPath: "d/s\(i).wav", duration: 1, tags: ["a", "b\(i % 7)", "c"], cluster: i % 8, score: 0.5)
    }
    let (database, _, _) = try await makeSearch(many)
    let statements = try await database.writer.read { db -> [String] in
        var seen: [String] = []
        db.trace { seen.append($0.description) }
        var f = SampleFilter()
        f.tags = ["a", "c"]
        let page = try SampleQuery.browse(db, filter: f, sort: SampleSort(.filename), limit: limit)
        #expect(page.rows.count == limit)
        #expect(page.rows.allSatisfy { $0.tags.count == 3 })
        return seen
    }
    #expect(statements.count == 2, "\(statements.count) statements for limit \(limit)")  // rows (with tags) + total
}

@Test func tagCountsAreOrderedAndFollowTheFilter() async throws {
    let (database, _, service) = try await makeSearch()
    let all = try await service.tagCounts()
    #expect(all.first == TagCount(name: "drum", count: 4))
    #expect(all.contains(TagCount(name: "kick", count: 3)))  // 1, 2 and the pending one; not the missing sample
    #expect(zip(all, all.dropFirst()).allSatisfy { $0.count > $1.count || ($0.count == $1.count && $0.name < $1.name) })

    var f = SampleFilter()
    f.tags = ["kick"]
    let within = try await service.tagCounts(filter: f)
    #expect(Set(within.map(\.name)) == ["kick", "drum", "hard", "soft"])
    #expect(within.first == TagCount(name: "kick", count: 3))
    _ = database
}

@Test func textSearchFindsTheClosestSamplesBestFirst() async throws {
    let (_, _, service) = try await makeSearch()
    let results = try await service.searchText("axis 5", k: 3)
    #expect(results.first?.id == 5)
    #expect(abs((results.first?.score ?? 0) - 1) < 1e-5)
    #expect(results.count == 3)
    #expect(zip(results, results.dropFirst()).allSatisfy { $0.score >= $1.score })
    #expect(results.first?.row.filename == "bass_sub.wav")
}

@Test func textSearchRespectsFiltersAndNeverReturnsMissingOrUnindexedSamples() async throws {
    let (_, _, service) = try await makeSearch()
    var f = SampleFilter()
    f.tags = ["drum"]
    let results = try await service.searchText("axis 5", k: 50, filter: f)
    #expect(Set(results.map(\.id)) == [1, 2, 3, 4])
    let everything = try await service.searchText("axis 5", k: 50)
    #expect(!everything.map(\.id).contains(10))  // missing
    #expect(!everything.map(\.id).contains(11) && !everything.map(\.id).contains(12))  // not indexed
    #expect(everything.count == 9)
}

@Test func similarExcludesTheQuerySampleAndRespectsFilters() async throws {
    var near = specs
    near[1].vector = unit(1, 2, mix: 0.9)  // sample 2 is close to sample 1
    let (_, _, service) = try await makeSearch(near)
    let results = try await service.similar(to: 1, k: 3)
    #expect(!results.map(\.id).contains(1))
    #expect(results.first?.id == 2)

    var f = SampleFilter()
    f.tags = ["snare"]
    #expect(try await service.similar(to: 1, k: 5, filter: f).map(\.id) == [3])
}

@Test func searchErrors() async throws {
    let (_, _, service) = try await makeSearch()
    await #expect(throws: SearchError.emptyQuery) { try await service.searchText("   ") }
    await #expect(throws: SearchError.notIndexed(11)) { try await service.similar(to: 11) }
    await #expect(throws: SearchError.notIndexed(999)) { try await service.similar(to: 999) }
}

/// S2 query side: `SONDR_BENCH=1 SONDR_BENCH_DB=<library.sqlite> swift test -c release -Xswiftc -enable-testing --filter browseBenchmark`
/// (make the library with `sondr-testlib <n> <folder> --db <file> --fake`).
@Test(.enabled(if: ProcessInfo.processInfo.environment["SONDR_BENCH"] != nil && ProcessInfo.processInfo.environment["SONDR_BENCH_DB"] != nil, "set SONDR_BENCH=1 and SONDR_BENCH_DB"))
func browseBenchmark() async throws {
    let database = try LibraryDatabase(url: URL(fileURLWithPath: ProcessInfo.processInfo.environment["SONDR_BENCH_DB"]!))
    let clock = ContinuousClock()
    func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) * 1e-15 }
    func median(_ block: () async throws -> Void) async throws -> Double {
        try await block()  // warm up
        var times: [Double] = []
        for _ in 0..<5 { times.append(ms(try await clock.measure { try await block() })) }
        return times.sorted()[2]
    }
    let total = try await database.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM samples")! }
    print("browse benchmark over \(total) samples (page of 200, includes total count):")

    func page(_ label: String, _ filter: SampleFilter, _ sort: SampleSort) async throws {
        let t = try await median { _ = try await database.writer.read { try SampleQuery.browse($0, filter: filter, sort: sort, limit: 200) } }
        print(String(format: "  %-34@ %8.1f ms", label as NSString, t))
    }
    var tag = SampleFilter(); tag.tags = ["drum"]
    var tags2 = SampleFilter(); tags2.tags = ["drum", "hard"]
    var kw = SampleFilter(); kw.keyword = "kick"
    var kw2 = SampleFilter(); kw2.keyword = "kick hard"
    var unsorted = SampleFilter(); unsorted.cluster = .unsorted
    var combined = SampleFilter(); combined.keyword = "snare"; combined.tags = ["drum"]; combined.minDuration = 0.01
    try await page("all, by name", SampleFilter(), SampleSort(.filename))
    try await page("all, by name desc", SampleFilter(), SampleSort(.filename, ascending: false))
    try await page("all, by length", SampleFilter(), SampleSort(.duration))
    try await page("all, by date added", SampleFilter(), SampleSort(.added))
    try await page("all, by brightness", SampleFilter(), SampleSort(.brightness))
    try await page("tag drum, by name", tag, SampleSort(.filename))
    try await page("tags drum+hard, by name", tags2, SampleSort(.filename))
    try await page("keyword kick, by name", kw, SampleSort(.filename))
    try await page("keyword 'kick hard', by name", kw2, SampleSort(.filename))
    try await page("unsorted cluster, by name", unsorted, SampleSort(.filename))
    try await page("keyword+tag+duration, by name", combined, SampleSort(.filename))
    let brushed: SampleFilter = { var f = SampleFilter(); f.dimRanges = [.brightness: 0.3...0.6, .tonality: 0.2...0.9]; return f }()
    try await page("two brushed dims, by name", brushed, SampleSort(.filename))
    let wholeSample = try await median { _ = try await database.writer.read { try SampleQuery.dimSample($0, filter: SampleFilter(), limit: 2000) } }
    let brushedSample = try await median { _ = try await database.writer.read { try SampleQuery.dimSample($0, filter: brushed, limit: 2000) } }
    print(String(format: "  %-34@ %8.1f ms", "parallel coords sample, all" as NSString, wholeSample))
    print(String(format: "  %-34@ %8.1f ms", "parallel coords sample, brushed" as NSString, brushedSample))
    let counts = try await median { _ = try await database.writer.read { try SampleQuery.tagCounts($0) } }
    print(String(format: "  %-34@ %8.1f ms", "tag counts (all)" as NSString, counts))

    let index = VectorIndex()
    let load = try await clock.measure { try await index.load(from: database) }
    let service = SearchService(database: database, index: index, embedder: AxisEmbedder())
    let text = try await median { _ = try await service.searchText("axis 5", k: 100) }
    let filtered = try await median { _ = try await service.searchText("axis 5", k: 100, filter: tag) }
    print(String(format: "  %-34@ %8.1f ms", "text search top 100 (no embed)" as NSString, text))
    print(String(format: "  %-34@ %8.1f ms", "text search, tag filter" as NSString, filtered))
    print("  index load \(load)")
}
