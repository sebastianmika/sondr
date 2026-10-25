import Foundation
import GRDB

public enum TagRetagError: Error, Equatable, LocalizedError {
    /// A previous change of tag settings has not been applied to all samples yet.
    case pending

    public var errorDescription: String? {
        switch self {
        case .pending: return "An earlier change of tag settings is still being applied."
        }
    }
}

public struct RetagProgress: Equatable, Sendable {
    public var total: Int
    public var done: Int
}

public struct RetagSummary: Equatable, Sendable {
    public var samples: Int
    /// True if the job stopped early; the change stays pending and resumes on the next start.
    public var cancelled: Bool
}

/// A running (or finished) retag job.
public final class RetagRun: Sendable {
    /// Emits after the start and after every committed chunk, then finishes with the job.
    public let progress: AsyncStream<RetagProgress>
    private let task: Task<RetagSummary, Error>

    init(progress: AsyncStream<RetagProgress>, task: Task<RetagSummary, Error>) {
        self.progress = progress
        self.task = task
    }

    /// Stops after the chunk in flight.
    public func cancel() { task.cancel() }

    public func result() async throws -> RetagSummary { try await task.value }
}

/// Applies a change of tag settings to the samples it affects (see ``TagRetag``).
///
/// Two steps, so that an interrupted run can be finished: ``commit(_:old:new:)`` saves the new
/// settings and remembers old and new in `meta` in one transaction; ``start(database:tagger:chunkSize:)``
/// works through the affected samples in chunks and then forgets the pending change. A chunk is one
/// transaction and the work is idempotent, so killing the app at any time and starting the job
/// again gives the same result as an uninterrupted run.
public enum TagRetagJob {
    public static let chunkSize = 500
    static let pendingKey = "retag_pending"

    private struct Pending: Codable {
        var old: TaggingSettings
        var new: TaggingSettings
    }

    public static func hasPending(_ db: Database) throws -> Bool {
        try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [pendingKey]) != nil
    }

    /// Saves `new` as the tag settings and marks the change as pending.
    /// - Throws: ``TagRuleError`` for an invalid rule, ``TagRetagError/pending`` if an earlier change is unfinished.
    public static func commit(_ db: Database, old: TaggingSettings, new: TaggingSettings) throws {
        _ = try TagRuleSet(new.global)
        for item in new.locations.values { _ = try TagRuleSet(item.rules) }
        guard try !hasPending(db) else { throw TagRetagError.pending }
        try TaggingStore.saveGlobal(db, new.global)
        for (id, tagging) in new.locations { try TaggingStore.save(db, locationID: id, tagging) }
        let saved = try TaggingStore.load(db)
        let data = try JSONEncoder().encode(Pending(old: old, new: saved))
        try db.execute(
            sql: "INSERT INTO meta (key, value) VALUES (?, ?)", arguments: [pendingKey, String(decoding: data, as: UTF8.self)])
    }

    /// Starts applying the pending change in the background (nothing pending: finishes at once).
    /// - Throws: ``JobError/alreadyRunning(_:)`` if a scan or another retag runs on `database`.
    public static func start(
        database: LibraryDatabase, tagger: Tagger, chunkSize: Int = TagRetagJob.chunkSize
    ) throws -> RetagRun {
        try database.jobs.begin(.retag)
        do { try database.jobs.begin(.scan) } catch {
            database.jobs.end(.retag)
            throw error
        }
        let (stream, continuation) = AsyncStream.makeStream(of: RetagProgress.self, bufferingPolicy: .bufferingNewest(1))
        let task = Task<RetagSummary, Error> {
            defer {
                continuation.finish()
                database.jobs.end(.scan)
                database.jobs.end(.retag)
            }
            return try await run(database: database, tagger: tagger, chunkSize: chunkSize) { continuation.yield($0) }
        }
        return RetagRun(progress: stream, task: task)
    }

    private static func run(
        database: LibraryDatabase, tagger: Tagger, chunkSize: Int, report: @Sendable (RetagProgress) -> Void
    ) async throws -> RetagSummary {
        let text = try await database.writer.read {
            try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key = ?", arguments: [pendingKey])
        }
        guard let text else { return RetagSummary(samples: 0, cancelled: false) }
        let pending = try JSONDecoder().decode(Pending.self, from: Data(text.utf8))
        let old = try TagComputer(tagger: tagger, settings: pending.old)
        let new = try TagComputer(tagger: tagger, settings: pending.new)
        let ids = try await database.writer.read {
            try TagRetag.affectedSampleIDs($0, old: pending.old, new: pending.new)
        }

        var progress = RetagProgress(total: ids.count, done: 0)
        report(progress)
        for chunk in ids.chunked(chunkSize) {
            if Task.isCancelled { return RetagSummary(samples: progress.done, cancelled: true) }
            do {
                try await database.writer.write { try TagRetag.retag($0, sampleIDs: chunk, old: old, new: new) }
            } catch is CancellationError {
                // The chunk may or may not have been written; either way a later run gives the same result.
                return RetagSummary(samples: progress.done, cancelled: true)
            }
            progress.done += chunk.count
            report(progress)
        }
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [pendingKey])
            try LibraryTags.pruneUnused(db)
        }
        return RetagSummary(samples: ids.count, cancelled: false)
    }
}
