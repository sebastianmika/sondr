import Foundation
import GRDB

public struct IndexProgress: Equatable, Sendable {
    /// Samples that were pending when the job started.
    public var total: Int
    public var done: Int
    public var failed: Int
}

public struct IndexSummary: Equatable, Sendable {
    public var done = 0
    public var failed = 0
    /// Finished samples that only got their spectrogram thumbnail (no embedding was needed).
    public var backfilled = 0
    /// True if the job stopped early because it was cancelled; the rest stays pending.
    public var cancelled = false

    /// "Indexed N samples, N failed." (+ " Added spectrograms to N.")
    public var message: String {
        "Indexed \(done) samples, \(failed) failed." + (backfilled > 0 ? " Added spectrograms to \(backfilled)." : "")
    }

    public init(done: Int = 0, failed: Int = 0, backfilled: Int = 0, cancelled: Bool = false) {
        self.done = done
        self.failed = failed
        self.backfilled = backfilled
        self.cancelled = cancelled
    }
}

/// A running (or finished) index job.
public final class IndexRun: Sendable {
    /// Emits after the start and after every committed chunk, then finishes with the job.
    public let progress: AsyncStream<IndexProgress>
    private let task: Task<IndexSummary, Error>

    init(progress: AsyncStream<IndexProgress>, task: Task<IndexSummary, Error>) {
        self.progress = progress
        self.task = task
    }

    /// Stops after the chunk in flight; nothing from that chunk is written.
    public func cancel() { task.cancel() }

    public func result() async throws -> IndexSummary { try await task.value }
}

/// Embeds every pending sample.
///
/// Per chunk of samples: decode on all cores (the next chunk is decoded while the current one is
/// embedded), embed in batches, then write embeddings, dims, thumbnails and `embed_state` in
/// **one transaction**. A sample is `done` only if all of that was committed, so the job can be
/// killed at any time and simply run again: "pending" is the work list. Unreadable files become
/// `failed` with a reason and never get a vector; if the model itself fails, the job stops with
/// that error and the chunk stays pending.
///
/// Samples that were finished before spectrogram thumbnails existed get just the thumbnail
/// (decode only, no model) before the embedding starts.
public enum IndexJob {
    public static let chunkSize = 256

    /// Starts indexing in the background.
    ///
    /// - Parameters:
    ///   - retryFailed: Also try samples that failed before.
    ///   - vectorIndex: Reloaded from the database after the run, before the result is available.
    /// - Throws: ``JobError/alreadyRunning(_:)`` immediately if another index job runs on `database`.
    public static func start(
        database: LibraryDatabase, embedder: any Embedder, chunkSize: Int = IndexJob.chunkSize,
        retryFailed: Bool = false, vectorIndex: VectorIndex? = nil
    ) throws -> IndexRun {
        try database.jobs.begin(.index)
        let (stream, continuation) = AsyncStream.makeStream(of: IndexProgress.self, bufferingPolicy: .bufferingNewest(1))
        let task = Task<IndexSummary, Error> {
            defer {
                continuation.finish()
                database.jobs.end(.index)
            }
            let summary = try await run(
                database: database, embedder: embedder, chunkSize: chunkSize, retryFailed: retryFailed
            ) { continuation.yield($0) }
            // A new Task does not inherit the cancellation, which would make the reads and writes throw.
            try await Task { try await afterRun(database, vectorIndex) }.value
            return summary
        }
        return IndexRun(progress: stream, task: task)
    }

    /// Reloads the vector index and regroups multisamples of every location.
    private static func afterRun(_ database: LibraryDatabase, _ vectorIndex: VectorIndex?) async throws {
        try await vectorIndex?.load(from: database)
        let locations = try await database.writer.read { try Int64.fetchAll($0, sql: "SELECT id FROM locations") }
        for id in locations { try await MultisampleGrouper.rebuild(database: database, locationID: id) }
    }

    private struct Pending: Sendable {
        let id: Int64
        let path: String
        let duration: Double
    }

    private struct Decoded: Sendable {
        let sample: Pending
        let clip: Result<[Float], DecodeFailure>
    }

    private struct DecodeFailure: Error, Sendable {
        let message: String
    }

    private static func run(
        database: LibraryDatabase, embedder: any Embedder, chunkSize: Int, retryFailed: Bool,
        report: @Sendable (IndexProgress) -> Void
    ) async throws -> IndexSummary {
        let version = try await embedder.modelVersion()
        try await prepare(database, modelVersion: version, retryFailed: retryFailed)
        _ = try await Reconciliation.run(database: database)

        let centres = ClusterAssigner.Centres(try await ClusterCentres.ensure(database: database, embedder: embedder))
        _ = try await database.writer.write {
            try ClusterAssigner.assignMissing($0, centres: centres)
        }

        var progress = IndexProgress(
            total: try await database.writer.read {
                try Int.fetchOne(
                    $0, sql: "SELECT count(*) FROM samples WHERE (embed_state = 'pending' OR \(needsSpectrogram)) AND missing = 0")!
            }, done: 0, failed: 0)
        report(progress)

        var backfilled = 0
        var lastID: Int64 = 0
        while true {
            let rows = try await fetch(database, after: lastID, limit: chunkSize, where: needsSpectrogram)
            guard let last = rows.last else { break }
            lastID = last.id
            let decoded = await decode(rows)
            if Task.isCancelled { return IndexSummary(done: 0, failed: 0, backfilled: backfilled, cancelled: true) }
            let count = try await database.writer.write { db -> Int in
                var stored = 0
                for case (let sample, .success(let clip)) in decoded.map({ ($0.sample, $0.clip) }) {
                    try SpectrogramThumbnail.store(db, sampleID: sample.id, thumbnail: SpectrogramThumbnail.make(audio: clip))
                    stored += 1
                }
                return stored
            }
            backfilled += count
            progress.done += count
            report(progress)
        }

        var rows = try await fetch(database, after: 0, limit: chunkSize)
        let first = rows
        var decoding = Task { await decode(first) }
        defer { decoding.cancel() }
        while !rows.isEmpty {
            let decoded = await decoding.value
            if Task.isCancelled {
                // A new Task does not inherit the cancellation, which would make the write throw.
                try await Task { try await database.writer.write { try DimStats.recompute($0) } }.value
                return IndexSummary(done: progress.done - backfilled, failed: progress.failed, backfilled: backfilled, cancelled: true)
            }
            let nextRows = try await fetch(database, after: rows.last!.id, limit: chunkSize)
            decoding = Task { await decode(nextRows) }

            let good = decoded.compactMap { item -> (Pending, [Float])? in
                if case .success(let clip) = item.clip { return (item.sample, clip) }
                return nil
            }
            let vectors = try await embed(embedder, clips: good.map(\.1))
            if Task.isCancelled {
                // A new Task does not inherit the cancellation, which would make the write throw.
                try await Task { try await database.writer.write { try DimStats.recompute($0) } }.value
                return IndexSummary(done: progress.done - backfilled, failed: progress.failed, backfilled: backfilled, cancelled: true)
            }

            let chunkResult = try await commit(database, decoded: decoded, vectors: vectors, centres: centres)
            progress.done += chunkResult.done
            progress.failed += chunkResult.failed
            report(progress)
            rows = nextRows
        }
        try await database.writer.write { try DimStats.recompute($0) }
        return IndexSummary(done: progress.done - backfilled, failed: progress.failed, backfilled: backfilled, cancelled: false)
    }

    /// Embeds a chunk. If the batch throws, one bad clip may be the cause, so it retries clip by clip and
    /// returns the failures per clip. If every clip of a larger chunk fails, the model is broken: rethrows.
    private static func embed(_ embedder: any Embedder, clips: [[Float]]) async throws -> [Result<[Float], any Error>] {
        do {
            let vectors = try await embedder.embed(audio: clips)
            guard vectors.count == clips.count else {
                throw EmbeddingError.unexpectedOutput("\(vectors.count) vectors for \(clips.count) clips")
            }
            return vectors.map { .success($0) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            var results: [Result<[Float], any Error>] = []
            for clip in clips {
                do {
                    guard let vector = try await embedder.embed(audio: [clip]).first else { throw error }
                    results.append(.success(vector))
                } catch { results.append(.failure(error)) }
            }
            if clips.count > 1, !results.contains(where: { if case .success = $0 { true } else { false } }) { throw error }
            return results
        }
    }

    /// Records the model version. If it changed, all embeddings are stale: they are deleted and
    /// every sample goes back to pending. Optionally puts failed samples back to pending.
    private static func prepare(_ database: LibraryDatabase, modelVersion: String, retryFailed: Bool) async throws {
        try await database.writer.write { db in
            let stored = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'model_version'")
            try discardStaleDerivedData(db, storedVersion: stored, newVersion: modelVersion)
            try db.execute(
                sql: "INSERT INTO meta (key, value) VALUES ('model_version', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [modelVersion])
            if retryFailed {
                try db.execute(sql: "UPDATE samples SET embed_state = 'pending', embed_error = NULL WHERE embed_state = 'failed'")
            }
        }
    }

    private static let needsSpectrogram = "(embed_state = 'done' AND spectrogram_thumb IS NULL)"
    private static let isPending = "embed_state = 'pending'"

    /// A different embedding model makes every stored vector, cluster and map worthless.
    static func discardStaleDerivedData(_ db: Database, storedVersion: String?, newVersion: String) throws {
        guard let storedVersion, storedVersion != newVersion else { return }
        try db.execute(sql: "DELETE FROM embeddings")
        try db.execute(
            sql: "UPDATE samples SET embed_state = 'pending', embed_error = NULL, cluster_id = NULL, cluster_score = NULL")
        try db.execute(sql: "DELETE FROM maps")  // map_points cascade
    }

    private static func fetch(
        _ database: LibraryDatabase, after id: Int64, limit: Int, where condition: String = isPending
    ) async throws -> [Pending] {
        try await database.writer.read { db in
            let cursor = try Row.fetchCursor(
                db,
                sql: """
                    SELECT id, canonical_path, duration FROM samples
                    WHERE \(condition) AND missing = 0 AND id > ? ORDER BY id LIMIT ?
                    """, arguments: [id, limit])
            var result: [Pending] = []
            while let row = try cursor.next() {
                result.append(Pending(id: row["id"], path: row["canonical_path"], duration: row["duration"]))
            }
            return result
        }
    }

    private static func decode(_ samples: [Pending]) async -> [Decoded] {
        await withTaskGroup(of: (Int, Decoded).self) { group in
            var next = 0
            func add(_ index: Int) {
                let sample = samples[index]
                group.addTask {
                    do {
                        return (index, Decoded(sample: sample, clip: .success(try AudioLoader.load(url: URL(fileURLWithPath: sample.path)))))
                    } catch {
                        return (index, Decoded(sample: sample, clip: .failure(DecodeFailure(message: error.localizedDescription))))
                    }
                }
            }
            while next < min(samples.count, ProcessInfo.processInfo.activeProcessorCount) {
                add(next)
                next += 1
            }
            var out = [Decoded?](repeating: nil, count: samples.count)
            while let (index, item) = await group.next() {
                out[index] = item
                if next < samples.count, !Task.isCancelled {
                    add(next)
                    next += 1
                }
            }
            return out.compactMap { $0 }
        }
    }

    private static func commit(
        _ database: LibraryDatabase, decoded: [Decoded], vectors: [Result<[Float], any Error>], centres: ClusterAssigner.Centres
    ) async throws -> (done: Int, failed: Int) {
        try await database.writer.write { db in
            var vectorIterator = vectors.makeIterator()
            var done = 0
            var failed = 0
            for item in decoded {
                switch item.clip {
                case .success(let clip):
                    guard let result = vectorIterator.next() else { continue }
                    guard case .success(let vector) = result else {
                        if case .failure(let error) = result {
                            try db.execute(
                                sql: "UPDATE samples SET embed_state = 'failed', embed_error = ? WHERE id = ?",
                                arguments: ["Embedding failed: \(error.localizedDescription)", item.sample.id])
                        }
                        failed += 1
                        continue
                    }
                    try db.execute(
                        sql: "INSERT OR REPLACE INTO embeddings (sample_id, vector) VALUES (?, ?)",
                        arguments: [item.sample.id, EmbeddingCodec.encode(vector)])
                    try DimStats.store(
                        db, sampleID: item.sample.id,
                        dims: AudioFeatures.rawDims(
                            audio: clip, sampleRate: Double(ClapMelExtractor.sampleRate), duration: item.sample.duration))
                    try WaveformThumbnail.store(
                        db, sampleID: item.sample.id, thumbnail: WaveformThumbnail.make(audio: clip))
                    try SpectrogramThumbnail.store(
                        db, sampleID: item.sample.id, thumbnail: SpectrogramThumbnail.make(audio: clip))
                    try ClusterAssigner.assign(db, sampleID: item.sample.id, vector: vector, centres: centres)
                    try db.execute(
                        sql: "UPDATE samples SET embed_state = 'done', embed_error = NULL WHERE id = ?",
                        arguments: [item.sample.id])
                    done += 1
                case .failure(let failure):
                    try db.execute(
                        sql: "UPDATE samples SET embed_state = 'failed', embed_error = ? WHERE id = ?",
                        arguments: [failure.message, item.sample.id])
                    failed += 1
                }
            }
            return (done, failed)
        }
    }
}
