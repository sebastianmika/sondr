import Foundation
import GRDB
import Testing

@testable import SondrCore

/// A unit vector with weight on axis `main`, plus a little on `detail`.
private func vector(main: Int, detail: Int = 100) -> [Float] {
    var values = [Float](repeating: 0, count: EmbeddingService.embeddingSize)
    values[main] = 1
    values[detail] = 0.1
    let norm = values.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return values.map { $0 / norm }
}

/// Library with location 1 at /lib. Each file gets a sample; `sound(file)` picks its embedding axis.
private func makeLibrary(
    files: [String], state: (String) -> String = { _ in "done" }, sound: (String) -> Int
) throws -> LibraryDatabase {
    let database = try LibraryDatabase(inMemory: ())
    try database.writer.write { db in
        try db.execute(sql: "INSERT INTO locations (id, path, added_at) VALUES (1, '/lib', 0)")
        for (index, file) in files.enumerated() {
            let id = Int64(index + 1)
            try db.execute(
                sql: """
                    INSERT INTO samples (id, content_hash, canonical_path, filename, rel_path, duration,
                        sample_rate, channels, format, embed_state, file_size, file_mtime, scanned_at)
                    VALUES (?, ?, ?, ?, ?, 1, 48000, 1, 'wav', ?, 1, 0, 0)
                    """, arguments: [id, "h\(id)", "/lib/\(file)", file, file, state(file)])
            try db.execute(
                sql: "INSERT INTO sample_paths (sample_id, path, location_id) VALUES (?, ?, 1)", arguments: [id, "/lib/\(file)"])
            if state(file) == "done" {
                try db.execute(
                    sql: "INSERT INTO embeddings (sample_id, vector) VALUES (?, ?)",
                    arguments: [id, EmbeddingCodec.encode(vector(main: sound(file), detail: 100 + index))])
            }
        }
    }
    return database
}

private let piano = ["Keys/Piano_C3.wav", "Keys/Piano_E3.wav", "Keys/Piano_G3.wav", "Keys/Piano_C4.wav", "Keys/Piano_E4.wav"]

private func groupedSamples(_ database: LibraryDatabase) throws -> [(String, Int64?, Int?, String?)] {
    try database.writer.read { db in
        try Row.fetchAll(db, sql: "SELECT filename, group_id, pitch, pitch_label FROM samples ORDER BY id")
            .map { ($0["filename"], $0["group_id"], $0["pitch"], $0["pitch_label"]) }
    }
}

@Test func rebuildGroupsNoteNamesWhenTheMembersSoundAlike() async throws {
    let database = try makeLibrary(files: piano + ["Keys/Pad_C3.wav"], sound: { $0.contains("Piano") ? 1 : 2 })
    let summary = try await MultisampleGrouper.rebuild(database: database, locationID: 1)
    #expect(summary == .init(groups: 1, samples: 5, rejected: 0, deferred: 0))

    let rows = try groupedSamples(database)
    #expect(rows.prefix(5).allSatisfy { $0.1 != nil })
    #expect(rows.prefix(5).map { $0.3 } == ["C3", "E3", "G3", "C4", "E4"])
    #expect(rows.prefix(5).map { $0.2 } == [48, 52, 55, 60, 64])
    #expect(rows[5].1 == nil)
    let representative = try await database.writer.read {
        try Int64.fetchOne($0, sql: "SELECT representative_id FROM sample_groups")
    }
    #expect(representative == 3)
}

@Test func rebuildRejectsNoteNamesOnDifferentSounds() async throws {
    let database = try makeLibrary(files: piano, sound: { Int($0.dropFirst(11).prefix(1).utf8.first ?? 0) })
    let summary = try await MultisampleGrouper.rebuild(database: database, locationID: 1)
    #expect(summary.groups == 0)
    #expect(summary.rejected == 1)
    #expect(try groupedSamples(database).allSatisfy { $0.1 == nil })
}

@Test func rebuildLeavesGroupsWithUnindexedMembersForLater() async throws {
    let database = try makeLibrary(files: piano, state: { $0.hasSuffix("E4.wav") ? "pending" : "done" }, sound: { _ in 1 })
    let summary = try await MultisampleGrouper.rebuild(database: database, locationID: 1)
    #expect(summary == .init(groups: 0, samples: 0, rejected: 0, deferred: 1))
}

@Test func rebuildIgnoresNumbersWithoutMetadata() async throws {
    let numbers = (60..<65).map { "Keys/Piano_\($0).wav" }
    let database = try makeLibrary(files: numbers, sound: { _ in 1 })
    let summary = try await MultisampleGrouper.rebuild(database: database, locationID: 1)
    #expect(summary.groups == 0)
}

@Test func rebuildFollowsFolderRulesAndIsRepeatable() async throws {
    let drums = piano.map { $0.replacingOccurrences(of: "Keys", with: "Keys/Drums") }
    let database = try makeLibrary(files: piano + drums, sound: { _ in 1 })
    #expect(try await MultisampleGrouper.rebuild(database: database, locationID: 1).groups == 2)
    #expect(try await MultisampleGrouper.rebuild(database: database, locationID: 1).groups == 2)

    try await database.writer.write {
        try MultisampleStore.save($0, locationID: 1, MultisampleRules(overrides: [.init(folder: "Keys/Drums", group: false)]))
    }
    let summary = try await MultisampleGrouper.rebuild(database: database, locationID: 1)
    #expect(summary.groups == 1)
    let rows = try groupedSamples(database)
    #expect(rows.prefix(5).allSatisfy { $0.1 != nil })
    #expect(rows.suffix(5).allSatisfy { $0.1 == nil && $0.2 == nil })
}

@Test func metadataBackingNeedsVaryingRootNotesWithAConstantOctaveShift() throws {
    let group = try #require(MultisampleNames.groups(paths: ["P_C3.wav", "P_D3.wav", "P_E3.wav", "P_F3.wav"]).first)
    let names = group.members.map(\.midi)
    #expect(MultisampleNames.isBackedByMetadata(group, rootNotes: names.map { $0 }))
    #expect(MultisampleNames.isBackedByMetadata(group, rootNotes: names.map { $0 + 12 }))
    #expect(!MultisampleNames.isBackedByMetadata(group, rootNotes: names.map { _ in 0 }))
    #expect(!MultisampleNames.isBackedByMetadata(group, rootNotes: names.map { _ in nil }))
    #expect(!MultisampleNames.isBackedByMetadata(group, rootNotes: names.map { $0 + 1 }))
    #expect(!MultisampleNames.isBackedByMetadata(group, rootNotes: [names[0], nil, nil, nil]))
}

@Test func metadataBackingAcceptsNamesThatSkipANumber() throws {
    let paths = [70, 71, 72, 74, 75, 76].map { "Mono-\($0).wav" }
    let group = try #require(MultisampleNames.groups(paths: paths).first)
    #expect(MultisampleNames.isBackedByMetadata(group, rootNotes: [70, 71, 72, 73, 74, 75]))
    #expect(MultisampleNames.isBackedByMetadata(group, rootNotes: [58, 59, 60, 61, 62, 63]))
    // Notes that skip where the names do not, or fall out of order, are not backing.
    #expect(!MultisampleNames.isBackedByMetadata(group, rootNotes: [70, 71, 72, 75, 76, 77]))
    #expect(!MultisampleNames.isBackedByMetadata(group, rootNotes: [70, 72, 71, 73, 74, 75]))
    #expect(!MultisampleNames.isBackedByMetadata(group, rootNotes: [71, 72, 73, 74, 75, 76]))
}
