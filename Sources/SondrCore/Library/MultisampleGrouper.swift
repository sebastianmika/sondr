import Foundation
import GRDB

/// Turns the groups that file names suggest (``MultisampleNames``) into stored multisample groups.
///
/// A candidate is accepted when file metadata backs the pitches (root notes agree with the names up to a
/// whole number of octaves), or, for note names without usable metadata, when the members sound alike.
/// Numbers in names are accepted only with metadata. Candidates whose members are not all indexed yet are
/// left for a later run. A run replaces all groups of one location, so it can be repeated at any time.
public enum MultisampleGrouper {
    /// Mean cosine similarity of members' embeddings needed to accept a group without metadata.
    /// Provisional; tune on a real library.
    public static let minimumSimilarity: Float = 0.8
    static let similaritySample = 16

    public struct Summary: Equatable, Sendable {
        public var groups = 0
        public var samples = 0
        public var rejected = 0
        /// Candidates left alone because some members are not indexed yet.
        public var deferred = 0
    }

    private struct Entry {
        let sampleID: Int64
        let path: String
        let relative: String
        let embedState: String
    }

    private enum Verdict { case accept, reject, later }

    @discardableResult
    public static func rebuild(database: LibraryDatabase, locationID: Int64) async throws -> Summary {
        let (root, rules, rows) = try await database.writer.read { db -> (String, MultisampleRules, [Entry]) in
            guard let root = try String.fetchOne(db, sql: "SELECT path FROM locations WHERE id = ?", arguments: [locationID])
            else { return ("", MultisampleRules(), []) }
            let rules = try MultisampleStore.load(db, locationID: locationID)
            let prefix = root.hasSuffix("/") ? root : root + "/"
            let rows = try GRDB.Row.fetchAll(
                db,
                sql: """
                    SELECT sample_paths.sample_id AS id, sample_paths.path AS path, samples.embed_state AS state
                    FROM sample_paths JOIN samples ON samples.id = sample_paths.sample_id
                    WHERE sample_paths.location_id = ? AND samples.missing = 0
                    ORDER BY sample_paths.path
                    """, arguments: [locationID]
            ).compactMap { row -> Entry? in
                let path: String = row["path"]
                guard path.hasPrefix(prefix) else { return nil }
                return Entry(sampleID: row["id"], path: path, relative: String(path.dropFirst(prefix.count)), embedState: row["state"])
            }
            return (root, rules, rows)
        }

        var byRelative: [String: Entry] = [:]
        for row in rows where byRelative[row.relative] == nil { byRelative[row.relative] = row }
        let allowed = byRelative.keys.filter { rules.allows(folder: ($0 as NSString).deletingLastPathComponent) }
        let candidates = MultisampleNames.groups(paths: Array(allowed)) {
            AudioRootNote.pitchNumbers(from: URL(fileURLWithPath: root).appendingPathComponent($0))
        }

        var summary = Summary()
        var accepted: [(MultisampleNames.Group, [Int64])] = []
        for group in candidates {
            let members = group.members.compactMap { byRelative[$0.path] }
            switch try await verdict(for: group, rows: members, root: root, database: database) {
            case .accept:
                accepted.append((withRootNotePitches(group, root: root), group.members.compactMap { byRelative[$0.path]?.sampleID }))
            case .reject: summary.rejected += 1
            case .later: summary.deferred += 1
            }
        }

        let stored = accepted
        let byID = Dictionary(rows.map { ($0.sampleID, $0) }, uniquingKeysWith: { first, _ in first })
        let written = try await database.writer.write { db -> (groups: Int, samples: Int) in
            var groups = 0, samples = 0
            // Manual groups stay as they are, and so do their members.
            try db.execute(
                sql: """
                    UPDATE samples SET group_id = NULL, pitch = NULL, pitch_label = NULL
                    WHERE group_id IN (SELECT id FROM sample_groups WHERE location_id = ? AND manual = 0)
                    """, arguments: [locationID])
            try db.execute(sql: "DELETE FROM sample_groups WHERE location_id = ? AND manual = 0", arguments: [locationID])
            try db.execute(
                sql: """
                    DELETE FROM sample_groups WHERE location_id = ? AND manual = 1
                        AND NOT EXISTS (SELECT 1 FROM samples WHERE group_id = sample_groups.id)
                    """, arguments: [locationID])
            var taken = Set(try Int64.fetchAll(
                db, sql: "SELECT samples.id FROM samples JOIN sample_groups ON sample_groups.id = samples.group_id WHERE sample_groups.location_id = ?",
                arguments: [locationID]))
            for (group, ids) in stored {
                let members = zip(group.members, ids).filter { taken.insert($1).inserted }
                guard Set(members.map { $0.0.midi }).count >= MultisampleNames.minimumPitches else { continue }
                let medianPitch = Array(Set(members.map { $0.0.midi })).sorted().medianValue
                guard let representative = members.first(where: { $0.0.midi == medianPitch })
                else { continue }
                let stem = ((byID[representative.1]?.path ?? "") as NSString).lastPathComponent as NSString
                try db.execute(
                    sql: "INSERT INTO sample_groups (location_id, folder, key, name, representative_id) VALUES (?, ?, ?, ?, ?)",
                    arguments: [locationID, group.folder, group.key, stem.deletingPathExtension, representative.1])
                let groupID = db.lastInsertedRowID
                for (member, id) in members {
                    try db.execute(
                        sql: "UPDATE samples SET group_id = ?, pitch = ?, pitch_label = ? WHERE id = ?",
                        arguments: [groupID, member.midi, member.label, id])
                }
                groups += 1
                samples += members.count
            }
            return (groups, samples)
        }
        summary.groups = written.groups
        summary.samples = written.samples
        return summary
    }

    /// A numbered group takes its pitches from the files' root notes: a pack that skips a number in its names
    /// still has consecutive notes. Left as named when a file has no root note.
    private static func withRootNotePitches(_ group: MultisampleNames.Group, root: String) -> MultisampleNames.Group {
        guard group.kind == .number else { return group }
        let base = URL(fileURLWithPath: root)
        let notes = group.members.map { AudioRootNote.read(from: base.appendingPathComponent($0.path)) }
        guard !notes.contains(where: { $0 == nil }) else { return group }
        let members = zip(group.members, notes).map { member, note in
            MultisampleNames.Member(path: member.path, midi: note!, layer: member.layer, label: member.label)
        }
        return MultisampleNames.Group(folder: group.folder, key: group.key, kind: group.kind, members: members)
    }

    private static func verdict(
        for group: MultisampleNames.Group, rows: [Entry], root: String, database: LibraryDatabase
    ) async throws -> Verdict {
        let notes = group.members.map { member in
            rows.first { $0.relative == member.path }.flatMap { AudioRootNote.read(from: URL(fileURLWithPath: $0.path)) }
        }
        if MultisampleNames.isBackedByMetadata(group, rootNotes: notes) { return .accept }
        guard group.kind == .note else { return .reject }
        if rows.contains(where: { $0.embedState == "pending" }) { return .later }

        let ids = rows.filter { $0.embedState == "done" }.map(\.sampleID)
        let vectors = try await database.writer.read { db in
            try ids.compactMap { id in
                try Data.fetchOne(db, sql: "SELECT vector FROM embeddings WHERE sample_id = ?", arguments: [id])
                    .flatMap(EmbeddingCodec.decode)
            }
        }
        guard vectors.count >= MultisampleNames.minimumPitches else { return .reject }
        return meanSimilarity(vectors) >= minimumSimilarity ? .accept : .reject
    }

    /// Mean pairwise dot product of unit vectors, over at most ``similaritySample`` evenly spaced ones.
    static func meanSimilarity(_ vectors: [[Float]]) -> Float {
        let step = max(1, vectors.count / similaritySample)
        let sample = stride(from: 0, to: vectors.count, by: step).map { vectors[$0] }
        var total: Float = 0
        var pairs = 0
        for i in 0..<sample.count {
            for j in (i + 1)..<sample.count {
                total += zip(sample[i], sample[j]).reduce(0) { $0 + $1.0 * $1.1 }
                pairs += 1
            }
        }
        return pairs == 0 ? 0 : total / Float(pairs)
    }
}

private extension Array where Element == Int {
    var medianValue: Int { self[count / 2] }
}
