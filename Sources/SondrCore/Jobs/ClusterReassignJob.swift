import Foundation
import GRDB

public struct ReclusterProgress: Equatable, Sendable {
    public var total: Int
    public var done: Int
}

public struct ReclusterSummary: Equatable, Sendable {
    public var samples: Int
    /// True if the job stopped early; the change stays pending and resumes on the next start.
    public var cancelled: Bool
}

/// A running (or finished) recluster job.
public final class ReclusterRun: Sendable {
    /// Emits after the start and after every committed chunk, then finishes with the job.
    public let progress: AsyncStream<ReclusterProgress>
    private let task: Task<ReclusterSummary, Error>

    init(progress: AsyncStream<ReclusterProgress>, task: Task<ReclusterSummary, Error>) {
        self.progress = progress
        self.task = task
    }

    /// Stops after the chunk in flight.
    public func cancel() { task.cancel() }

    public func result() async throws -> ReclusterSummary { try await task.value }
}

/// Applies an edit of the clusters to every sample (same two steps as ``TagRetagJob``).
///
/// ``commit(_:edited:)`` saves the edited rows, drops the centres of changed and removed clusters,
/// clears every sample's cluster and marks the change pending, all in one transaction.
/// ``start(database:embedder:chunkSize:)`` computes the missing centres and assigns the samples in
/// chunks of one transaction each. Both steps are idempotent, so after a kill the next start
/// finishes the work. Excludes scan, index and retag, and is excluded by them.
public enum ClusterReassignJob {
    static let pendingKey = "recluster_pending"

    public static func hasPending(_ db: Database) throws -> Bool {
        try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [pendingKey]) != nil
    }

    /// Saves the clusters as `edited`. Rows with an id that exists are updated, missing ids are
    /// deleted, rows with a negative or unknown id are added with the next free id (`max(id) + 1`;
    /// an unreadable colour becomes a generated one).
    /// - Returns: True if the samples must be assigned again (centres changed); then the change is pending.
    /// - Throws: ``ClusterError/invalidEdit(_:)`` for no clusters or an empty name or keywords,
    ///   ``ClusterError/pending`` if an earlier change is unfinished.
    @discardableResult
    public static func commit(_ db: Database, edited: [ClusterDefinition]) throws -> Bool {
        guard !edited.isEmpty else { throw ClusterError.invalidEdit("At least one cluster is needed.") }
        for cluster in edited
        where cluster.name.trimmingCharacters(in: .whitespaces).isEmpty
            || cluster.keywords.trimmingCharacters(in: .whitespaces).isEmpty
        {
            throw ClusterError.invalidEdit("Every cluster needs a name and a description.")
        }
        guard try !hasPending(db) else { throw ClusterError.pending }

        let current = Dictionary(uniqueKeysWithValues: try ClusterCentres.definitions(db).map { ($0.id, $0) })
        let keptIDs = Set(edited.map(\.id)).intersection(current.keys)
        var nextID = (current.keys.max() ?? -1) + 1
        var centresChanged = false

        for id in current.keys where !keptIDs.contains(id) {
            try db.execute(sql: "DELETE FROM clusters WHERE id = ?", arguments: [id])
            centresChanged = true
        }
        for cluster in edited {
            let color = ClusterPalette.RGB(hex: cluster.color)?.hex
            if let old = current[cluster.id] {
                try db.execute(
                    sql: "UPDATE clusters SET name = ?, color = ?, keywords = ? WHERE id = ?",
                    arguments: [cluster.name, color ?? old.color, cluster.keywords, cluster.id])
                if old.keywords != cluster.keywords {
                    try db.execute(sql: "DELETE FROM cluster_centres WHERE cluster_id = ?", arguments: [cluster.id])
                    centresChanged = true
                }
            } else {
                try db.execute(
                    sql: "INSERT INTO clusters (id, name, color, keywords) VALUES (?, ?, ?, ?)",
                    arguments: [nextID, cluster.name, color ?? ClusterPalette.generatedHex(forCluster: nextID), cluster.keywords])
                nextID += 1
                centresChanged = true
            }
        }
        guard centresChanged else { return false }
        // A new or changed centre can win samples from any cluster, so all of them are assigned again.
        try db.execute(sql: "UPDATE samples SET cluster_id = NULL, cluster_score = NULL")
        try db.execute(sql: "INSERT INTO meta (key, value) VALUES (?, '1')", arguments: [pendingKey])
        return true
    }

    /// Starts applying the pending change in the background (nothing pending: finishes at once).
    /// - Throws: ``JobError/alreadyRunning(_:)`` if a scan, index, retag or recluster runs on `database`.
    public static func start(
        database: LibraryDatabase, embedder: any Embedder, chunkSize: Int = ClusterAssigner.chunkSize
    ) throws -> ReclusterRun {
        let kinds: [JobKind] = [.recluster, .scan, .index, .retag]
        try database.jobs.begin(kinds)
        let (stream, continuation) = AsyncStream.makeStream(of: ReclusterProgress.self, bufferingPolicy: .bufferingNewest(1))
        let task = Task<ReclusterSummary, Error> {
            defer {
                continuation.finish()
                kinds.forEach(database.jobs.end)
            }
            return try await run(database: database, embedder: embedder, chunkSize: chunkSize) { continuation.yield($0) }
        }
        return ReclusterRun(progress: stream, task: task)
    }

    private static func run(
        database: LibraryDatabase, embedder: any Embedder, chunkSize: Int, report: @Sendable (ReclusterProgress) -> Void
    ) async throws -> ReclusterSummary {
        var progress = ReclusterProgress(total: 0, done: 0)
        do {
            guard try await database.writer.read({ try hasPending($0) }) else {
                return ReclusterSummary(samples: 0, cancelled: false)
            }
            let centres = ClusterAssigner.Centres(try await ClusterCentres.ensure(database: database, embedder: embedder))
            progress.total = try await database.writer.read {
                try Int.fetchOne($0, sql: "SELECT count(*) FROM samples WHERE embed_state = 'done' AND cluster_id IS NULL")!
            }
            report(progress)
            let total = progress.total
            progress.done = try await ClusterAssigner.assignMissing(database: database, centres: centres, chunkSize: chunkSize) {
                report(ReclusterProgress(total: total, done: $0))
            }
        } catch is CancellationError {
            return ReclusterSummary(samples: progress.done, cancelled: true)
        }
        if Task.isCancelled { return ReclusterSummary(samples: progress.done, cancelled: true) }
        try await database.writer.write { try $0.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [pendingKey]) }
        return ReclusterSummary(samples: progress.done, cancelled: false)
    }
}
