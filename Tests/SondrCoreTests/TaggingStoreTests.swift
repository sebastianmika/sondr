import GRDB
import Testing

@testable import SondrCore

@Test func settingsRoundTrip() throws {
    let database = try LibraryDatabase(inMemory: ())
    let rules = [TagRule(kind: .glob, pattern: "v*"), TagRule(kind: .regex, pattern: "a|b")]
    try database.writer.write { db in
        try db.execute(sql: "INSERT INTO locations (id, path, added_at) VALUES (1, '/lib/A', 0), (2, '/lib/B', 0)")
        try TaggingStore.saveGlobal(db, rules)
        try TaggingStore.save(db, locationID: 1, LocationTagging(extraTags: ["drumhaus", "live"], rules: rules))
    }
    let settings = try database.writer.read { try TaggingStore.load($0) }
    #expect(settings.global == rules)
    #expect(settings.locations[1] == LocationTagging(extraTags: ["drumhaus", "live"], rules: rules))
    #expect(settings.locations[2] == LocationTagging())
    let info = try database.writer.read { try LibraryInfo.locations($0) }
    #expect(info.first { $0.id == 1 }?.tagging.extraTags == ["drumhaus", "live"])
}

@Test func extraTagsAreNormalisedAndDeduplicatedWhenSaved() throws {
    let database = try LibraryDatabase(inMemory: ())
    try database.writer.write { db in
        try db.execute(sql: "INSERT INTO locations (id, path, added_at) VALUES (1, '/lib/A', 0)")
        try TaggingStore.save(db, locationID: 1, LocationTagging(extraTags: [" Live ", "live", "", "Warm"]))
    }
    let tagging = try database.writer.read { try TaggingStore.load($0) }.locations[1]
    #expect(tagging?.extraTags == ["live", "warm"])
}

@Test func invalidRulesAreNotSaved() throws {
    let database = try LibraryDatabase(inMemory: ())
    try database.writer.write { db in
        try db.execute(sql: "INSERT INTO locations (id, path, added_at) VALUES (1, '/lib/A', 0)")
    }
    #expect(throws: TagRuleError.self) {
        try database.writer.write { try TaggingStore.saveGlobal($0, [TagRule(kind: .regex, pattern: "(")]) }
    }
    #expect(throws: TagRuleError.self) {
        try database.writer.write {
            try TaggingStore.save($0, locationID: 1, LocationTagging(rules: [TagRule(kind: .text, pattern: " ")]))
        }
    }
}
