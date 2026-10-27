import Foundation
import GRDB

public struct LibraryStats: Equatable, Sendable {
    public var samples = 0
    public var indexed = 0
    public var pending = 0
    public var failed = 0
    public var missing = 0
}

public struct LocationInfo: Equatable, Sendable, Identifiable {
    public let id: Int64
    public let path: String
    /// What the user calls this location; the folder's name until they pick one.
    public let name: String
    public let typeFilter: String?
    public let maxLength: Double?
    public let tagging: LocationTagging
    public let multisampleRules: MultisampleRules
    /// Samples that have at least one path in this location.
    public let sampleCount: Int
}

/// Read-only summaries for the sidebar and status line, and the operations that remove things.
public enum LibraryInfo {
    public static func stats(_ db: Database) throws -> LibraryStats {
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT count(*) AS samples,
                    coalesce(sum(embed_state = 'done' AND missing = 0), 0) AS indexed,
                    coalesce(sum(embed_state = 'pending' AND missing = 0), 0) AS pending,
                    coalesce(sum(embed_state = 'failed' AND missing = 0), 0) AS failed,
                    coalesce(sum(missing), 0) AS missing
                FROM samples
                """)!
        return LibraryStats(
            samples: row["samples"], indexed: row["indexed"], pending: row["pending"], failed: row["failed"],
            missing: row["missing"])
    }

    public static func locations(_ db: Database) throws -> [LocationInfo] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT locations.id, locations.path, locations.name, locations.type_filter, locations.max_length,
                    locations.extra_tags, locations.tag_rules, locations.group_rules,
                    (SELECT count(DISTINCT sample_id) FROM sample_paths WHERE location_id = locations.id) AS n
                FROM locations
                """
        ).map {
            LocationInfo(
                id: $0["id"], path: $0["path"],
                name: LibraryInfo.displayName($0["name"], path: $0["path"]), typeFilter: $0["type_filter"], maxLength: $0["max_length"],
                tagging: TaggingStore.tagging(extraTags: $0["extra_tags"], rules: $0["tag_rules"]),
                multisampleRules: MultisampleStore.decode($0["group_rules"]),
                sampleCount: $0["n"])
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The stored name, or the folder's name when none is stored or it is blank.
    static func displayName(_ name: String?, path: String) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : trimmed
    }

    /// Every path a sample has, with the folder it was found in.
    public static func paths(_ db: Database, sampleID: Int64) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT path FROM sample_paths WHERE sample_id = ? ORDER BY id", arguments: [sampleID])
    }

    /// Removes a location and the samples that only it held. Samples that also have a path in
    /// another location stay (tags, embedding and all). Returns the ids of the deleted samples,
    /// so that the caller can drop them from the vector index. Audio files are never touched.
    public static func removeLocation(_ db: Database, id: Int64) throws -> [Int64] {
        // Survivors lose the tags this location gave them (extra tags, path words), unless another path gives them too.
        let survivors = try Int64.fetchAll(
            db,
            sql: """
                SELECT DISTINCT sample_id FROM sample_paths WHERE location_id = ?
                    AND sample_id IN (SELECT sample_id FROM sample_paths WHERE location_id IS NOT ?)
                """, arguments: [id, id])
        let settings = try TaggingStore.load(db)
        let computer = try? TagComputer(tagger: Tagger.bundled(), settings: settings)
        let before = try computer.map { computer in
            try TagRetag.entries(db, sampleIDs: survivors).mapValues { TagRetag.union($0, computer) }
        } ?? [:]

        // Only samples that had a path here may go; missing samples of other locations have no path and must stay.
        let held = try Int64.fetchAll(db, sql: "SELECT DISTINCT sample_id FROM sample_paths WHERE location_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM sample_paths WHERE location_id = ?", arguments: [id])
        let orphans = try held.filter { sample in
            try !Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM sample_paths WHERE sample_id = ?)", arguments: [sample])!
        }
        for sample in orphans { try db.execute(sql: "DELETE FROM samples WHERE id = ?", arguments: [sample]) }
        try db.execute(sql: "DELETE FROM locations WHERE id = ?", arguments: [id])
        // Samples that survive through another location may have had their canonical path here.
        try db.execute(
            sql: """
                UPDATE samples SET canonical_path = (SELECT path FROM sample_paths WHERE sample_id = samples.id ORDER BY id LIMIT 1)
                WHERE canonical_path NOT IN (SELECT path FROM sample_paths WHERE sample_id = samples.id)
                    AND EXISTS (SELECT 1 FROM sample_paths WHERE sample_id = samples.id)
                """)
        if computer != nil {
            var remaining = settings
            remaining.locations[id] = nil
            if let after = try? TagComputer(tagger: Tagger.bundled(), settings: remaining) {
                let entries = try TagRetag.entries(db, sampleIDs: survivors)
                for sample in survivors {
                    try TagRetag.apply(
                        db, sampleID: sample, old: before[sample] ?? [],
                        new: TagRetag.union(entries[sample] ?? [], after))
                }
            }
        }
        try LibraryTags.pruneUnused(db)
        return orphans
    }
}
