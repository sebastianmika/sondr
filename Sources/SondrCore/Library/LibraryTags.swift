import Foundation
import GRDB

public enum TagError: Error, Equatable, LocalizedError {
    case invalidName
    case nameTaken(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName: return "A tag name cannot be empty."
        case .nameTaken(let name): return "There is already a tag called “\(name)”. Merge into it instead."
        case .notFound(let name): return "There is no tag called “\(name)”."
        }
    }
}

/// Reads and writes tags in the database. Auto tags come from ``Tagger``; manual tags are the
/// user's. A user removing an auto tag is remembered in `removed_auto_tags`, so no later scan
/// brings it back (the legacy app re-added them on every scan).
///
/// Every function runs in the caller's transaction, so a bulk edit is one commit.
public enum LibraryTags {
    static let chunk = 500

    /// Lower-cased, trimmed tag name. Throws ``TagError/invalidName`` for an empty one.
    public static func normalised(_ name: String) throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { throw TagError.invalidName }
        return clean
    }

    /// Adds auto tags to a sample, except ones the user removed. Existing rows (auto or manual) stay.
    public static func applyAuto(_ db: Database, sampleID: Int64, tags: Set<String>) throws {
        for name in tags.sorted() {
            let tagID = try tagID(db, name)
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO sample_tags (sample_id, tag_id, source)
                    SELECT ?, ?, 'auto'
                    WHERE NOT EXISTS (SELECT 1 FROM removed_auto_tags WHERE sample_id = ? AND tag_id = ?)
                    """, arguments: [sampleID, tagID, sampleID, tagID])
        }
    }

    /// Adds a manual tag. An earlier removal of the same auto tag is forgotten.
    public static func add(_ db: Database, sampleID: Int64, name: String) throws {
        try add(db, sampleIDs: [sampleID], name: name)
    }

    /// Adds a manual tag to many samples. An earlier removal of the same auto tag is forgotten, and
    /// samples that had the tag as an auto tag now own it as a manual one.
    public static func add(_ db: Database, sampleIDs: [Int64], name: String) throws {
        let name = try normalised(name)
        let tagID = try tagID(db, name)
        for ids in sampleIDs.chunked(chunk) {
            let marks = placeholders(ids.count)
            try db.execute(
                sql: "DELETE FROM removed_auto_tags WHERE tag_id = ? AND sample_id IN (\(marks))",
                arguments: StatementArguments([tagID] + ids))
            try db.execute(
                sql: """
                    INSERT INTO sample_tags (sample_id, tag_id, source)
                    SELECT id, ?, 'manual' FROM samples WHERE id IN (\(marks)) ON CONFLICT(sample_id, tag_id) DO UPDATE SET source = 'manual'
                    """, arguments: StatementArguments([tagID] + ids))
        }
    }

    /// Removes a tag from a sample. Removing an auto tag makes the removal permanent.
    public static func remove(_ db: Database, sampleID: Int64, name: String) throws {
        try remove(db, sampleIDs: [sampleID], name: name)
    }

    /// Removes a tag from many samples. Auto tags are remembered as removed; empty tags disappear.
    public static func remove(_ db: Database, sampleIDs: [Int64], name: String) throws {
        guard let tagID = try Int64.fetchOne(db, sql: "SELECT id FROM tags WHERE name = ?", arguments: [name])
        else { return }
        for ids in sampleIDs.chunked(chunk) {
            let marks = placeholders(ids.count)
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO removed_auto_tags (sample_id, tag_id)
                    SELECT sample_id, tag_id FROM sample_tags
                    WHERE tag_id = ? AND source = 'auto' AND sample_id IN (\(marks))
                    """, arguments: StatementArguments([tagID] + ids))
            try db.execute(
                sql: "DELETE FROM sample_tags WHERE tag_id = ? AND sample_id IN (\(marks))",
                arguments: StatementArguments([tagID] + ids))
        }
        try pruneUnused(db)
    }

    /// Renames a tag. Throws ``TagError/nameTaken(_:)`` if `new` exists (use ``merge(_:source:into:)``).
    public static func rename(_ db: Database, from old: String, to new: String) throws {
        let new = try normalised(new)
        guard try tagID(existing: old, db) != nil else { throw TagError.notFound(old) }
        if new == old { return }
        if try tagID(existing: new, db) != nil { throw TagError.nameTaken(new) }
        try merge(db, source: old, into: new)
    }

    /// Moves every use of `source` to `target` (created if needed) and removes `source`.
    ///
    /// No sample ends up with `target` twice; a manual use stays manual. Where `source` was an
    /// auto tag it is recorded as removed for that sample, so rescans do not bring it back.
    public static func merge(_ db: Database, source: String, into target: String) throws {
        let target = try normalised(target)
        guard let sourceID = try tagID(existing: source, db) else { throw TagError.notFound(source) }
        if source == target { return }
        let targetID = try tagID(db, target)
        // Manual uses (also lifts a removal of the target tag for these samples).
        try db.execute(
            sql: "DELETE FROM removed_auto_tags WHERE tag_id = ? AND sample_id IN (SELECT sample_id FROM sample_tags WHERE tag_id = ? AND source = 'manual')",
            arguments: [targetID, sourceID])
        try db.execute(
            sql: """
                INSERT INTO sample_tags (sample_id, tag_id, source)
                SELECT sample_id, ?, 'manual' FROM sample_tags WHERE tag_id = ? AND source = 'manual'
                ON CONFLICT(sample_id, tag_id) DO UPDATE SET source = 'manual'
                """, arguments: [targetID, sourceID])
        // Auto uses, unless the user removed the target tag from that sample.
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO sample_tags (sample_id, tag_id, source)
                SELECT sample_id, ?, 'auto' FROM sample_tags
                WHERE tag_id = ? AND source = 'auto'
                  AND NOT EXISTS (SELECT 1 FROM removed_auto_tags r WHERE r.sample_id = sample_tags.sample_id AND r.tag_id = ?)
                """, arguments: [targetID, sourceID, targetID])
        try deleteTag(db, id: sourceID)
    }

    /// Removes a tag from every sample. Where it was an auto tag the removal is remembered.
    public static func delete(_ db: Database, name: String) throws {
        guard let id = try tagID(existing: name, db) else { throw TagError.notFound(name) }
        try deleteTag(db, id: id)
    }

    /// Deletes tags that no sample uses and that no removal refers to.
    /// Share of a location's samples below which one of its auto tags is dropped by ``dropRare(_:locationID:upTo:keeping:)``.
    public static let minimumShare = 0.01

    /// Removes the auto tags of a location's samples that are rare there: used by `n` samples or fewer,
    /// or by less than ``minimumShare`` of them. The removals are remembered, so rescans do not bring the
    /// tags back. Manual tags and the tags in `keeping` (a location's extra tags) stay.
    /// - Returns: How many tags were dropped.
    @discardableResult
    public static func dropRare(_ db: Database, locationID: Int64, upTo n: Int, keeping: [String] = []) throws -> Int {
        let keep = String(decoding: try JSONEncoder().encode(keeping), as: UTF8.self)
        let tagIDs = try Int64.fetchAll(
            db,
            sql: """
                WITH loc AS (SELECT DISTINCT sample_id FROM sample_paths WHERE location_id = ?),
                counts AS (
                    SELECT tag_id, count(*) AS n FROM sample_tags
                    WHERE source = 'auto' AND sample_id IN loc GROUP BY tag_id)
                SELECT tag_id FROM counts
                WHERE (n <= ? OR n < ? * (SELECT count(*) FROM loc))
                    AND tag_id NOT IN (SELECT id FROM tags WHERE name IN (SELECT value FROM json_each(?)))
                """, arguments: [locationID, n, minimumShare, keep])
        for ids in tagIDs.chunked(chunk) {
            let json = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
            let rare = """
                FROM sample_tags WHERE source = 'auto' AND tag_id IN (SELECT value FROM json_each(?))
                    AND sample_id IN (SELECT sample_id FROM sample_paths WHERE location_id = ?)
                """
            try db.execute(
                sql: "INSERT OR IGNORE INTO removed_auto_tags (sample_id, tag_id) SELECT sample_id, tag_id " + rare,
                arguments: [json, locationID])
            try db.execute(sql: "DELETE " + rare, arguments: [json, locationID])
        }
        try pruneUnused(db)
        return tagIDs.count
    }

    public static func pruneUnused(_ db: Database) throws {
        try db.execute(
            sql: """
                DELETE FROM tags WHERE id NOT IN (SELECT tag_id FROM sample_tags)
                    AND id NOT IN (SELECT tag_id FROM removed_auto_tags)
                """)
    }

    /// Tag names of a sample, sorted.
    public static func names(_ db: Database, sampleID: Int64) throws -> [String] {
        try String.fetchAll(
            db,
            sql: """
                SELECT tags.name FROM sample_tags JOIN tags ON tags.id = sample_tags.tag_id
                WHERE sample_id = ? ORDER BY tags.name
                """, arguments: [sampleID])
    }

    // MARK: Helpers

    private static func deleteTag(_ db: Database, id: Int64) throws {
        try db.execute(
            sql: "INSERT OR IGNORE INTO removed_auto_tags (sample_id, tag_id) SELECT sample_id, tag_id FROM sample_tags WHERE tag_id = ? AND source = 'auto'",
            arguments: [id])
        try db.execute(sql: "DELETE FROM sample_tags WHERE tag_id = ?", arguments: [id])
        try pruneUnused(db)
    }

    private static func tagID(existing name: String, _ db: Database) throws -> Int64? {
        try Int64.fetchOne(db, sql: "SELECT id FROM tags WHERE name = ?", arguments: [name])
    }

    private static func tagID(_ db: Database, _ name: String) throws -> Int64 {
        try db.execute(sql: "INSERT OR IGNORE INTO tags (name) VALUES (?)", arguments: [name])
        return try Int64.fetchOne(db, sql: "SELECT id FROM tags WHERE name = ?", arguments: [name])!
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
