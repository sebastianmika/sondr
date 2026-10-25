import Foundation
import Testing

@testable import SondrCore

private struct GoldenQuery: Decodable, CustomTestStringConvertible {
    let query: String
    let input_ids: [Int32]
    let attention_mask: [Int32]

    var testDescription: String { "\"\(query.prefix(30))\"" }
}

private struct GoldenText: Decodable {
    let model_max_length: Int
    let queries: [GoldenQuery]
}

private func loadGolden() throws -> GoldenText {
    try JSONDecoder().decode(GoldenText.self, from: Data(contentsOf: Fixtures.url("golden/text.json")))
}

private let golden = (try? loadGolden())?.queries ?? []

@Test func goldenTextFixturesLoaded() throws {
    let text = try loadGolden()
    #expect(text.model_max_length == ClapTokenizer.maxLength)
    #expect(text.queries.count >= 25)
}

@Test(arguments: golden)
fileprivate func tokenizerMatchesHuggingFace(query: GoldenQuery) throws {
    let tokenizer = try ClapTokenizer.bundled()
    #expect(tokenizer.encode(query.query) == query.input_ids)
    #expect(query.attention_mask.allSatisfy { $0 == 1 })
}

@Test func tokenizerEmptyStringIsOnlySpecialTokens() throws {
    #expect(try ClapTokenizer.bundled().encode("") == [0, 2])
}

@Test func tokenizerTruncatesToMaxLengthKeepingEndToken() throws {
    let ids = try ClapTokenizer.bundled().encode(String(repeating: "snare ", count: 700))
    #expect(ids.count == ClapTokenizer.maxLength)
    #expect(ids.first == 0)
    #expect(ids.last == 2)
}

@Test func tokenizerThrowsWhenResourcesAreMissing() {
    let nowhere = URL(fileURLWithPath: "/nonexistent")
    #expect(throws: ClapTokenizerError.self) {
        try ClapTokenizer(vocabURL: nowhere, mergesURL: nowhere)
    }
}

@Test func tokenizerRejectsMalformedMerges() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data("{\"a\": 0}".utf8).write(to: dir.appendingPathComponent("vocab.json"))
    try Data("#version: 0.2\nonlyonecolumn\n".utf8).write(to: dir.appendingPathComponent("merges.txt"))
    #expect(throws: ClapTokenizerError.self) {
        try ClapTokenizer(
            vocabURL: dir.appendingPathComponent("vocab.json"),
            mergesURL: dir.appendingPathComponent("merges.txt"))
    }
}

@Test func tokenizerSpeedIsReported() throws {
    let clock = ContinuousClock()
    var tokenizer: ClapTokenizer?
    let load = try clock.measure { tokenizer = try ClapTokenizer.bundled() }
    let runs = 200
    let encode = clock.measure {
        for _ in 0..<runs { _ = tokenizer!.encode("punchy 808 kick drum with long reverb tail") }
    }
    print("tokenizer: load \(load), encode \(encode / runs) per query")
}
