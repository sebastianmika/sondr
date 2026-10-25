import GRDB

public struct ReconciliationReport: Equatable, Sendable {
    /// `done` samples without a usable vector or without dims/thumbnail: back to pending.
    public var resetToPending = 0
    /// Vectors of samples that are not `done`, or unreadable vectors: deleted.
    public var removedVectors = 0

    public var isClean: Bool { resetToPending == 0 && removedVectors == 0 }
}

/// Makes `embed_state` and the `embeddings` table agree again after a crash or a bad write.
///
/// The index job commits a vector and the state in one transaction, so this should find nothing.
/// It exists for databases that were edited, restored from a partial copy, or hit by a bug. It
/// never deletes samples, and only discards derived data, which the index job recomputes.
public enum Reconciliation {
    public static func run(database: LibraryDatabase) async throws -> ReconciliationReport {
        try await database.writer.write { try run($0) }
    }

    public static func run(_ db: Database) throws -> ReconciliationReport {
        var report = ReconciliationReport()

        // Vectors that cannot be read back (wrong length) are worthless.
        try db.execute(
            sql: "DELETE FROM embeddings WHERE length(vector) != ?", arguments: [512 * 2])  // Float16 x 512
        report.removedVectors += db.changesCount

        // Finished samples that lack their vector, dims or thumbnail.
        try db.execute(
            sql: """
                UPDATE samples SET embed_state = 'pending', embed_error = NULL, cluster_id = NULL, cluster_score = NULL,
                    wave_thumb = NULL, spectrogram_thumb = NULL, dim_brightness = NULL, dim_percussiveness = NULL, dim_energy = NULL,
                    dim_tonality = NULL, dim_noisiness = NULL, dim_duration = NULL
                WHERE embed_state = 'done' AND (
                    id NOT IN (SELECT sample_id FROM embeddings)
                    OR wave_thumb IS NULL OR dim_brightness IS NULL OR dim_percussiveness IS NULL
                    OR dim_energy IS NULL OR dim_tonality IS NULL OR dim_noisiness IS NULL OR dim_duration IS NULL)
                """)
        report.resetToPending = db.changesCount

        // Vectors whose sample is not finished (including ones reset just above).
        try db.execute(
            sql: "DELETE FROM embeddings WHERE sample_id NOT IN (SELECT id FROM samples WHERE embed_state = 'done')")
        report.removedVectors += db.changesCount

        // An unfinished sample must not carry a cluster.
        try db.execute(
            sql: """
                UPDATE samples SET cluster_id = NULL, cluster_score = NULL
                WHERE embed_state != 'done' AND (cluster_id IS NOT NULL OR cluster_score IS NOT NULL)
                """)
        return report
    }
}
