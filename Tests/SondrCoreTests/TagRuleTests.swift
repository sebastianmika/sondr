import Foundation
import Testing

@testable import SondrCore

private func blocked(_ rule: TagRule, _ tag: String) throws -> Bool {
    try TagRuleSet([rule]).blocks(tag)
}

@Test(arguments: [
    (TagRule.Kind.text, "kick", "kick", true),
    (.text, "kick", "KICK", true),
    (.text, " Kick ", "kick", true),
    (.text, "kick", "kicks", false),
    (.glob, "v*", "v1", true),
    (.glob, "v*", "vox", true),
    (.glob, "v*", "kv", false),
    (.glob, "*bpm", "90bpm", true),
    (.glob, "k?ck", "kick", true),
    (.glob, "k?ck", "kck", false),
    (.glob, "a.b", "axb", false),
    (.glob, "a+b", "a+b", true),
    (.regex, "[0-9]+bpm", "90bpm", true),
    (.regex, "[0-9]+bpm", "x90bpm", false),
    (.regex, "kick|snare", "snare", true),
    (.regex, "kick|snare", "snares", false),
    (.regex, "KICK", "kick", true),
])
func ruleMatching(_ kind: TagRule.Kind, _ pattern: String, _ tag: String, _ expected: Bool) throws {
    #expect(try blocked(TagRule(kind: kind, pattern: pattern), tag) == expected)
}

@Test func invalidRegexIsRejectedWithAMessage() {
    let rule = TagRule(kind: .regex, pattern: "(unclosed")
    #expect(throws: TagRuleError.self) { try TagRuleSet([rule]) }
    #expect(rule.validationMessage != nil)
    #expect(TagRule(kind: .regex, pattern: "ok.*").validationMessage == nil)
}

@Test func emptyPatternIsRejected() {
    for kind in TagRule.Kind.allCases {
        #expect(TagRule(kind: kind, pattern: "  ").validationMessage != nil)
    }
}

@Test func ruleSetReportsTheFirstMatchingRule() throws {
    let first = TagRule(kind: .glob, pattern: "v*")
    let second = TagRule(kind: .text, pattern: "vox")
    let set = try TagRuleSet([first, second])
    #expect(set.firstMatch(for: "vox") == first)
    #expect(set.firstMatch(for: "kick") == nil)
    #expect(try TagRuleSet([]).blocks("anything") == false)
}

@Test func rulesRoundTripThroughJSON() throws {
    let rules = [TagRule(kind: .glob, pattern: "v*"), TagRule(kind: .regex, pattern: "a|b")]
    #expect(try TagRule.decode(TagRule.encode(rules)) == rules)
    #expect(try TagRule.decode(nil) == [])
}
