import Foundation
import GRDB
import Testing

@testable import SondrCore

/// Deterministic fake model: the vector depends on the clip's content.
private final class StubEmbedder: Embedder, @unchecked Sendable {
    private let lock = NSLock()
    private var _clipsEmbedded = 0
    private var _calls = 0
    let version: String
    let failFromCall: Int?
    let poison: (@Sendable ([Float]) -> Bool)?
    let onCall: (@Sendable (Int) async -> Void)?

    init(
        version: String = "stub-1", failFromCall: Int? = nil, poison: (@Sendable ([Float]) -> Bool)? = nil,
        onCall: (@Sendable (Int) async -> Void)? = nil
    ) {
        self.version = version
        self.failFromCall = failFromCall
        self.poison = poison
        self.onCall = onCall
    }

    var clipsEmbedded: Int { lock.withLock { _clipsEmbedded } }

    func modelVersion() async throws -> String { version }

    func embed(audio clips: [[Float]]) async throws -> [[Float]] {
        let call = lock.withLock { () -> Int in
            _calls += 1
            return _calls
        }
        await onCall?(call)
        if let failFromCall, call >= failFromCall { throw EmbeddingError.predictionFailed("stub failure") }
        if let poison, clips.contains(where: poison) { throw EmbeddingError.predictionFailed("poison clip") }
        lock.withLock { _clipsEmbedded += clips.count }
        return clips.map(Self.vector)
    }

    func embed(text: String) async throws -> [Float] { Self.unit(seed: UInt64(truncatingIfNeeded: text.hashValue)) }

    static func vector(_ clip: [Float]) -> [Float] {
        let seed = clip.prefix(2000).enumerated().reduce(UInt64(7)) { ($0 &* 31) &+ UInt64($1.element.bitPattern) &+ UInt64($1.offset) }
        return unit(seed: seed)
    }

    static func unit(seed: UInt64) -> [Float] {
        var state = seed | 1
        var v = (0..<EmbeddingService.embeddingSize).map { _ -> Float in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) % 2000 - 1000) / 1000
        }
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        v = v.map { $0 / norm }
        return v
    }
}

private struct Library {
    let root: URL
    let database: LibraryDatabase

    static func make(count: Int) async throws -> Library {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("sondr-idx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        let root = LibraryScanner.realURL(made)
        try TestLibraryGenerator.generate(count: count, into: root)
        let database = try LibraryDatabase(inMemory: ())
        let summary = try await LibraryScanner(database: database).scan(root: root)
        #expect(summary.new == count)
        return Library(root: root, database: database)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func scalar(_ sql: String) async throws -> Int {
        try await database.writer.read { try Int.fetchOne($0, sql: sql) ?? -1 }
    }

    /// Every `done` sample has a vector, dims and a thumbnail; every vector belongs to a `done` sample.
    func expectConsistent() async throws {
        #expect(try await scalar("SELECT count(*) FROM samples WHERE embed_state = 'done' AND id NOT IN (SELECT sample_id FROM embeddings)") == 0)
        #expect(try await scalar("SELECT count(*) FROM embeddings WHERE sample_id NOT IN (SELECT id FROM samples WHERE embed_state = 'done')") == 0)
        #expect(try await scalar("SELECT count(*) FROM samples WHERE embed_state = 'done' AND (dim_brightness IS NULL OR dim_duration IS NULL OR wave_thumb IS NULL OR spectrogram_thumb IS NULL)") == 0)
        #expect(try await scalar("SELECT count(*) FROM samples WHERE embed_state != 'done' AND (dim_brightness IS NOT NULL OR wave_thumb IS NOT NULL)") == 0)
    }
}

@Test func indexJobEmbedsEveryPendingSample() async throws {
    let library = try await Library.make(count: 40)
    defer { library.remove() }
    let embedder = StubEmbedder()

    let run = try IndexJob.start(database: library.database, embedder: embedder, chunkSize: 8)
    var events: [IndexProgress] = []
    for await progress in run.progress { events.append(progress) }
    let summary = try await run.result()

    #expect(summary == IndexSummary(done: 40, failed: 0, cancelled: false))
    #expect(events.first?.total == 40)
    #expect(events.last == IndexProgress(total: 40, done: 40, failed: 0))
    #expect(try await library.scalar("SELECT count(*) FROM embeddings") == 40)
    #expect(try await library.scalar("SELECT count(*) FROM samples WHERE embed_state = 'done'") == 40)
    #expect(try await library.scalar("SELECT length(vector) FROM embeddings LIMIT 1") == 1024)
    #expect(try await library.scalar("SELECT count(*) FROM dim_stats") == 6)
    let version = try await library.database.writer.read { try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key = 'model_version'") }
    #expect(version == "stub-1")
    try await library.expectConsistent()
}

@Test func storedVectorsMatchWhatTheModelReturned() async throws {
    let library = try await Library.make(count: 3)
    defer { library.remove() }
    let run = try IndexJob.start(database: library.database, embedder: StubEmbedder())
    _ = try await run.result()

    let (path, blob) = try await library.database.writer.read { db -> (String, Data) in
        let row = try Row.fetchOne(db, sql: "SELECT canonical_path, vector FROM samples JOIN embeddings ON sample_id = samples.id LIMIT 1")!
        return (row["canonical_path"], row["vector"])
    }
    let expected = StubEmbedder.vector(try AudioLoader.load(url: URL(fileURLWithPath: path)))
    let stored = try #require(EmbeddingCodec.decode(blob))
    let dot = zip(stored, expected).reduce(0) { $0 + $1.0 * $1.1 }
    #expect(dot > 0.9999)
}

@Test func unreadableFileEndsFailedWithAReasonAndNoVector() async throws {
    let library = try await Library.make(count: 12)
    defer { library.remove() }
    let (victimID, victimPath) = try await library.database.writer.read { db -> (Int64, String) in
        let row = try Row.fetchOne(db, sql: "SELECT id, canonical_path FROM samples ORDER BY id LIMIT 1 OFFSET 3")!
        return (row["id"], row["canonical_path"])
    }
    try Data("garbage".utf8).write(to: URL(fileURLWithPath: victimPath))

    let summary = try await IndexJob.start(database: library.database, embedder: StubEmbedder(), chunkSize: 5).result()

    #expect(summary.done == 11)
    #expect(summary.failed == 1)
    let (state, reason) = try await library.database.writer.read { db -> (String, String?) in
        let row = try Row.fetchOne(db, sql: "SELECT embed_state, embed_error FROM samples WHERE id = ?", arguments: [victimID])!
        return (row["embed_state"], row["embed_error"])
    }
    #expect(state == "failed")
    #expect(reason?.isEmpty == false)
    #expect(try await library.scalar("SELECT count(*) FROM embeddings WHERE sample_id = \(victimID)") == 0)
    try await library.expectConsistent()
}

@Test func jobKilledByAModelErrorResumesWithoutDuplicatesOrHalfWrittenRows() async throws {
    let library = try await Library.make(count: 40)
    defer { library.remove() }

    let broken = StubEmbedder(failFromCall: 3)
    await #expect(throws: EmbeddingError.self) {
        try await IndexJob.start(database: library.database, embedder: broken, chunkSize: 8).result()
    }
    #expect(try await library.scalar("SELECT count(*) FROM samples WHERE embed_state = 'done'") == 16)
    #expect(try await library.scalar("SELECT count(*) FROM samples WHERE embed_state = 'pending'") == 24)
    try await library.expectConsistent()

    let healthy = StubEmbedder()
    let summary = try await IndexJob.start(database: library.database, embedder: healthy, chunkSize: 8).result()
    #expect(summary.done == 24)
    #expect(healthy.clipsEmbedded == 24)  // finished work is not redone
    #expect(try await library.scalar("SELECT count(*) FROM embeddings") == 40)
    #expect(try await library.scalar("SELECT count(DISTINCT sample_id) FROM embeddings") == 40)
    try await library.expectConsistent()
}

@Test func oneClipTheModelRejectsEndsFailedAndTheRestAreIndexed() async throws {
    let library = try await Library.make(count: 12)
    defer { library.remove() }
    let victimPath = try await library.database.writer.read {
        try String.fetchOne($0, sql: "SELECT canonical_path FROM samples ORDER BY id LIMIT 1 OFFSET 3")!
    }
    let poisoned = try AudioLoader.load(url: URL(fileURLWithPath: victimPath))

    let summary = try await IndexJob.start(
        database: library.database, embedder: StubEmbedder(poison: { $0 == poisoned }), chunkSize: 5
    ).result()

    #expect(summary.done == 11)
    #expect(summary.failed == 1)
    #expect(try await library.scalar("SELECT count(*) FROM samples WHERE embed_state = 'failed' AND embed_error LIKE 'Embedding failed%'") == 1)
    #expect(try await library.scalar("SELECT count(*) FROM samples WHERE embed_state = 'pending'") == 0)
    try await library.expectConsistent()
}

@Test func cancelledJobStopsCleanlyAndCanBeResumed() async throws {
    let library = try await Library.make(count: 40)
    defer { library.remove() }
    let box = RunBox()
    let embedder = StubEmbedder(onCall: { call in if call == 2 { box.run?.cancel() } })
    let run = try IndexJob.start(database: library.database, embedder: embedder, chunkSize: 8)
    box.run = run

    let summary = try await run.result()
    #expect(summary.cancelled)
    #expect(summary.done < 40)
    let doneAfterCancel = try await library.scalar("SELECT count(*) FROM samples WHERE embed_state = 'done'")
    #expect(doneAfterCancel == summary.done)
    #expect(try await library.scalar("SELECT count(*) FROM dim_stats") == 6)  // ranges cover what was indexed before the cancel
    try await library.expectConsistent()

    let rest = try await IndexJob.start(database: library.database, embedder: StubEmbedder(), chunkSize: 8).result()
    #expect(rest.done == 40 - doneAfterCancel)
    #expect(try await library.scalar("SELECT count(*) FROM embeddings") == 40)
}

private final class RunBox: @unchecked Sendable {
    var run: IndexRun?
}

@Test func secondIndexJobIsRejectedWhileOneRuns() async throws {
    let library = try await Library.make(count: 10)
    defer { library.remove() }
    let gate = AsyncGate()
    let slow = StubEmbedder(onCall: { _ in await gate.wait() })
    let first = try IndexJob.start(database: library.database, embedder: slow)

    #expect(throws: JobError.alreadyRunning(.index)) {
        try IndexJob.start(database: library.database, embedder: StubEmbedder())
    }
    gate.open()
    _ = try await first.result()

    let again = try IndexJob.start(database: library.database, embedder: StubEmbedder())
    _ = try await again.result()  // the lock was released
}

@Test func scanAndIndexJobsDoNotBlockEachOther() throws {
    let registry = JobRegistry()
    try registry.begin(.scan)
    try registry.begin(.index)
    #expect(throws: JobError.alreadyRunning(.scan)) { try registry.begin(.scan) }
    registry.end(.scan)
    try registry.begin(.scan)
}

/// One-shot barrier for tests.
private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        opened = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

@Test func changedModelVersionDiscardsOldEmbeddings() async throws {
    let library = try await Library.make(count: 10)
    defer { library.remove() }
    _ = try await IndexJob.start(database: library.database, embedder: StubEmbedder(version: "v1")).result()
    try await library.database.writer.write { try $0.execute(sql: "UPDATE samples SET cluster_id = NULL") }

    let again = StubEmbedder(version: "v2")
    let summary = try await IndexJob.start(database: library.database, embedder: again).result()

    #expect(summary.done == 10)
    #expect(again.clipsEmbedded == 10)
    #expect(try await library.scalar("SELECT count(*) FROM embeddings") == 10)
    let version = try await library.database.writer.read { try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key = 'model_version'") }
    #expect(version == "v2")
}

@Test func sameModelVersionKeepsFinishedWork() async throws {
    let library = try await Library.make(count: 10)
    defer { library.remove() }
    _ = try await IndexJob.start(database: library.database, embedder: StubEmbedder()).result()
    let again = StubEmbedder()
    let summary = try await IndexJob.start(database: library.database, embedder: again).result()
    #expect(summary.done == 0)
    #expect(again.clipsEmbedded == 0)
}

@Test func missingSamplesAreNotIndexedAndFailedOnesCanBeRetried() async throws {
    let library = try await Library.make(count: 6)
    defer { library.remove() }
    try await library.database.writer.write { db in
        try db.execute(sql: "UPDATE samples SET missing = 1 WHERE id = 1")
        try db.execute(sql: "UPDATE samples SET embed_state = 'failed', embed_error = 'old' WHERE id = 2")
    }
    let first = try await IndexJob.start(database: library.database, embedder: StubEmbedder()).result()
    #expect(first.done == 4)
    #expect(try await library.scalar("SELECT count(*) FROM samples WHERE embed_state = 'failed'") == 1)

    let retry = try await IndexJob.start(database: library.database, embedder: StubEmbedder(), retryFailed: true).result()
    #expect(retry.done == 1)
    #expect(try await library.scalar("SELECT embed_state = 'pending' FROM samples WHERE id = 1") == 1)
}

@Test func embeddingCodecRoundTripsWithinHalfPrecision() throws {
    let vector = StubEmbedder.unit(seed: 5)
    let decoded = try #require(EmbeddingCodec.decode(EmbeddingCodec.encode(vector)))
    #expect(decoded.count == 512)
    let dot = zip(vector, decoded).reduce(0) { $0 + $1.0 * $1.1 }
    #expect(dot > 0.99999)
    #expect(EmbeddingCodec.decode(Data([1, 2, 3])) == nil)
}

@Test func indexJobAssignsEveryFinishedSampleToAClusterInTheCatalog() async throws {
    let library = try await Library.make(count: 30)
    defer { library.remove() }
    _ = try await IndexJob.start(database: library.database, embedder: StubEmbedder(), chunkSize: 8).result()

    #expect(try await library.scalar("SELECT count(*) FROM samples WHERE embed_state = 'done' AND (cluster_id IS NULL OR cluster_score IS NULL)") == 0)
    #expect(try await library.scalar("SELECT count(*) FROM samples WHERE cluster_id NOT BETWEEN 0 AND 7") == 0)
    #expect(try await library.scalar("SELECT count(*) FROM samples WHERE cluster_id NOT IN (SELECT id FROM clusters)") == 0)
    #expect(try await library.scalar("SELECT count(*) FROM cluster_centres") == 8)
    #expect(try await library.scalar("SELECT count(*) FROM samples WHERE embed_state != 'done' AND cluster_id IS NOT NULL") == 0)
}

@Test func indexJobStoresASpectrogramOfTheRightSizeForEverySample() async throws {
    let library = try await Library.make(count: 12)
    defer { library.remove() }
    _ = try await IndexJob.start(database: library.database, embedder: StubEmbedder()).result()
    #expect(try await library.scalar("SELECT count(*) FROM samples WHERE length(spectrogram_thumb) = \(SpectrogramThumbnail.columns * SpectrogramThumbnail.bands)") == 12)
    try await library.expectConsistent()
}

@Test func samplesIndexedBeforeSpectrogramsExistGetThemWithoutBeingEmbeddedAgain() async throws {
    let library = try await Library.make(count: 20)
    defer { library.remove() }
    let embedder = StubEmbedder()
    _ = try await IndexJob.start(database: library.database, embedder: embedder).result()
    let embeddedBefore = embedder.clipsEmbedded
    try await library.database.writer.write {
        try $0.execute(sql: "UPDATE samples SET spectrogram_thumb = NULL WHERE id % 2 = 0")
    }
    let missing = try await library.scalar("SELECT count(*) FROM samples WHERE spectrogram_thumb IS NULL")
    #expect(missing == 10)

    let run = try IndexJob.start(database: library.database, embedder: embedder)
    var last = IndexProgress(total: 0, done: 0, failed: 0)
    for await progress in run.progress { last = progress }
    let summary = try await run.result()

    #expect(summary.done == 0)
    #expect(summary.backfilled == missing)
    #expect(last.total == missing && last.done == missing)
    #expect(embedder.clipsEmbedded == embeddedBefore)
    try await library.expectConsistent()
}

@Test func backfillSkipsMissingFilesAndLeavesThemForLater() async throws {
    let library = try await Library.make(count: 6)
    defer { library.remove() }
    let embedder = StubEmbedder()
    _ = try await IndexJob.start(database: library.database, embedder: embedder).result()
    try await library.database.writer.write {
        try $0.execute(sql: "UPDATE samples SET spectrogram_thumb = NULL")
        try $0.execute(sql: "UPDATE samples SET missing = 1 WHERE id <= 2")
    }
    let summary = try await IndexJob.start(database: library.database, embedder: embedder).result()
    #expect(summary.backfilled == 4)
    #expect(try await library.scalar("SELECT count(*) FROM samples WHERE spectrogram_thumb IS NULL") == 2)
}

@Test func corruptedDatabaseIsRepairedAndThenIndexedCompletely() async throws {
    let library = try await Library.make(count: 12)
    defer { library.remove() }
    _ = try await IndexJob.start(database: library.database, embedder: StubEmbedder()).result()
    try await library.database.writer.write { db in
        try db.execute(sql: "DELETE FROM embeddings WHERE sample_id IN (1, 2)")  // done, no vector
        try db.execute(sql: "UPDATE samples SET embed_state = 'pending' WHERE id IN (3, 4)")  // vector, not done
        try db.execute(sql: "UPDATE samples SET wave_thumb = NULL WHERE id = 5")  // half written
    }

    let summary = try await IndexJob.start(database: library.database, embedder: StubEmbedder()).result()

    #expect(summary.done == 5)
    #expect(try await library.scalar("SELECT count(*) FROM embeddings") == 12)
    try await library.expectConsistent()
}

@Test func changedModelVersionAlsoDeletesMaps() async throws {
    let library = try await Library.make(count: 4)
    defer { library.remove() }
    _ = try await IndexJob.start(database: library.database, embedder: StubEmbedder(version: "v1")).result()
    try await library.database.writer.write { db in
        try db.execute(
            sql: "INSERT INTO maps (id, created_at, model_version, parameters, fitted_count, input_dims, work_dims, ref_embedding, ref_work) VALUES (1, 0, 'v1', '{}', 1, 1, 1, x'00', x'00')")
        try db.execute(sql: "INSERT INTO map_points (map_id, sample_id, x, y, fitted) VALUES (1, 1, 0, 0, 1)")
    }
    _ = try await IndexJob.start(database: library.database, embedder: StubEmbedder(version: "v2")).result()
    #expect(try await library.scalar("SELECT count(*) FROM maps") == 0)
    #expect(try await library.scalar("SELECT count(*) FROM map_points") == 0)
}

@Test func afterTheRunTheVectorIndexIsReloadedAndTheMessageSaysWhatHappened() async throws {
    let library = try await Library.make(count: 10)
    defer { library.remove() }
    let index = VectorIndex()
    let summary = try await IndexJob.start(database: library.database, embedder: StubEmbedder(), vectorIndex: index).result()
    #expect(await index.count == 10)
    #expect(summary.message == "Indexed 10 samples, 0 failed.")
    #expect(IndexSummary(done: 1, failed: 2, backfilled: 3).message == "Indexed 1 samples, 2 failed. Added spectrograms to 3.")
}

private let modelsDirectory = ModelLocator.find() ?? URL(fileURLWithPath: "/nonexistent/Models")

@Test(.enabled(if: ModelLocator.isComplete(modelsDirectory), "models not found: set SONDR_MODELS"))
func indexJobWithTheRealModelIndexesGoldenFixtures() async throws {
    let made = FileManager.default.temporaryDirectory.appendingPathComponent("sondr-idx-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: made) }
    let names = ["bass_sub.wav", "hat_open.wav", "fx_riser.wav", "fx_impact.wav", "lead_saw.wav", "kick_long_tail.wav", "snare_basic.wav"]
    for name in names { try FileManager.default.copyItem(at: Fixtures.url("audio/\(name)"), to: made.appendingPathComponent(name)) }
    let database = try LibraryDatabase(inMemory: ())
    _ = try await LibraryScanner(database: database).scan(root: LibraryScanner.realURL(made))

    let summary = try await IndexJob.start(database: database, embedder: EmbeddingService(modelsDirectory: modelsDirectory)).result()

    #expect(summary.done == names.count)
    #expect(summary.failed == 0)
    let bad = try await database.writer.read {
        try Int.fetchOne($0, sql: "SELECT count(*) FROM samples WHERE embed_state != 'done' OR cluster_id IS NULL OR id NOT IN (SELECT sample_id FROM embeddings) OR wave_thumb IS NULL OR spectrogram_thumb IS NULL OR dim_brightness IS NULL")
    }
    #expect(bad == 0)
}
