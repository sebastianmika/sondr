import Foundation
import GRDB

public enum LibraryDatabaseError: Error, Equatable, LocalizedError {
    case cannotOpen(String)

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let why): return "Cannot open the library database: \(why)"
        }
    }
}

/// The single SQLite file that holds the whole library (WAL mode, foreign keys on).
///
/// One squashed schema, no migrations: the library is recreated after every schema change.
public final class LibraryDatabase: Sendable {
    public let writer: any DatabaseWriter
    /// At most one job of each kind runs against this database.
    public let jobs = JobRegistry()

    /// `~/Library/Application Support/Sondr/library.sqlite`, overridable with `SONDR_DB`.
    public static func defaultURL() -> URL {
        if let path = ProcessInfo.processInfo.environment["SONDR_DB"] {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sondr/library.sqlite")
    }

    /// Opens (creating if needed) the database at `url`.
    public init(url: URL = LibraryDatabase.defaultURL()) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var configuration = Configuration()
            configuration.foreignKeysEnabled = true
            writer = try DatabasePool(path: url.path, configuration: configuration)
            try writer.write { db in
                if try !db.tableExists("samples") { try db.execute(sql: Self.schema) }
            }
        } catch {
            throw LibraryDatabaseError.cannotOpen(error.localizedDescription)
        }
    }

    /// In-memory database for tests.
    public init(inMemory: Void) throws {
        writer = try DatabaseQueue(configuration: Configuration())
        try writer.write { try $0.execute(sql: Self.schema) }
    }

    // `pitch` is MIDI with C4 = 60, `pitch_label` the note as the file names it. A group's
    // `cluster_id` is the most common cluster among its members. Global tag rules live in `meta`.
    static let schema = """
        CREATE TABLE locations (
            id INTEGER PRIMARY KEY,
            path TEXT NOT NULL UNIQUE,
            type_filter TEXT,
            max_length REAL,
            added_at REAL NOT NULL,
            extra_tags TEXT,
            tag_rules TEXT,
            group_rules TEXT
        );

        CREATE TABLE clusters (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            color TEXT NOT NULL DEFAULT '#8E8E93',
            keywords TEXT NOT NULL DEFAULT ''
        );

        CREATE TABLE samples (
            id INTEGER PRIMARY KEY,
            content_hash TEXT NOT NULL UNIQUE,
            canonical_path TEXT NOT NULL,
            filename TEXT NOT NULL,
            name TEXT,
            rel_path TEXT NOT NULL,
            duration REAL NOT NULL,
            sample_rate REAL NOT NULL,
            channels INTEGER NOT NULL,
            format TEXT NOT NULL,
            missing INTEGER NOT NULL DEFAULT 0,
            embed_state TEXT NOT NULL DEFAULT 'pending'
                CHECK (embed_state IN ('pending', 'done', 'failed')),
            embed_error TEXT,
            cluster_id INTEGER REFERENCES clusters(id) ON DELETE SET NULL,
            cluster_score REAL,
            dim_brightness REAL,
            dim_percussiveness REAL,
            dim_energy REAL,
            dim_tonality REAL,
            dim_noisiness REAL,
            dim_duration REAL,
            wave_thumb BLOB,
            spectrogram_thumb BLOB,
            group_id INTEGER REFERENCES sample_groups(id) ON DELETE SET NULL,
            pitch INTEGER,
            pitch_label TEXT,
            file_size INTEGER NOT NULL,
            file_mtime REAL NOT NULL,
            scanned_at REAL NOT NULL
        );
        CREATE INDEX samples_name ON samples(name);
        CREATE INDEX samples_embed_state ON samples(embed_state);
        CREATE INDEX samples_cluster_id ON samples(cluster_id);
        CREATE INDEX samples_group_id ON samples(group_id);

        CREATE TABLE sample_groups (
            id INTEGER PRIMARY KEY,
            location_id INTEGER NOT NULL REFERENCES locations(id) ON DELETE CASCADE,
            folder TEXT NOT NULL,
            key TEXT NOT NULL,
            representative_id INTEGER REFERENCES samples(id) ON DELETE SET NULL,
            cluster_id INTEGER REFERENCES clusters(id) ON DELETE SET NULL,
            UNIQUE (location_id, folder, key)
        );

        CREATE TABLE sample_paths (
            id INTEGER PRIMARY KEY,
            sample_id INTEGER NOT NULL REFERENCES samples(id) ON DELETE CASCADE,
            path TEXT NOT NULL UNIQUE,
            location_id INTEGER REFERENCES locations(id) ON DELETE SET NULL,
            file_size INTEGER,
            file_mtime REAL
        );
        CREATE INDEX sample_paths_sample_id ON sample_paths(sample_id);

        CREATE TABLE embeddings (
            sample_id INTEGER PRIMARY KEY REFERENCES samples(id) ON DELETE CASCADE,
            vector BLOB NOT NULL
        );

        CREATE TABLE tags (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL UNIQUE
        );

        CREATE TABLE sample_tags (
            sample_id INTEGER NOT NULL REFERENCES samples(id) ON DELETE CASCADE,
            tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
            source TEXT NOT NULL CHECK (source IN ('auto', 'manual')),
            PRIMARY KEY (sample_id, tag_id)
        );
        CREATE INDEX sample_tags_tag_id ON sample_tags(tag_id);

        CREATE TABLE removed_auto_tags (
            sample_id INTEGER NOT NULL REFERENCES samples(id) ON DELETE CASCADE,
            tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
            PRIMARY KEY (sample_id, tag_id)
        );

        CREATE TABLE cluster_centres (
            cluster_id INTEGER NOT NULL REFERENCES clusters(id) ON DELETE CASCADE,
            model_version TEXT NOT NULL,
            vector BLOB NOT NULL,
            PRIMARY KEY (cluster_id, model_version)
        );

        CREATE TABLE dim_stats (
            dim TEXT PRIMARY KEY,
            p5 REAL NOT NULL,
            p95 REAL NOT NULL
        );

        CREATE TABLE maps (
            id INTEGER PRIMARY KEY,
            created_at REAL NOT NULL,
            model_version TEXT NOT NULL,
            parameters TEXT NOT NULL,
            fitted_count INTEGER NOT NULL,
            input_dims INTEGER NOT NULL,
            work_dims INTEGER NOT NULL,
            ref_embedding BLOB NOT NULL,
            ref_work BLOB NOT NULL,
            pca_dim INTEGER,
            pca_count INTEGER,
            pca_mean BLOB,
            pca_components BLOB,
            built_count INTEGER
        );

        CREATE TABLE map_points (
            map_id INTEGER NOT NULL REFERENCES maps(id) ON DELETE CASCADE,
            sample_id INTEGER NOT NULL REFERENCES samples(id) ON DELETE CASCADE,
            x REAL NOT NULL,
            y REAL NOT NULL,
            fitted INTEGER NOT NULL,
            PRIMARY KEY (map_id, sample_id)
        ) WITHOUT ROWID;
        CREATE INDEX map_points_sample ON map_points(sample_id);

        CREATE TABLE meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """
}
