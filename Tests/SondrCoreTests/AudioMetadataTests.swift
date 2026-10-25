import Foundation
import Testing

@testable import SondrCore

private func value(_ label: String, in items: [MetadataItem]) -> String? {
    items.first { $0.key == label }?.value
}

@Test func readReportsBitDepthAndCodecOfWav() async {
    let items = await AudioMetadata.read(url: Fixtures.url("audio/bits24_kick.wav"))
    #expect(value("file.bitDepth", in: items) == "24 bit")
    #expect(value("file.codec", in: items) == "lpcm")
    #expect(value("file.size", in: items) != nil)
}

@Test func readReportsBitRateOfMp3() async {
    let items = await AudioMetadata.read(url: Fixtures.url("audio/lead.mp3"))
    #expect(value("file.codec", in: items) == ".mp3")
    #expect(value("file.bitRate", in: items) != nil)
}

@Test func readReturnsNothingForUnreadableFile() async {
    let items = await AudioMetadata.read(url: Fixtures.url("audio/corrupt/not_audio.wav"))
    #expect(items.allSatisfy { ["file.size", "file.modified"].contains($0.key) })
}

@Test func readReturnsNothingForMissingFile() async {
    let items = await AudioMetadata.read(url: URL(fileURLWithPath: "/nonexistent/none.wav"))
    #expect(items.isEmpty)
}

private func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
private func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

@Test func readReturnsEmbeddedRiffInfoTags() async throws {
    let title = Data("Test Title\0\0".utf8)
    let info = Data("INFO".utf8) + Data("INAM".utf8) + le32(UInt32(title.count)) + title
    let format = Data("fmt ".utf8) + le32(16) + le16(1) + le16(1) + le32(8000) + le32(8000) + le16(1) + le16(8)
    let samples = Data(repeating: 128, count: 800)
    let body = Data("WAVE".utf8) + format + Data("data".utf8) + le32(UInt32(samples.count)) + samples
        + Data("LIST".utf8) + le32(UInt32(info.count)) + info
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
    try (Data("RIFF".utf8) + le32(UInt32(body.count)) + body).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let items = await AudioMetadata.read(url: url)
    #expect(items.contains { $0.value == "Test Title" })
}
