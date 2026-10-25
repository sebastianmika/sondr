import Foundation
import GRDB
import Testing

@testable import SondrCore

private let drums = "/lib/Drums"
private let loops = "/lib/Loops"

/// Two locations; sample 1 only in Drums, sample 2 in both (a duplicate file), sample 3 only in Loops.
private func makeLibrary() throws -> LibraryDatabase {
    let database = try LibraryDatabase(inMemory: ())
    try database.writer.write { db in
        for (id, path) in [(1, drums), (2, loops)] {
            try db.execute(
                sql: "INSERT INTO locations (id, path, added_at) VALUES (?, ?, 0)", arguments: [id, path])
        }
        let samples: [(Int64, [(Int64, String)])] = [
            (1, [(1, "\(drums)/Kicks/hard_kick_v2.wav")]),
            (2, [(1, "\(drums)/Snares/snare_v1.wav"), (2, "\(loops)/Backup/snare_v1.wav")]),
            (3, [(2, "\(loops)/Amen/break_90bpm.wav")]),
        ]
        for (id, paths) in samples {
            try db.execute(
                sql: """
                    INSERT INTO samples (id, content_hash, canonical_path, filename, rel_path, duration,
                        sample_rate, channels, format, file_size, file_mtime, scanned_at)
                    VALUES (?, ?, ?, 'x.wav', 'x.wav', 1, 48000, 1, 'wav', 1, 0, 0)
                    """, arguments: [id, "h\(id)", paths[0].1])
            for (location, path) in paths {
                try db.execute(
                    sql: "INSERT INTO sample_paths (sample_id, path, location_id) VALUES (?, ?, ?)",
                    arguments: [id, path, location])
            }
        }
    }
    return database
}

private let none = TaggingSettings()

private func tagging(_ build: (inout TaggingSettings) -> Void) -> TaggingSettings {
    var settings = TaggingSettings()
    build(&settings)
    return settings
}

private func apply(_ database: LibraryDatabase, _ settings: TaggingSettings) throws {
    let computer = try TagComputer(tagger: Tagger.bundled(), settings: settings)
    try database.writer.write { db in
        for id in try Int64.fetchAll(db, sql: "SELECT id FROM samples") {
            let tags = try TagRetag.tags(db, sampleID: id, computer: computer)
            try LibraryTags.applyAuto(db, sampleID: id, tags: tags)
        }
    }
}

private func retag(_ database: LibraryDatabase, from old: TaggingSettings, to new: TaggingSettings) throws {
    let tagger = try Tagger.bundled()
    try database.writer.write { db in
        let ids = try TagRetag.affectedSampleIDs(db, old: old, new: new)
        try TagRetag.retag(
            db, sampleIDs: ids, old: TagComputer(tagger: tagger, settings: old),
            new: TagComputer(tagger: tagger, settings: new))
    }
}

private func names(_ database: LibraryDatabase, _ id: Int64) throws -> [String] {
    try database.writer.read { try LibraryTags.names($0, sampleID: id) }
}

@Test func computerTagsPathBelowTheLocationAndAddsExtras() throws {
    let computer = try TagComputer(
        tagger: Tagger.bundled(),
        settings: tagging { $0.locations[1] = LocationTagging(extraTags: [" Drumhaus ", "Acoustic"]) })
    let tags = computer.tags(locationID: 1, rootPath: drums, path: "\(drums)/Kicks/hard_kick_v2.wav")
    #expect(tags.isSuperset(of: ["drum", "kick", "hard", "drumhaus", "acoustic"]))
    #expect(!tags.contains("lib"))
}

@Test func rulesFilterPathTagsButNotExtras() throws {
    let settings = tagging {
        $0.global = [TagRule(kind: .text, pattern: "hard")]
        $0.locations[1] = LocationTagging(extraTags: ["kite", "hard"], rules: [TagRule(kind: .glob, pattern: "k*")])
    }
    let computer = try TagComputer(tagger: Tagger.bundled(), settings: settings)
    let tags = computer.tags(locationID: 1, rootPath: drums, path: "\(drums)/Kicks/hard_kick_v2.wav")
    #expect(tags.contains("drum"))
    #expect(!tags.contains("kick"))  // location rule
    #expect(tags.contains("kite") && tags.contains("hard"))  // extras are never filtered
}

@Test func theRulesOfOneLocationDoNotApplyToAnother() throws {
    let settings = tagging { $0.locations[1] = LocationTagging(rules: [TagRule(kind: .text, pattern: "snare")]) }
    let computer = try TagComputer(tagger: Tagger.bundled(), settings: settings)
    #expect(!computer.tags(locationID: 1, rootPath: drums, path: "\(drums)/s/snare.wav").contains("snare"))
    #expect(computer.tags(locationID: 2, rootPath: loops, path: "\(loops)/s/snare.wav").contains("snare"))
}

@Test func changingExtrasAddsAndRemovesExactlyThoseTags() throws {
    let database = try makeLibrary()
    let before = tagging { $0.locations[1] = LocationTagging(extraTags: ["old"]) }
    let after = tagging { $0.locations[1] = LocationTagging(extraTags: ["new"]) }
    try apply(database, before)
    #expect(try names(database, 1).contains("old"))
    try retag(database, from: before, to: after)
    let one = try names(database, 1)
    #expect(one.contains("new") && !one.contains("old"))
    #expect(one.contains("kick"))  // untouched path tags stay
    #expect(try !names(database, 3).contains("new"))  // other location
    let tagNames = try database.writer.read { try String.fetchAll($0, sql: "SELECT name FROM tags") }
    #expect(!tagNames.contains("old"))  // pruned
}

@Test func blacklistingATagRemovesItAndLiftingItBringsItBack() throws {
    let database = try makeLibrary()
    let open = none
    let closed = tagging { $0.global = [TagRule(kind: .regex, pattern: "amen|hard")] }
    try apply(database, open)
    #expect(try names(database, 3).contains("amen"))
    try retag(database, from: open, to: closed)
    #expect(try !names(database, 3).contains("amen"))
    #expect(try !names(database, 1).contains("hard"))
    try retag(database, from: closed, to: open)
    #expect(try names(database, 3).contains("amen"))
    #expect(try names(database, 1).contains("hard"))
}

@Test func manualMergedRenamedAndRemovedTagsSurviveARetag() throws {
    let database = try makeLibrary()
    let before = tagging { $0.locations[1] = LocationTagging(extraTags: ["old"]) }
    let after = tagging {
        $0.global = [TagRule(kind: .text, pattern: "hard")]
        $0.locations[1] = LocationTagging(extraTags: ["new"])
    }
    try apply(database, before)
    try database.writer.write { db in
        try LibraryTags.add(db, sampleID: 1, name: "mine")
        try LibraryTags.rename(db, from: "kick", to: "bassdrum")  // auto row under a name the tagger never makes
        try LibraryTags.remove(db, sampleID: 2, name: "snare")  // sticky removal
        try LibraryTags.add(db, sampleID: 1, name: "hard")  // manual copy of a tag that gets blacklisted
    }
    try retag(database, from: before, to: after)
    let one = try names(database, 1)
    #expect(one.contains("mine"))
    #expect(one.contains("bassdrum"))
    #expect(one.contains("hard"))  // manual, so the blacklist does not remove it
    #expect(one.contains("new") && !one.contains("old"))
    #expect(try !names(database, 2).contains("snare"))
}

@Test func aSampleInTwoLocationsKeepsTagsOfTheOtherOne() throws {
    let database = try makeLibrary()
    let before = tagging {
        $0.locations[1] = LocationTagging(extraTags: ["shared"])
        $0.locations[2] = LocationTagging(extraTags: ["shared"])
    }
    let after = tagging { $0.locations[1] = LocationTagging(extraTags: ["shared"]) }
    try apply(database, before)
    try retag(database, from: before, to: after)
    #expect(try names(database, 2).contains("shared"))  // location 1 still gives it
    #expect(try !names(database, 3).contains("shared"))  // location 2 only
}

@Test func retaggingTwiceChangesNothing() throws {
    let database = try makeLibrary()
    let before = none
    let after = tagging {
        $0.global = [TagRule(kind: .glob, pattern: "?ard")]
        $0.locations[2] = LocationTagging(extraTags: ["loop"])
    }
    try apply(database, before)
    try retag(database, from: before, to: after)
    let first = try (1...3).map { try names(database, Int64($0)) }
    try retag(database, from: before, to: after)
    let second = try (1...3).map { try names(database, Int64($0)) }
    #expect(first == second)
}

@Test func onlySamplesOfChangedLocationsAreAffected() throws {
    let database = try makeLibrary()
    let after = tagging { $0.locations[2] = LocationTagging(extraTags: ["loop"]) }
    let ids = try database.writer.read { try TagRetag.affectedSampleIDs($0, old: none, new: after) }
    #expect(Set(ids) == [2, 3])
    let global = tagging { $0.global = [TagRule(kind: .text, pattern: "x")] }
    let all = try database.writer.read { try TagRetag.affectedSampleIDs($0, old: none, new: global) }
    #expect(Set(all) == [1, 2, 3])
    let same = try database.writer.read { try TagRetag.affectedSampleIDs($0, old: none, new: none) }
    #expect(same.isEmpty)
}

/// `SONDR_BENCH=1 swift test -c release --filter retagCost`: 250k samples, global rule change.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SONDR_BENCH"] != nil))
func retagCost() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("retag-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let database = try LibraryDatabase(url: url)
    let count = 250_000
    let folders = ["Kicks", "Snares", "Hats", "Pads/Warm", "Loops/Amen", "Vox/Chops", "FX/Risers"]
    try database.writer.write { db in
        try db.execute(sql: "INSERT INTO locations (id, path, added_at) VALUES (1, '/lib/Packs', 0)")
        for i in 1...count {
            let path = "/lib/Packs/Pack \(i % 400)/\(folders[i % folders.count])/hard_sound_\(i)_v\(i % 3)_\(80 + i % 90)bpm.wav"
            try db.execute(
                sql: """
                    INSERT INTO samples (id, content_hash, canonical_path, filename, rel_path, duration,
                        sample_rate, channels, format, file_size, file_mtime, scanned_at)
                    VALUES (?, ?, ?, 'x.wav', 'x.wav', 1, 48000, 1, 'wav', 1, 0, 0)
                    """, arguments: [i, "h\(i)", path])
            try db.execute(
                sql: "INSERT INTO sample_paths (sample_id, path, location_id) VALUES (?, ?, 1)", arguments: [i, path])
        }
    }
    let tagger = try Tagger.bundled()
    let old = TaggingSettings()
    let new = TaggingSettings(
        global: [TagRule(kind: .glob, pattern: "hard")], locations: [1: LocationTagging(extraTags: ["packs"])])
    let oldComputer = try TagComputer(tagger: tagger, settings: old)
    let newComputer = try TagComputer(tagger: tagger, settings: new)

    func timed(_ label: String, _ work: () throws -> Void) rethrows {
        let start = Date()
        try work()
        print("retag bench: \(label) \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
    }
    // Initial tagging, to have something to retag.
    try timed("initial tagging of \(count)") {
        for chunk in Array(1...count).map(Int64.init).chunked(500) {
            try database.writer.write { db in
                let entries = try TagRetag.entries(db, sampleIDs: chunk)
                for id in chunk {
                    let tags = (entries[id] ?? []).reduce(into: Set<String>()) {
                        $0.formUnion(oldComputer.tags(locationID: $1.locationID, rootPath: $1.rootPath, path: $1.path))
                    }
                    try LibraryTags.applyAuto(db, sampleID: id, tags: tags)
                }
            }
        }
    }
    try timed("retag of \(count)") {
        let ids = try database.writer.read { try TagRetag.affectedSampleIDs($0, old: old, new: new) }
        #expect(ids.count == count)
        for chunk in ids.chunked(500) {
            try database.writer.write { try TagRetag.retag($0, sampleIDs: chunk, old: oldComputer, new: newComputer) }
        }
    }
    let hard = try database.writer.read {
        try Int.fetchOne($0, sql: "SELECT count(*) FROM sample_tags JOIN tags ON tags.id = tag_id WHERE name = 'hard'")
    }
    #expect(hard == 0)
}
