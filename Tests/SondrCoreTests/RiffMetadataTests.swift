import Foundation
import Testing

@testable import SondrCore

private func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
private func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

private func chunk(_ id: String, _ body: Data) -> Data {
    Data(id.utf8) + le32(UInt32(body.count)) + body + (body.count % 2 == 1 ? Data([0]) : Data())
}

private func wav(_ chunks: [Data]) throws -> URL {
    let format = chunk("fmt ", le16(1) + le16(1) + le32(8000) + le32(8000) + le16(1) + le16(8))
    let body = Data("WAVE".utf8) + format + chunk("data", Data(repeating: 128, count: 8)) + chunks.reduce(Data(), +)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
    try (Data("RIFF".utf8) + le32(UInt32(body.count)) + body).write(to: url)
    return url
}

private func read(_ chunks: [Data]) throws -> [String: String] {
    let url = try wav(chunks)
    defer { try? FileManager.default.removeItem(at: url) }
    return Dictionary(RiffMetadata.read(from: url).map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
}

@Test func readDecodesSmplRootNoteFineTuneAndLoop() throws {
    let loop = le32(0) + le32(0) + le32(100) + le32(900) + le32(0) + le32(0)
    let smpl = chunk(
        "smpl", le32(0) + le32(0) + le32(0) + le32(60) + le32(0x8000_0000) + le32(0) + le32(0) + le32(1) + le32(0) + loop)
    let values = try read([smpl])
    #expect(values["riff.smpl.rootNote"] == "C4 (60)")
    #expect(values["riff.smpl.fineTune"] == "50 cents")
    #expect(values["riff.smpl.loops"] == "1")
    #expect(values["riff.smpl.loop1"] == "100 – 900 frames")
}

@Test func readDecodesInstChunk() throws {
    let inst = chunk("inst", Data([48, 0xF6, 3, 36, 60, 1, 127]))
    let values = try read([inst])
    #expect(values["riff.inst.rootNote"] == "C3 (48)")
    #expect(values["riff.inst.fineTune"] == "-10 cents")
    #expect(values["riff.inst.gain"] == "3 dB")
    #expect(values["riff.inst.noteRange"] == "C2 (36) – C4 (60)")
    #expect(values["riff.inst.velocityRange"] == "1 – 127")
}

@Test func readDecodesBextAndSkipsEmptyFields() throws {
    var body = Data(count: 602)
    body.replaceSubrange(256..<266, with: Data("Logic Pro X".utf8.prefix(10)))
    body.replaceSubrange(320..<330, with: Data("2018-01-23".utf8))
    let values = try read([chunk("bext", body)])
    #expect(values["riff.bext.originator"] == "Logic Pro")
    #expect(values["riff.bext.originationDate"] == "2018-01-23")
    #expect(values["riff.bext.description"] == nil)
    #expect(values["riff.bext.timeReference"] == nil)
}

@Test func readDecodesCueCountAndMarkerLabels() throws {
    let label = chunk("labl", le32(1) + Data("Clap\0".utf8))
    let adtl = chunk("LIST", Data("adtl".utf8) + label)
    let values = try read([chunk("cue ", le32(1) + Data(count: 24)), adtl])
    #expect(values["riff.cue.count"] == "1")
    #expect(values["riff.adtl.labels"] == "Clap")
}

@Test func readListsUnknownChunksWithTheirSizeAndSkipsPadding() throws {
    let values = try read([chunk("FLLR", Data(count: 100)), chunk("AFAn", Data(count: 7))])
    #expect(values["riff.chunk.AFAn"] == "7 bytes")
    #expect(values["riff.chunk.FLLR"] == nil)
}

@Test func readStopsAtChunkIdThatIsNotText() throws {
    let garbage = Data([0xDE, 0xAD, 0xBE, 0xEF]) + le32(4) + Data(count: 4)
    let values = try read([chunk("inst", Data([48, 0, 0, 0, 127, 0, 127])), garbage])
    #expect(values["riff.inst.rootNote"] == "C3 (48)")
    #expect(values.keys.allSatisfy { !$0.hasPrefix("riff.chunk.") })
}

@Test func readReturnsNothingForNonWav() {
    #expect(RiffMetadata.read(from: Fixtures.url("audio/lead.mp3")).isEmpty)
}

@Test func splitOrdersMainByCatalogAndKeepsTheRestExtended() {
    let catalog = MetadataCatalog(main: [
        .init(key: "b", name: "Bee"), .init(key: "a", name: "Ay"),
    ])
    let items = [
        MetadataItem(key: "a", value: "1"), MetadataItem(key: "x", value: "2"), MetadataItem(key: "b", value: "3"),
    ]
    let result = catalog.split(items)
    #expect(result.main.map(\.name) == ["Bee", "Ay"])
    #expect(result.main.map(\.value) == ["3", "1"])
    #expect(result.extended == [MetadataItem(key: "x", value: "2")])
}

@Test func standardCatalogHasUniqueKeysAndNames() {
    let fields = MetadataCatalog.standard.main
    #expect(Set(fields.map(\.key)).count == fields.count)
    #expect(Set(fields.map(\.name)).count == fields.count)
}
