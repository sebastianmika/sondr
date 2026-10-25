import Foundation
import Testing

@testable import SondrCore

private struct GoldenPath: Decodable {
    let path: String
    let tags: [String]
}

private func golden() throws -> [GoldenPath] {
    try JSONDecoder().decode([GoldenPath].self, from: Data(contentsOf: Fixtures.url("golden/tagger.json")))
}

@Test func taggerMatchesLegacyOnGoldenPaths() throws {
    let tagger = try Tagger.bundled()
    let cases = try golden()
    var different: [(String, Set<String>, Set<String>)] = []
    for item in cases {
        let ours = tagger.tags(for: item.path)
        if ours != Set(item.tags) { different.append((item.path, ours, Set(item.tags))) }
    }
    for (path, ours, expected) in different {
        print("  \(path)\n    only ours: \(ours.subtracting(expected).sorted())  only legacy: \(expected.subtracting(ours).sorted())")
    }
    #expect(different.isEmpty && cases.count == 200)
}

@Test func taggerReadsTheBundledAliasesAndStopwords() throws {
    let tagger = try Tagger.bundled()
    #expect(tagger.tags(for: "/Samples/Audio/Sounds/kick.wav") == ["kick"])
    #expect(tagger.tags(for: "/BassDrum/hardHit.wav") == ["kick", "bass", "drum", "hard", "hit"])
    #expect(tagger.tags(for: "/perc/hh_closed.wav") == ["percussion", "hi-hat", "closed"])
}

@Test(arguments: [
    ("kick.wav", "kick"), ("a.b.wav", "a.b"), (".hidden", ".hidden"), ("trailing.", "trailing."),
    ("noext", "noext"),
])
func stemFollowsPathlib(name: String, expected: String) {
    #expect(Tagger.stem(of: name) == expected)
}

@Test(arguments: [
    ("BassDrum", ["Bass", "Drum"]), ("808_Sub", ["808", "Sub"]), ("F1", ["F", "1"]),
    ("90bpm", ["90", "bpm"]), ("hi-hat", ["hi-hat"]), ("a b", ["a", "b"]),
])
func splitTokenSplitsLikeTheLegacyRegexes(text: String, expected: [String]) {
    #expect(Tagger.splitToken(text) == expected)
}

@Test(arguments: [
    ("kicks", "kick"), ("batteries", "battery"), ("boxes", "box"), ("glasses", "glass"),
    ("buses", "bus"), ("bass", "bass"), ("chorus", "chorus"), ("hats", "hat"), ("gas", "gas"),
    ("ass", "ass"),
])
func singulariserHandlesCommonPlurals(word: String, expected: String) {
    #expect(Singular.of(word) == expected)
}

@Test func taggerIgnoresEmptyPaths() throws {
    let tagger = try Tagger.bundled()
    #expect(tagger.tags(for: "").isEmpty)
    #expect(tagger.tags(for: "/").isEmpty)
}
