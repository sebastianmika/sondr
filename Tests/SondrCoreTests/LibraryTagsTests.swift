import GRDB
import Testing

@testable import SondrCore

private func makeSample(_ db: Database, hash: String = "h") throws -> Int64 {
    try db.execute(
        sql: """
            INSERT INTO samples (content_hash, canonical_path, filename, rel_path, duration,
                sample_rate, channels, format, file_size, file_mtime, scanned_at)
            VALUES (?, '/a.wav', 'a.wav', 'a.wav', 1, 48000, 1, 'wav', 1, 0, 0)
            """, arguments: [hash])
    return db.lastInsertedRowID
}

@Test func removedAutoTagStaysRemoved() throws {
    let database = try LibraryDatabase(inMemory: ())
    let names = try database.writer.write { db -> [String] in
        let id = try makeSample(db)
        try LibraryTags.applyAuto(db, sampleID: id, tags: ["kick", "drum"])
        try LibraryTags.remove(db, sampleID: id, name: "drum")
        try LibraryTags.applyAuto(db, sampleID: id, tags: ["kick", "drum", "hard"])
        return try LibraryTags.names(db, sampleID: id)
    }
    #expect(names == ["hard", "kick"])
}

@Test func removingAManualTagIsNotRemembered() throws {
    let database = try LibraryDatabase(inMemory: ())
    let names = try database.writer.write { db -> [String] in
        let id = try makeSample(db)
        try LibraryTags.add(db, sampleID: id, name: "mine")
        try LibraryTags.remove(db, sampleID: id, name: "mine")
        try LibraryTags.applyAuto(db, sampleID: id, tags: ["mine"])
        return try LibraryTags.names(db, sampleID: id)
    }
    #expect(names == ["mine"])
}

@Test func addingTagBackLiftsTheRemoval() throws {
    let database = try LibraryDatabase(inMemory: ())
    let source = try database.writer.write { db -> String? in
        let id = try makeSample(db)
        try LibraryTags.applyAuto(db, sampleID: id, tags: ["kick"])
        try LibraryTags.remove(db, sampleID: id, name: "kick")
        try LibraryTags.add(db, sampleID: id, name: "kick")
        try LibraryTags.applyAuto(db, sampleID: id, tags: ["kick"])
        return try String.fetchOne(db, sql: "SELECT source FROM sample_tags")
    }
    #expect(source == "manual")
}

@Test func applyingAutoTagsDoesNotDemoteManualOnes() throws {
    let database = try LibraryDatabase(inMemory: ())
    let sources = try database.writer.write { db -> [String] in
        let id = try makeSample(db)
        try LibraryTags.add(db, sampleID: id, name: "kick")
        try LibraryTags.applyAuto(db, sampleID: id, tags: ["kick"])
        return try String.fetchAll(db, sql: "SELECT source FROM sample_tags")
    }
    #expect(sources == ["manual"])
}

@Test func removingAnUnknownTagDoesNothing() throws {
    let database = try LibraryDatabase(inMemory: ())
    try database.writer.write { db in
        let id = try makeSample(db)
        try LibraryTags.remove(db, sampleID: id, name: "nope")
        try LibraryTags.applyAuto(db, sampleID: id, tags: ["a1"])
        try LibraryTags.remove(db, sampleID: id, name: "other")
    }
}

// MARK: Editing (Story 6.1)

private func rowsOf(_ db: Database, _ name: String) throws -> [[String]] {
    try Row.fetchAll(
        db,
        sql: """
            SELECT sample_id, source FROM sample_tags JOIN tags ON tags.id = tag_id WHERE tags.name = ? ORDER BY sample_id
            """, arguments: [name]
    ).map { ["\($0["sample_id"] as Int64)", $0["source"]] }
}

private func tagNames(_ db: Database) throws -> [String] {
    try String.fetchAll(db, sql: "SELECT name FROM tags ORDER BY name")
}

@Test func bulkAddOfAThousandSamplesIsOneTransaction() throws {
    let database = try LibraryDatabase(inMemory: ())
    let (commits, count) = try database.writer.write { db -> (Int, Int) in
        var ids: [Int64] = []
        for i in 0..<1000 { ids.append(try makeSample(db, hash: "h\(i)")) }
        var statements: [String] = []
        db.trace { statements.append($0.description) }
        try LibraryTags.add(db, sampleIDs: ids, name: "  Punchy ")
        let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM sample_tags WHERE source = 'manual'")!
        return (statements.filter { $0.hasPrefix("COMMIT") }.count, count)
    }
    #expect(count == 1000)
    #expect(commits == 0)  // inside one write transaction: nothing committed until the closure ends
    #expect(try database.writer.read { try tagNames($0) } == ["punchy"])  // normalised
}

@Test func bulkRemoveWritesRemovalsOnlyForAutoTagsAndPrunesEmptyTags() throws {
    let database = try LibraryDatabase(inMemory: ())
    try database.writer.write { db in
        let a = try makeSample(db, hash: "a"), b = try makeSample(db, hash: "b")
        try LibraryTags.applyAuto(db, sampleID: a, tags: ["kick", "drum"])
        try LibraryTags.add(db, sampleID: b, name: "kick")
        try LibraryTags.add(db, sampleID: b, name: "mine")
        try LibraryTags.remove(db, sampleIDs: [a, b], name: "kick")
        try LibraryTags.remove(db, sampleIDs: [b], name: "mine")

        #expect(try rowsOf(db, "kick").isEmpty)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM removed_auto_tags") == 1)  // only a's auto kick
        #expect(try tagNames(db) == ["drum", "kick"])  // "mine" is gone, "kick" stays for the removal marker
        try LibraryTags.applyAuto(db, sampleID: a, tags: ["kick"])
        #expect(try rowsOf(db, "kick").isEmpty)  // stays removed
    }
}

@Test func mergeMovesUsesWithoutDuplicatesAndKeepsManualOwnership() throws {
    let database = try LibraryDatabase(inMemory: ())
    try database.writer.write { db in
        let a = try makeSample(db, hash: "a"), b = try makeSample(db, hash: "b"), c = try makeSample(db, hash: "c")
        try LibraryTags.applyAuto(db, sampleID: a, tags: ["kik", "kick"])  // has both
        try LibraryTags.applyAuto(db, sampleID: b, tags: ["kik"])
        try LibraryTags.add(db, sampleID: c, name: "kik")  // manual source tag
        try LibraryTags.add(db, sampleID: c, name: "kick")  // and the target
        try LibraryTags.merge(db, source: "kik", into: "kick")

        #expect(try rowsOf(db, "kick") == [["1", "auto"], ["2", "auto"], ["3", "manual"]])
        #expect(try rowsOf(db, "kik").isEmpty)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM (SELECT sample_id, tag_id FROM sample_tags GROUP BY 1, 2 HAVING count(*) > 1)") == 0)
        // the auto uses of the old name are remembered as removed, so a rescan does not bring them back
        try LibraryTags.applyAuto(db, sampleID: b, tags: ["kik"])
        #expect(try rowsOf(db, "kik").isEmpty)
    }
}

@Test func mergeIntoANewNameAndSelfMerge() throws {
    let database = try LibraryDatabase(inMemory: ())
    try database.writer.write { db in
        let a = try makeSample(db)
        try LibraryTags.add(db, sampleID: a, name: "old")
        try LibraryTags.merge(db, source: "old", into: "old")  // no-op
        #expect(try rowsOf(db, "old") == [["1", "manual"]])
        try LibraryTags.merge(db, source: "old", into: " NEW ")
        #expect(try rowsOf(db, "new") == [["1", "manual"]])
        #expect(try tagNames(db) == ["new"])
    }
}

@Test func mergingRespectsAnEarlierRemovalOfTheTargetOnThatSample() throws {
    let database = try LibraryDatabase(inMemory: ())
    try database.writer.write { db in
        let a = try makeSample(db)
        try LibraryTags.applyAuto(db, sampleID: a, tags: ["kik", "kick"])
        try LibraryTags.remove(db, sampleID: a, name: "kick")  // user does not want "kick" here
        try LibraryTags.merge(db, source: "kik", into: "kick")
        #expect(try rowsOf(db, "kick").isEmpty)
    }
}

@Test func renameWorksAndReportsConflictsAndUnknownNames() throws {
    let database = try LibraryDatabase(inMemory: ())
    try database.writer.write { db in
        let a = try makeSample(db)
        try LibraryTags.add(db, sampleID: a, name: "one")
        try LibraryTags.add(db, sampleID: a, name: "two")
        try LibraryTags.rename(db, from: "one", to: "uno")
        #expect(try tagNames(db) == ["two", "uno"])
        #expect(throws: TagError.nameTaken("two")) { try LibraryTags.rename(db, from: "uno", to: "Two") }
        #expect(throws: TagError.notFound("zzz")) { try LibraryTags.rename(db, from: "zzz", to: "x") }
        #expect(throws: TagError.invalidName) { try LibraryTags.rename(db, from: "uno", to: "  ") }
        try LibraryTags.rename(db, from: "uno", to: "uno")  // same name: nothing happens
        #expect(try tagNames(db) == ["two", "uno"])
    }
}

@Test func deleteRemovesTheTagEverywhereAndKeepsAutoRemovalsSticky() throws {
    let database = try LibraryDatabase(inMemory: ())
    try database.writer.write { db in
        let a = try makeSample(db, hash: "a"), b = try makeSample(db, hash: "b")
        try LibraryTags.applyAuto(db, sampleID: a, tags: ["noise", "kick"])
        try LibraryTags.add(db, sampleID: b, name: "noise")
        try LibraryTags.delete(db, name: "noise")

        #expect(try LibraryTags.names(db, sampleID: a) == ["kick"])
        #expect(try LibraryTags.names(db, sampleID: b).isEmpty)
        try LibraryTags.applyAuto(db, sampleID: a, tags: ["noise"])
        #expect(try LibraryTags.names(db, sampleID: a) == ["kick"])  // not resurrected for a
        #expect(throws: TagError.notFound("nope")) { try LibraryTags.delete(db, name: "nope") }
    }
}

@Test func deletingASampleLeavesNoDanglingTagRows() throws {
    let database = try LibraryDatabase(inMemory: ())
    try database.writer.write { db in
        let a = try makeSample(db)
        try LibraryTags.applyAuto(db, sampleID: a, tags: ["kick"])
        try db.execute(sql: "DELETE FROM samples")
        try LibraryTags.pruneUnused(db)
        #expect(try tagNames(db).isEmpty)
    }
}

/// 200 samples in location 1: "common" on all, "some" on 3, "once" on 1, "extra" on 1, "manual" (by hand) on 1.
private func rareTagsLibrary() throws -> LibraryDatabase {
    let database = try LibraryDatabase(inMemory: ())
    try database.writer.write { db in
        try db.execute(sql: "INSERT INTO locations (id, path, added_at) VALUES (1, '/lib', 0)")
        for i in 0..<200 {
            let id = try makeSample(db, hash: "h\(i)")
            try db.execute(sql: "INSERT INTO sample_paths (sample_id, path, location_id) VALUES (?, ?, 1)", arguments: [id, "/lib/\(i).wav"])
            var tags: Set<String> = ["common"]
            if i < 3 { tags.insert("some") }
            if i == 0 { tags.formUnion(["once", "extra"]) }
            try LibraryTags.applyAuto(db, sampleID: id, tags: tags)
            if i == 1 { try LibraryTags.add(db, sampleID: id, name: "manual") }
        }
    }
    return database
}

private func allTagNames(_ database: LibraryDatabase) throws -> [String] {
    try database.writer.read { try String.fetchAll($0, sql: "SELECT name FROM tags WHERE id IN (SELECT tag_id FROM sample_tags) ORDER BY name") }
}

@Test func dropRareRemovesTagsUsedByFewSamplesAndKeepsExtrasAndManualTags() throws {
    let database = try rareTagsLibrary()
    let dropped = try database.writer.write { try LibraryTags.dropRare($0, locationID: 1, upTo: 1, keeping: ["extra"]) }

    // "once" has 1 sample, "some" has 3 of 200 (1.5%, above 1%).
    #expect(dropped == 1)
    #expect(try allTagNames(database) == ["common", "extra", "manual", "some"])
}

@Test func dropRareAlsoDropsTagsUnderOnePercent() throws {
    let database = try rareTagsLibrary()
    try database.writer.write { try LibraryTags.dropRare($0, locationID: 1, upTo: 0, keeping: ["extra"]) }

    // With no count limit, only the 1% rule applies: "once" (0.5%) goes, "some" (1.5%) stays.
    #expect(try allTagNames(database) == ["common", "extra", "manual", "some"])
    try database.writer.write { try LibraryTags.dropRare($0, locationID: 1, upTo: 3) }
    #expect(try allTagNames(database) == ["common", "manual"])
}

@Test func dropRareTagsDoNotComeBackOnRescan() throws {
    let database = try rareTagsLibrary()
    try database.writer.write { db in
        try LibraryTags.dropRare(db, locationID: 1, upTo: 1)
        let first = try Int64.fetchOne(db, sql: "SELECT id FROM samples ORDER BY id LIMIT 1")!
        try LibraryTags.applyAuto(db, sampleID: first, tags: ["common", "once"])
    }
    #expect(try !allTagNames(database).contains("once"))
}
