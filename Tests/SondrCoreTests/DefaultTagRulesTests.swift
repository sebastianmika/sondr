import Testing

@testable import SondrCore

@Test(arguments: [
    "01", "7", "12", "12.", "01-02", "3.5", "1_2", "1-2-3", "f#", "c#", "c#3", "C#-3", "c3", "c-3", "eb2", "F#",
])
func defaultRulesBlock(tag: String) {
    #expect(DefaultTagRules.set.blocks(tag))
}

@Test(arguments: [
    "808", "909", "120", "2020", "am", "cm", "dm", "db", "ab", "bb", "90bpm-chop-bright", "punchy-02-120",
    "kick", "hi-hat", "e2e4", "h3",
])
func defaultRulesKeep(tag: String) {
    #expect(!DefaultTagRules.set.blocks(tag))
}

@Test func computerDropsDefaultTagsEvenWithoutAnyUserRule() throws {
    let computer = try TagComputer(tagger: Tagger.bundled(), settings: TaggingSettings())
    let tags = computer.tags(locationID: 1, rootPath: "/lib/Drums", path: "/lib/Drums/01 Kick 808.wav")
    #expect(tags.contains("kick") && tags.contains("808") && !tags.contains("01"))
}
