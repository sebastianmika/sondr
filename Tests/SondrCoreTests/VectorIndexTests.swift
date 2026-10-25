import Foundation
import GRDB
import Testing

@testable import SondrCore

private let dimension = VectorIndex.dimension

private struct Generator {
    var state: UInt64
    mutating func unitVector() -> [Float] {
        var v = (0..<dimension).map { _ -> Float in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) % 20001 - 10000) / 10000
        }
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        v = v.map { $0 / norm }
        return v
    }
}

private func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }

private func bruteForce(
    _ vectors: [Int64: [Float]], query: [Float], k: Int, allowed: Set<Int64>? = nil, excluding: Int64? = nil
) -> [Int64] {
    vectors.filter { $0.key != excluding && (allowed?.contains($0.key) ?? true) }
        .map { ($0.key, dot($0.value, query)) }
        .sorted { $0.1 > $1.1 }
        .prefix(k).map(\.0)
}

private func filled(_ count: Int, seed: UInt64 = 1) async throws -> (VectorIndex, [Int64: [Float]]) {
    var generator = Generator(state: seed)
    let index = VectorIndex(capacity: 16)
    var vectors: [Int64: [Float]] = [:]
    for i in 0..<count {
        let v = generator.unitVector()
        vectors[Int64(i) + 100] = v
        try await index.append(id: Int64(i) + 100, vector: v)
    }
    return (index, vectors)
}

@Test func topKMatchesBruteForceOnRandomData() async throws {
    let (index, vectors) = try await filled(3000)
    var generator = Generator(state: 99)
    for _ in 0..<10 {
        let query = generator.unitVector()
        let hits = try await index.topK(query, k: 25)
        let expected = bruteForce(vectors, query: query, k: 25)
        #expect(hits.map(\.id) == expected)
        for hit in hits { #expect(abs(hit.score - dot(vectors[hit.id]!, query)) < 1e-5) }
        #expect(zip(hits, hits.dropFirst()).allSatisfy { $0.score >= $1.score })
    }
}

@Test func queryScaleDoesNotMatter() async throws {
    let (index, _) = try await filled(200)
    var generator = Generator(state: 5)
    let query = generator.unitVector()
    let a = try await index.topK(query, k: 5)
    let b = try await index.topK(query.map { $0 * 7 }, k: 5)
    #expect(a.map(\.id) == b.map(\.id))
    #expect(zip(a, b).allSatisfy { abs($0.score - $1.score) < 1e-5 })
}

@Test func allowedSetAndExclusionAreApplied() async throws {
    let (index, vectors) = try await filled(1000)
    var generator = Generator(state: 7)
    let query = generator.unitVector()
    let allowed = Set(vectors.keys.filter { $0 % 7 == 0 })
    let hits = try await index.topK(query, k: 10, allowed: allowed)
    #expect(hits.map(\.id) == bruteForce(vectors, query: query, k: 10, allowed: allowed))

    let own = vectors[150]!
    let similar = try await index.topK(own, k: 10, excluding: 150)
    #expect(!similar.contains { $0.id == 150 })
    #expect(similar.map(\.id) == bruteForce(vectors, query: own, k: 10, excluding: 150))
    #expect(try await index.topK(own, k: 1).first?.id == 150)  // without exclusion it finds itself
}

@Test func smallResultSetsAreHandled() async throws {
    let (index, vectors) = try await filled(5)
    let query = vectors[100]!
    #expect(try await index.topK(query, k: 50).count == 5)  // fewer vectors than k
    #expect(try await index.topK(query, k: 0).isEmpty)
    #expect(try await index.topK(query, k: 5, allowed: []).isEmpty)
    #expect(try await VectorIndex().topK(query, k: 5).isEmpty)  // empty index
    #expect(try await index.topK([Float](repeating: 0, count: dimension), k: 5).isEmpty)  // zero query
}

@Test func removeKeepsTheRemainingRowsIntact() async throws {
    let (index, vectors) = try await filled(300)
    var remaining = vectors
    for id in stride(from: Int64(100), to: 400, by: 3) {
        #expect(await index.remove(id: id))
        remaining[id] = nil
    }
    #expect(await index.remove(id: 100) == false)
    #expect(await index.count == remaining.count)
    for (id, vector) in remaining.prefix(20) { #expect(await index.vector(for: id) == vector) }

    var generator = Generator(state: 3)
    let query = generator.unitVector()
    #expect(try await index.topK(query, k: 15).map(\.id) == bruteForce(remaining, query: query, k: 15))

    // removing everything, and the last row, works
    for id in remaining.keys { await index.remove(id: id) }
    #expect(await index.count == 0)
}

@Test func appendReplacesExistingIdsAndGrowsPastCapacity() async throws {
    let (index, vectors) = try await filled(100)  // capacity started at 16
    #expect(await index.count == 100)
    var generator = Generator(state: 42)
    let replacement = generator.unitVector()
    try await index.append(id: 100, vector: replacement)
    #expect(await index.count == 100)
    #expect(await index.vector(for: 100) == replacement)
    #expect(await index.vector(for: 101) == vectors[101])
}

@Test func wrongDimensionIsRejected() async throws {
    let index = VectorIndex()
    await #expect(throws: VectorIndexError.wrongDimension(3)) { try await index.append(id: 1, vector: [1, 2, 3]) }
    await #expect(throws: VectorIndexError.wrongDimension(3)) { try await index.topK([1, 2, 3], k: 1) }
}

@Test func loadReadsFinishedPresentSamplesFromTheDatabase() async throws {
    let database = try LibraryDatabase(inMemory: ())
    var generator = Generator(state: 11)
    let vectors = (0..<4).map { _ in generator.unitVector() }
    let stored = Dictionary(uniqueKeysWithValues: vectors.enumerated().map { (Int64($0) + 1, $1) })
    try await database.writer.write { db in
        for (i, state) in ["done", "done", "pending", "done"].enumerated() {
            try db.execute(
                sql: """
                    INSERT INTO samples (content_hash, canonical_path, filename, rel_path, duration,
                        sample_rate, channels, format, file_size, file_mtime, scanned_at, embed_state, missing)
                    VALUES (?, '/a.wav', 'a.wav', 'a.wav', 1, 48000, 1, 'wav', 1, 0, 0, ?, ?)
                    """, arguments: ["h\(i)", state, i == 3 ? 1 : 0])
            let id = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO embeddings (sample_id, vector) VALUES (?, ?)", arguments: [id, EmbeddingCodec.encode(vectors[i])])
        }
    }
    let index = VectorIndex()
    try await index.load(from: database)
    #expect(await index.count == 2)  // not pending, not missing
    for id in [Int64(1), 2] {
        let loaded = try #require(await index.vector(for: id))
        #expect(dot(loaded, stored[id]!) > 0.9999)
    }
    #expect(await index.contains(3) == false)

    try await index.load(from: database)  // loading again replaces, not appends
    #expect(await index.count == 2)
}

/// S4: `SONDR_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter vectorIndexBenchmark`
@Test(.enabled(if: ProcessInfo.processInfo.environment["SONDR_BENCH"] != nil, "set SONDR_BENCH=1"))
func vectorIndexBenchmark() async throws {
    let n = 250_000
    var generator = Generator(state: 1)
    let index = VectorIndex(capacity: n)
    let clock = ContinuousClock()
    let build = try await clock.measure {
        for i in 0..<n { try await index.append(id: Int64(i), vector: generator.unitVector()) }
    }
    let query = generator.unitVector()
    _ = try await index.topK(query, k: 50)
    var times: [Double] = []
    for _ in 0..<20 {
        let d = try await clock.measure { _ = try await index.topK(query, k: 50) }
        times.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) * 1e-15)
    }
    let allowed = Set((0..<n).filter { $0 % 10 == 0 }.map(Int64.init))
    let filtered = try await clock.measure { _ = try await index.topK(query, k: 50, allowed: allowed) }
    print("S4: 250k x 512 top-50: median \(times.sorted()[10]) ms, max \(times.max()!) ms; filtered 10%: \(filtered); fill \(build)")
}

/// Launch cost: `SONDR_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter vectorIndexLoadBenchmark`
@Test(.enabled(if: ProcessInfo.processInfo.environment["SONDR_BENCH"] != nil, "set SONDR_BENCH=1"))
func vectorIndexLoadBenchmark() async throws {
    let n = 250_000
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/library.sqlite")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let database = try LibraryDatabase(url: url)
    var generator = Generator(state: 1)
    let blobs = (0..<64).map { _ in EmbeddingCodec.encode(generator.unitVector()) }
    try await database.writer.write { db in
        for i in 0..<n {
            try db.execute(
                sql: """
                    INSERT INTO samples (content_hash, canonical_path, filename, rel_path, duration,
                        sample_rate, channels, format, file_size, file_mtime, scanned_at, embed_state)
                    VALUES (?, '/a.wav', 'a.wav', 'a.wav', 1, 48000, 1, 'wav', 1, 0, 0, 'done')
                    """, arguments: ["h\(i)"])
            try db.execute(
                sql: "INSERT INTO embeddings (sample_id, vector) VALUES (?, ?)",
                arguments: [db.lastInsertedRowID, blobs[i % 64]])
        }
    }
    let index = VectorIndex()
    let elapsed = try await ContinuousClock().measure { try await index.load(from: database) }
    print("S4 load: \(await index.count) vectors from SQLite in \(elapsed)")
}
