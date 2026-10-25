import Testing

@testable import SondrCore

private let defaultSet = try! TagRuleSet(DefaultTagRules.rules)

@Test(arguments: [
    "01", "7", "12", "12.", "01-02", "3.5", "1_2", "1-2-3", "f#", "c#", "c#3", "C#-3", "c3", "c-3", "eb2", "F#",
])
func defaultRulesBlock(tag: String) {
    #expect(defaultSet.blocks(tag))
}

@Test(arguments: [
    "808", "909", "120", "2020", "am", "cm", "dm", "db", "ab", "bb", "90bpm-chop-bright", "punchy-02-120",
    "kick", "hi-hat", "e2e4", "h3",
])
func defaultRulesKeep(tag: String) {
    #expect(!defaultSet.blocks(tag))
}

@Test func aNewLibraryStartsWithTheDefaultsAsOrdinaryGlobalRules() async throws {
    let database = try LibraryDatabase(inMemory: ())
    let loaded = try await database.writer.read { try TaggingStore.load($0) }
    #expect(loaded.global == DefaultTagRules.rules)

    let computer = try TagComputer(tagger: Tagger.bundled(), settings: loaded)
    let tags = computer.tags(locationID: 1, rootPath: "/lib/Drums", path: "/lib/Drums/01 Kick 808.wav")
    #expect(tags.contains("kick") && tags.contains("808") && !tags.contains("01"))
}

@Test func theDefaultsCanBeEditedOrDeletedAndStayThatWay() async throws {
    let database = try LibraryDatabase(inMemory: ())
    let edited = Array(DefaultTagRules.rules.dropFirst()) + [TagRule(kind: .text, pattern: "hard")]
    try await database.writer.write { try TaggingStore.saveGlobal($0, edited) }
    #expect(try await database.writer.read { try TaggingStore.load($0) }.global == edited)

    try await database.writer.write { try TaggingStore.saveGlobal($0, []) }
    #expect(try await database.writer.read { try TaggingStore.load($0) }.global.isEmpty)
}
