import Foundation
import GRDB

public enum MultisampleGroupError: Error, Equatable, Sendable {
    case emptyName
    case noSamples
    case notAMember
}

/// Edits multisample groups by hand. Every edit marks the group `manual`, so ``MultisampleGrouper/rebuild(database:locationID:)``
/// leaves it and its members alone from then on. A group left without members is deleted.
public enum MultisampleGroups {
    public struct Info: Equatable, Sendable, Identifiable {
        public let id: Int64
        public let name: String
        public let manual: Bool
        public let representativeID: Int64?
        public let size: Int
        /// Lowest and highest note as written; empty when no member has a pitch.
        public let lowLabel: String
        public let highLabel: String
    }

    /// A new manual group of the given samples, which leave any group they were in.
    /// The representative is the member at the median pitch (the first member when none has a pitch).
    /// - Returns: The new group's id.
    @discardableResult
    public static func create(database: LibraryDatabase, locationID: Int64, name: String, sampleIDs: [Int64]) async throws -> Int64 {
        let name = try cleaned(name)
        guard !sampleIDs.isEmpty else { throw MultisampleGroupError.noSamples }
        let pitches = try await pitches(database, of: sampleIDs)
        return try await database.writer.write { db in
            try detach(db, sampleIDs)
            try db.execute(
                sql: "INSERT INTO sample_groups (location_id, folder, key, name, manual) VALUES (?, '', ?, ?, 1)",
                arguments: [locationID, manualKey(), name])
            let groupID = db.lastInsertedRowID
            try attach(db, groupID: groupID, sampleIDs: sampleIDs, pitches: pitches)
            try tidy(db, groupID: groupID)
            return groupID
        }
    }

    public static func rename(database: LibraryDatabase, groupID: Int64, name: String) async throws {
        let name = try cleaned(name)
        try await database.writer.write { db in
            try markManual(db, groupID)
            try db.execute(sql: "UPDATE sample_groups SET name = ? WHERE id = ?", arguments: [name, groupID])
        }
    }

    /// Dissolves the group; its members become single samples.
    public static func delete(database: LibraryDatabase, groupID: Int64) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE samples SET group_id = NULL, pitch = NULL, pitch_label = NULL WHERE group_id = ?", arguments: [groupID])
            try db.execute(sql: "DELETE FROM sample_groups WHERE id = ?", arguments: [groupID])
        }
    }

    /// Moves the samples into the group, out of any group they were in.
    public static func addMembers(database: LibraryDatabase, groupID: Int64, sampleIDs: [Int64]) async throws {
        let pitches = try await pitches(database, of: sampleIDs)
        try await database.writer.write { db in
            let inside = Set(try Int64.fetchAll(db, sql: "SELECT id FROM samples WHERE group_id = ?", arguments: [groupID]))
            let sampleIDs = sampleIDs.filter { !inside.contains($0) }
            try detach(db, sampleIDs)
            try markManual(db, groupID)
            try attach(db, groupID: groupID, sampleIDs: sampleIDs, pitches: pitches)
            try tidy(db, groupID: groupID)
        }
    }

    /// Takes the samples out of the group. The group disappears when no member is left.
    public static func removeMembers(database: LibraryDatabase, groupID: Int64, sampleIDs: [Int64]) async throws {
        try await database.writer.write { db in
            try markManual(db, groupID)
            try db.execute(
                sql: """
                    UPDATE samples SET group_id = NULL, pitch = NULL, pitch_label = NULL
                    WHERE group_id = ? AND id IN (SELECT value FROM json_each(?))
                    """, arguments: [groupID, json(sampleIDs)])
            try tidy(db, groupID: groupID)
        }
    }

    public static func setRepresentative(database: LibraryDatabase, groupID: Int64, sampleID: Int64) async throws {
        try await database.writer.write { db in
            guard try Bool.fetchOne(
                db, sql: "SELECT EXISTS (SELECT 1 FROM samples WHERE id = ? AND group_id = ?)", arguments: [sampleID, groupID]) == true
            else { throw MultisampleGroupError.notAMember }
            try markManual(db, groupID)
            try db.execute(sql: "UPDATE sample_groups SET representative_id = ? WHERE id = ?", arguments: [sampleID, groupID])
        }
    }

    /// The groups of one location, by name.
    public static func list(database: LibraryDatabase, locationID: Int64) async throws -> [Info] {
        try await database.writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT g.id, g.name, g.manual, g.representative_id,
                        (SELECT count(*) FROM samples m WHERE m.group_id = g.id) AS size,
                        (SELECT m.pitch_label FROM samples m WHERE m.group_id = g.id AND m.pitch IS NOT NULL
                            ORDER BY m.pitch, m.id LIMIT 1) AS low,
                        (SELECT m.pitch_label FROM samples m WHERE m.group_id = g.id AND m.pitch IS NOT NULL
                            ORDER BY m.pitch DESC, m.id LIMIT 1) AS high
                    FROM sample_groups g WHERE g.location_id = ? ORDER BY g.name COLLATE NOCASE, g.id
                    """, arguments: [locationID]
            ).map { row in
                let low: String? = row["low"], high: String? = row["high"]
                return Info(
                    id: row["id"], name: row["name"], manual: (row["manual"] as Int) != 0,
                    representativeID: row["representative_id"], size: row["size"], lowLabel: low ?? "", highLabel: high ?? "")
            }
        }
    }

    // MARK: Helpers

    private static func cleaned(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MultisampleGroupError.emptyName }
        return trimmed
    }

    private static func manualKey() -> String { "manual:\(UUID().uuidString)" }

    private static func json(_ ids: [Int64]) -> String { "[" + ids.map(String.init).joined(separator: ",") + "]" }

    /// Pitch of each sample: the note in its file name, else the root note in its file; absent when neither says.
    private static func pitches(_ database: LibraryDatabase, of ids: [Int64]) async throws -> [Int64: (midi: Int, label: String)] {
        let files = try await database.writer.read { db in
            try Row.fetchAll(
                db, sql: "SELECT id, filename, canonical_path FROM samples WHERE id IN (SELECT value FROM json_each(?))",
                arguments: [json(ids)]
            ).map { (id: $0["id"] as Int64, filename: $0["filename"] as String, path: $0["canonical_path"] as String) }
        }
        var found: [Int64: (midi: Int, label: String)] = [:]
        for file in files {
            let stem = (file.filename as NSString).deletingPathExtension
            if let parsed = MultisampleNames.parse(stem: stem), parsed.kind == .note {
                found[file.id] = (parsed.midi, parsed.label ?? MultisampleNames.noteLabel(parsed.midi))
            } else if let note = AudioRootNote.read(from: URL(fileURLWithPath: file.path)) {
                found[file.id] = (note, MultisampleNames.noteLabel(note))
            }
        }
        return found
    }

    private static func attach(
        _ db: Database, groupID: Int64, sampleIDs: [Int64], pitches: [Int64: (midi: Int, label: String)]
    ) throws {
        for id in sampleIDs {
            try db.execute(
                sql: "UPDATE samples SET group_id = ?, pitch = ?, pitch_label = ? WHERE id = ?",
                arguments: [groupID, pitches[id]?.midi, pitches[id]?.label, id])
        }
    }

    /// Takes samples out of their groups; those groups stay valid (and become manual).
    private static func detach(_ db: Database, _ sampleIDs: [Int64]) throws {
        let old = try Int64.fetchAll(
            db, sql: "SELECT DISTINCT group_id FROM samples WHERE group_id IS NOT NULL AND id IN (SELECT value FROM json_each(?))",
            arguments: [json(sampleIDs)])
        try db.execute(
            sql: """
                UPDATE samples SET group_id = NULL, pitch = NULL, pitch_label = NULL
                WHERE id IN (SELECT value FROM json_each(?))
                """, arguments: [json(sampleIDs)])
        for id in old {
            try markManual(db, id)
            try tidy(db, groupID: id)
        }
    }

    /// An edited automatic group is no longer ours to rebuild. Its key is freed for new automatic groups.
    private static func markManual(_ db: Database, _ groupID: Int64) throws {
        try db.execute(
            sql: "UPDATE sample_groups SET manual = 1, folder = '', key = ? WHERE id = ? AND manual = 0",
            arguments: [manualKey(), groupID])
    }

    /// Deletes an empty group; gives one whose representative left a new one (the median pitch).
    private static func tidy(_ db: Database, groupID: Int64) throws {
        let members = try Row.fetchAll(
            db, sql: "SELECT id, pitch FROM samples WHERE group_id = ? ORDER BY pitch, rel_path, id", arguments: [groupID])
        guard !members.isEmpty else {
            try db.execute(sql: "DELETE FROM sample_groups WHERE id = ?", arguments: [groupID])
            return
        }
        let current = try Int64.fetchOne(db, sql: "SELECT representative_id FROM sample_groups WHERE id = ?", arguments: [groupID])
        if let current, members.contains(where: { ($0["id"] as Int64) == current }) { return }
        let withPitch = members.filter { ($0["pitch"] as Int?) != nil }
        let pool = withPitch.isEmpty ? members : withPitch
        let representative: Int64 = pool[pool.count / 2]["id"]
        try db.execute(sql: "UPDATE sample_groups SET representative_id = ? WHERE id = ?", arguments: [representative, groupID])
    }
}
