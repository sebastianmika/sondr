import Foundation
import GRDB
import Testing

@testable import SondrCore

private func vector() -> [Float] {
    var values = [Float](repeating: 0, count: EmbeddingService.embeddingSize)
    values[1] = 1
    return values
}

/// Location 1 at /lib with one sample per file (ids 1...), all embedded alike so note names group.
private func makeLibrary(files: [String]) throws -> LibraryDatabase {
    let database = try LibraryDatabase(inMemory: ())
    try database.writer.write { db in
        try db.execute(sql: "INSERT INTO locations (id, path, added_at) VALUES (1, '/lib', 0)")
        for (index, file) in files.enumerated() {
            let id = Int64(index + 1)
            try db.execute(
                sql: """
                    INSERT INTO samples (id, content_hash, canonical_path, filename, rel_path, duration,
                        sample_rate, channels, format, embed_state, file_size, file_mtime, scanned_at)
                    VALUES (?, ?, ?, ?, ?, 1, 48000, 1, 'wav', 'done', 1, 0, 0)
                    """, arguments: [id, "h\(id)", "/lib/\(file)", (file as NSString).lastPathComponent, file])
            try db.execute(
                sql: "INSERT INTO sample_paths (sample_id, path, location_id) VALUES (?, ?, 1)", arguments: [id, "/lib/\(file)"])
            try db.execute(
                sql: "INSERT INTO embeddings (sample_id, vector) VALUES (?, ?)", arguments: [id, EmbeddingCodec.encode(vector())])
        }
    }
    return database
}

private let keys = ["Keys/Piano_C3.wav", "Keys/Piano_E3.wav", "Keys/Piano_G3.wav", "Keys/Piano_C4.wav", "Keys/Piano_E4.wav"]
private let loose = ["Fx/Whoosh.wav", "Fx/Riser.wav", "Fx/Hit.wav"]

private func members(_ database: LibraryDatabase, _ groupID: Int64) throws -> [Int64] {
    try database.writer.read {
        try Int64.fetchAll($0, sql: "SELECT id FROM samples WHERE group_id = ? ORDER BY id", arguments: [groupID])
    }
}

private func groups(_ database: LibraryDatabase) async throws -> [MultisampleGroups.Info] {
    try await MultisampleGroups.list(database: database, locationID: 1)
}

@Test func createMakesAManualGroupWithPitchesFromTheNames() async throws {
    let database = try makeLibrary(files: keys + loose)
    let id = try await MultisampleGroups.create(database: database, locationID: 1, name: " Warm keys ", sampleIDs: [1, 3, 5, 6])
    #expect(try members(database, id) == [1, 3, 5, 6])
    let (name, manual, folder, key, representative) = try await database.writer.read { db -> (String, Int, String, String, Int64) in
        let row = try Row.fetchOne(db, sql: "SELECT * FROM sample_groups WHERE id = ?", arguments: [id])!
        return (row["name"], row["manual"], row["folder"], row["key"], row["representative_id"])
    }
    #expect(name == "Warm keys" && manual == 1 && folder == "" && key.hasPrefix("manual:"))
    // Pitches C3, G3, E4 and none for Whoosh: the median pitch is G3.
    #expect(representative == 3)
    let pitches = try await database.writer.read {
        try Int?.fetchAll($0, sql: "SELECT pitch FROM samples WHERE group_id = ? ORDER BY id", arguments: [id])
    }
    #expect(pitches == [48, 55, 64, nil])
    let info = try #require(try await groups(database).first)
    #expect(info == .init(id: id, name: "Warm keys", manual: true, representativeID: 3, size: 4, lowLabel: "C3", highLabel: "E4"))
}

@Test func createRejectsEmptyNameAndEmptySelection() async throws {
    let database = try makeLibrary(files: keys)
    await #expect(throws: MultisampleGroupError.emptyName) {
        try await MultisampleGroups.create(database: database, locationID: 1, name: "  ", sampleIDs: [1])
    }
    await #expect(throws: MultisampleGroupError.noSamples) {
        try await MultisampleGroups.create(database: database, locationID: 1, name: "x", sampleIDs: [])
    }
}

@Test func renameAddRemoveAndSetRepresentative() async throws {
    let database = try makeLibrary(files: keys + loose)
    let id = try await MultisampleGroups.create(database: database, locationID: 1, name: "A", sampleIDs: [1, 2, 3])
    try await MultisampleGroups.rename(database: database, groupID: id, name: "B")
    try await MultisampleGroups.addMembers(database: database, groupID: id, sampleIDs: [4, 6, 3])
    #expect(try members(database, id) == [1, 2, 3, 4, 6])

    try await MultisampleGroups.setRepresentative(database: database, groupID: id, sampleID: 6)
    await #expect(throws: MultisampleGroupError.notAMember) {
        try await MultisampleGroups.setRepresentative(database: database, groupID: id, sampleID: 5)
    }
    // Removing the representative picks a new one among the rest.
    try await MultisampleGroups.removeMembers(database: database, groupID: id, sampleIDs: [6, 1])
    #expect(try members(database, id) == [2, 3, 4])
    let info = try #require(try await groups(database).first)
    #expect(info.name == "B" && info.size == 3 && info.representativeID == 3)
    let removed = try await database.writer.read {
        try Int.fetchOne($0, sql: "SELECT count(*) FROM samples WHERE id = 1 AND group_id IS NULL AND pitch IS NULL")
    }
    #expect(removed == 1)
}

@Test func removingTheLastMemberDissolvesAndDeleteUngroups() async throws {
    let database = try makeLibrary(files: keys)
    let first = try await MultisampleGroups.create(database: database, locationID: 1, name: "A", sampleIDs: [1, 2])
    try await MultisampleGroups.removeMembers(database: database, groupID: first, sampleIDs: [1, 2])
    #expect(try await groups(database).isEmpty)

    let second = try await MultisampleGroups.create(database: database, locationID: 1, name: "B", sampleIDs: [3, 4])
    try await MultisampleGroups.delete(database: database, groupID: second)
    #expect(try await groups(database).isEmpty)
    let grouped = try await database.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM samples WHERE group_id IS NOT NULL") }
    #expect(grouped == 0)
}

@Test func movingASampleIntoAnotherGroupLeavesTheOldOneIntactOrDeletesIt() async throws {
    let database = try makeLibrary(files: keys)
    let one = try await MultisampleGroups.create(database: database, locationID: 1, name: "One", sampleIDs: [1, 2])
    let two = try await MultisampleGroups.create(database: database, locationID: 1, name: "Two", sampleIDs: [2, 3])
    #expect(try members(database, one) == [1])
    #expect(try members(database, two) == [2, 3])
    _ = try await MultisampleGroups.create(database: database, locationID: 1, name: "Three", sampleIDs: [1])
    #expect(try await groups(database).map(\.name) == ["Three", "Two"])
}

@Test func manualGroupSurvivesRebuildAndKeepsItsMembersOutOfAutoGroups() async throws {
    let database = try makeLibrary(files: keys)
    let manual = try await MultisampleGroups.create(database: database, locationID: 1, name: "Mine", sampleIDs: [1, 2])
    let summary = try await MultisampleGrouper.rebuild(database: database, locationID: 1)
    // Three piano files are left, which is enough for an automatic group of their own.
    #expect(summary.groups == 1 && summary.samples == 3)
    #expect(try members(database, manual) == [1, 2])
    #expect(try await groups(database).count == 2)
    // Running again changes nothing.
    _ = try await MultisampleGrouper.rebuild(database: database, locationID: 1)
    #expect(try members(database, manual) == [1, 2])
    #expect(try await groups(database).count == 2)
}

@Test func editingAnAutomaticGroupMakesItManualSoRebuildKeepsIt() async throws {
    let database = try makeLibrary(files: keys)
    #expect(try await MultisampleGrouper.rebuild(database: database, locationID: 1).groups == 1)
    let auto = try #require(try await groups(database).first)
    #expect(!auto.manual && auto.name == "Piano_G3")

    try await MultisampleGroups.rename(database: database, groupID: auto.id, name: "Grand")
    try await MultisampleGroups.removeMembers(database: database, groupID: auto.id, sampleIDs: [5])
    _ = try await MultisampleGrouper.rebuild(database: database, locationID: 1)
    let after = try await groups(database)
    #expect(after.count == 1 && after[0].id == auto.id && after[0].manual && after[0].name == "Grand")
    #expect(try members(database, auto.id) == [1, 2, 3, 4])
}

@Test func emptyManualGroupsAreDeletedByRebuild() async throws {
    let database = try makeLibrary(files: keys)
    try await database.writer.write {
        try $0.execute(sql: "INSERT INTO sample_groups (location_id, folder, key, name, manual) VALUES (1, '', 'manual:x', 'Empty', 1)")
    }
    _ = try await MultisampleGrouper.rebuild(database: database, locationID: 1)
    #expect(try await groups(database).map(\.name) == ["Piano_G3"])
}
