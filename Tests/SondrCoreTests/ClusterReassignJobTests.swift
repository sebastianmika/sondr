import Foundation
import GRDB
import Testing

@testable import SondrCore

private let dimension = EmbeddingService.embeddingSize

private func axis(_ k: Int) -> [Float] {
    var v = [Float](repeating: 0, count: dimension)
    v[k] = 1
    return v
}

/// Text vectors point along the axis of the keyword (`alpha` is axis 0, ...); records what it embedded.
/// While `gated`, `embed(text:)` waits until `open()` is called.
private final class AxisEmbedder: Embedder, @unchecked Sendable {
    static let words = ["alpha", "beta", "gamma", "delta"]
    private let lock = NSLock()
    private var _prompts: [String] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen: Bool

    init(gated: Bool = false) { isOpen = !gated }

    var prompts: [String] { lock.withLock { _prompts } }

    func open() {
        let toResume = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiting = [] }
            return waiting
        }
        toResume.forEach { $0.resume() }
    }

    func modelVersion() async throws -> String { "axis" }
    func embed(audio clips: [[Float]]) async throws -> [[Float]] { clips.map { _ in axis(100) } }

    func embed(text: String) async throws -> [Float] {
        lock.withLock { _prompts.append(text) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiting.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        return axis(Self.words.firstIndex(of: text) ?? 200)
    }
}

private func def(_ id: Int, _ word: String, name: String? = nil, color: String = "#102030") -> ClusterDefinition {
    ClusterDefinition(id: id, name: name ?? word, color: color, keywords: word)
}

/// Clusters alpha, beta, gamma (ids 0...2) with centres, and `perAxis` finished samples along each of
/// the axes 0...3 (the last one matches no cluster yet), all assigned.
private func makeLibrary(perAxis: Int = 4) async throws -> (LibraryDatabase, AxisEmbedder) {
    let database = try LibraryDatabase(inMemory: ())
    let embedder = AxisEmbedder()
    try await database.writer.write { db in
        for (id, word) in AxisEmbedder.words.prefix(3).enumerated() {
            try db.execute(
                sql: "INSERT INTO clusters (id, name, color, keywords) VALUES (?, ?, '#102030', ?)", arguments: [id, word, word])
        }
        for k in 0..<4 {
            for i in 0..<perAxis {
                try db.execute(
                    sql: """
                        INSERT INTO samples (content_hash, canonical_path, filename, rel_path, duration,
                            sample_rate, channels, format, file_size, file_mtime, scanned_at, embed_state)
                        VALUES (?, '/a.wav', 'a.wav', 'a.wav', 1, 48000, 1, 'wav', 1, 0, 0, 'done')
                        """, arguments: ["h\(k)-\(i)"])
                try db.execute(
                    sql: "INSERT INTO embeddings (sample_id, vector) VALUES (?, ?)",
                    arguments: [db.lastInsertedRowID, EmbeddingCodec.encode(axis(k))])
            }
        }
    }
    let centres = ClusterAssigner.Centres(try await ClusterCentres.ensure(database: database, embedder: embedder))
    try await ClusterAssigner.assignMissing(database: database, centres: centres)
    return (database, embedder)
}

/// Cluster of the samples along `axis` (all of them agree in these tests), nil if unassigned.
private func cluster(_ database: LibraryDatabase, axis k: Int, perAxis: Int = 4) async throws -> Int? {
    let all = try await database.writer.read {
        try Int?.fetchAll(
            $0, sql: "SELECT cluster_id FROM samples WHERE content_hash LIKE ? ORDER BY id", arguments: ["h\(k)-%"])
    }
    #expect(all.count == perAxis && Set(all).count == 1)
    return all[0]
}

@discardableResult
private func commit(_ database: LibraryDatabase, _ edited: [ClusterDefinition]) async throws -> Bool {
    try await database.writer.write { try ClusterReassignJob.commit($0, edited: edited) }
}

private func scalar(_ database: LibraryDatabase, _ sql: String) async throws -> Int {
    try await database.writer.read { try Int.fetchOne($0, sql: sql)! }
}

private func clusters(_ database: LibraryDatabase) async throws -> [ClusterDefinition] {
    try await database.writer.read { try ClusterCentres.definitions($0) }
}

@Test func editingADescriptionRecomputesOnlyThatCentre() async throws {
    let (database, embedder) = try await makeLibrary()
    #expect(embedder.prompts == ["alpha", "beta", "gamma"])
    #expect(try await cluster(database, axis: 3) != nil)

    var edited = try await clusters(database)
    edited[1].keywords = "delta"
    let changed = try await commit(database, edited)
    #expect(changed)
    #expect(try await scalar(database, "SELECT count(*) FROM samples WHERE cluster_id IS NOT NULL") == 0)

    let summary = try await ClusterReassignJob.start(database: database, embedder: embedder, chunkSize: 3).result()
    #expect(summary == ReclusterSummary(samples: 16, cancelled: false))
    #expect(embedder.prompts == ["alpha", "beta", "gamma", "delta"])  // only the edited centre
    #expect(try await cluster(database, axis: 3) == 1)
    #expect(try await cluster(database, axis: 0) == 0)
    #expect(try await scalar(database, "SELECT count(*) FROM meta WHERE key = 'recluster_pending'") == 0)
}

@Test func deletingAClusterReassignsItsSamples() async throws {
    let (database, embedder) = try await makeLibrary()
    #expect(try await cluster(database, axis: 1) == 1)

    let edited = try await clusters(database).filter { $0.id != 1 }
    try await commit(database, edited)
    _ = try await ClusterReassignJob.start(database: database, embedder: embedder).result()

    #expect(try await clusters(database).map(\.id) == [0, 2])
    #expect(try await scalar(database, "SELECT count(*) FROM cluster_centres WHERE cluster_id = 1") == 0)
    #expect(try await scalar(database, "SELECT count(*) FROM samples WHERE cluster_id IS NULL") == 0)
    #expect(try await scalar(database, "SELECT count(*) FROM samples WHERE cluster_id = 1") == 0)
    #expect(embedder.prompts.count == 3)  // no centre was recomputed
}

@Test func addingAClusterPicksUpSamplesAndGetsTheNextFreeID() async throws {
    let (database, embedder) = try await makeLibrary()
    var edited = try await clusters(database)
    edited.append(ClusterDefinition(id: -1, name: "new", color: "not a colour", keywords: "delta"))
    try await commit(database, edited)
    _ = try await ClusterReassignJob.start(database: database, embedder: embedder).result()

    let all = try await clusters(database)
    #expect(all.map(\.id) == [0, 1, 2, 3])
    #expect(ClusterPalette.RGB(hex: all[3].color) != nil)
    #expect(all[3].color != "not a colour")
    #expect(try await cluster(database, axis: 3) == 3)
    #expect(try await scalar(database, "SELECT count(*) FROM samples WHERE cluster_id = 3 AND cluster_score > 0.99") == 4)
}

@Test func renamingOrRecolouringChangesNothingElse() async throws {
    let (database, embedder) = try await makeLibrary()
    var edited = try await clusters(database)
    edited[0].name = "first"
    edited[0].color = "#ABCDEF"
    let changed = try await commit(database, edited)
    #expect(!changed)
    #expect(try await clusters(database)[0] == ClusterDefinition(id: 0, name: "first", color: "#ABCDEF", keywords: "alpha"))
    #expect(try await scalar(database, "SELECT count(*) FROM samples WHERE cluster_id IS NULL") == 0)
    let summary = try await ClusterReassignJob.start(database: database, embedder: embedder).result()
    #expect(summary == ReclusterSummary(samples: 0, cancelled: false))
}

@Test func anInterruptedJobResumesAtTheNextStart() async throws {
    let (database, embedder) = try await makeLibrary(perAxis: 10)
    var edited = try await clusters(database)
    edited.append(def(-1, "delta"))
    try await commit(database, edited)

    // The app is killed here: committed, nothing assigned.
    #expect(try await database.writer.read { try ClusterReassignJob.hasPending($0) })
    #expect(try await scalar(database, "SELECT count(*) FROM samples WHERE cluster_id IS NULL") == 40)

    let first = try ClusterReassignJob.start(database: database, embedder: embedder, chunkSize: 1)
    first.cancel()
    let cancelled = try await first.result()
    if cancelled.cancelled {
        #expect(try await database.writer.read { try ClusterReassignJob.hasPending($0) })
    }
    let second = try await ClusterReassignJob.start(database: database, embedder: embedder, chunkSize: 7).result()
    #expect(!second.cancelled)
    #expect(try await scalar(database, "SELECT count(*) FROM samples WHERE cluster_id IS NULL") == 0)
    #expect(try await cluster(database, axis: 3, perAxis: 10) == 3)
    #expect(try await database.writer.read { try !ClusterReassignJob.hasPending($0) })
}

@Test func zeroClustersEmptyFieldsAndAPendingChangeAreRefused() async throws {
    let (database, _) = try await makeLibrary()
    let current = try await clusters(database)
    await #expect(throws: ClusterError.self) { try await commit(database, []) }
    await #expect(throws: ClusterError.self) { try await commit(database, [def(0, "alpha", name: "  ")]) }
    await #expect(throws: ClusterError.self) { try await commit(database, [def(0, " ")]) }
    #expect(try await clusters(database) == current)

    try await commit(database, current + [def(-1, "delta")])
    await #expect(throws: ClusterError.pending) { try await commit(database, current) }
}

@Test func reclusterAndScanIndexRetagExcludeEachOtherBothWays() async throws {
    let (database, _) = try await makeLibrary()
    for kind in [JobKind.scan, .index, .retag] {
        try database.jobs.begin(kind)
        #expect(throws: JobError.alreadyRunning(kind)) {
            try ClusterReassignJob.start(database: database, embedder: AxisEmbedder())
        }
        #expect(!database.jobs.isRunning(.recluster))
        database.jobs.end(kind)
    }

    var edited = try await clusters(database)
    edited.append(def(-1, "delta"))
    try await commit(database, edited)
    let gated = AxisEmbedder(gated: true)
    let run = try ClusterReassignJob.start(database: database, embedder: gated)
    for kind in JobKind.allCases { #expect(throws: JobError.alreadyRunning(kind)) { try database.jobs.begin(kind) } }
    #expect(throws: JobError.self) { try TagRetagJob.start(database: database, tagger: Tagger.bundled()) }
    #expect(throws: JobError.self) { try IndexJob.start(database: database, embedder: gated) }
    gated.open()
    _ = try await run.result()
    for kind in JobKind.allCases { #expect(!database.jobs.isRunning(kind)) }
}
