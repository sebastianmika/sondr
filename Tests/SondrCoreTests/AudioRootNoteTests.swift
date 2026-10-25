import Foundation
import Testing

@testable import SondrCore

private func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
private func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
private func be32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }

private func chunk(_ id: String, _ body: Data, bigEndian: Bool = false) -> Data {
    var data = Data(id.utf8) + (bigEndian ? be32(UInt32(body.count)) : le32(UInt32(body.count))) + body
    if body.count % 2 == 1 { data.append(0) }
    return data
}

private func wav(extra: [Data]) -> Data {
    let format = chunk("fmt ", le16(1) + le16(1) + le32(8000) + le32(8000) + le16(1) + le16(8))
    let body = Data("WAVE".utf8) + format + chunk("data", Data(repeating: 128, count: 5)) + extra.reduce(Data(), +)
    return Data("RIFF".utf8) + le32(UInt32(body.count)) + body
}

private func write(_ data: Data, ext: String = "wav") throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
    try data.write(to: url)
    return url
}

@Test func readFindsSmplUnityNote() throws {
    let smpl = chunk("smpl", Data(count: 12) + le32(61) + Data(count: 20))
    let url = try write(wav(extra: [smpl]))
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(AudioRootNote.read(from: url) == 61)
}

@Test func readFallsBackToAcidThenInst() throws {
    let acid = chunk("acid", le32(0x02) + le16(55) + Data(count: 6))
    let inst = chunk("inst", Data([40, 0, 0, 127, 0, 127, 0]))
    let withAcid = try write(wav(extra: [inst, acid]))
    let withInst = try write(wav(extra: [inst]))
    defer { [withAcid, withInst].forEach { try? FileManager.default.removeItem(at: $0) } }
    #expect(AudioRootNote.read(from: withAcid) == 55)
    #expect(AudioRootNote.read(from: withInst) == 40)
}

@Test func readIgnoresAcidWithoutRootFlag() throws {
    let acid = chunk("acid", le32(0x01) + le16(55) + Data(count: 6))
    let url = try write(wav(extra: [acid]))
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(AudioRootNote.read(from: url) == nil)
}

@Test func readFindsAiffBaseNote() throws {
    let inst = chunk("INST", Data([62, 0, 0, 127, 0, 127]) + Data(count: 14), bigEndian: true)
    let body = Data("AIFF".utf8) + inst
    let url = try write(Data("FORM".utf8) + be32(UInt32(body.count)) + body, ext: "aif")
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(AudioRootNote.read(from: url) == 62)
}

@Test func readReturnsNilWithoutChunkOrForUnknownFiles() throws {
    let plain = try write(wav(extra: []))
    let junk = try write(Data("not audio at all".utf8))
    let truncated = try write(Data("RIFF".utf8) + le32(100) + Data("WAVE".utf8) + Data("smpl".utf8) + le32(60))
    defer { [plain, junk, truncated].forEach { try? FileManager.default.removeItem(at: $0) } }
    #expect(AudioRootNote.read(from: plain) == nil)
    #expect(AudioRootNote.read(from: junk) == nil)
    #expect(AudioRootNote.read(from: truncated) == nil)
    #expect(AudioRootNote.read(from: URL(fileURLWithPath: "/nonexistent.wav")) == nil)
}

@Test func pitchNumbersCollectsRootNotesAndKeyRange() throws {
    let smpl = chunk("smpl", Data(count: 12) + le32(48) + Data(count: 20))
    let inst = chunk("inst", Data([48, 0, 0, 45, 51, 0, 127]))
    let url = try write(wav(extra: [smpl, inst]))
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(AudioRootNote.pitchNumbers(from: url) == [48, 45, 51])
}

@Test func pitchNumbersIsEmptyWithoutChunksOrForOtherFiles() throws {
    let plain = try write(wav(extra: []))
    let junk = try write(Data("not audio at all".utf8))
    defer { [plain, junk].forEach { try? FileManager.default.removeItem(at: $0) } }
    #expect(AudioRootNote.pitchNumbers(from: plain).isEmpty)
    #expect(AudioRootNote.pitchNumbers(from: junk).isEmpty)
    #expect(AudioRootNote.pitchNumbers(from: URL(fileURLWithPath: "/nonexistent.wav")).isEmpty)
}

@Test func readStopsAtFirstNonPrintableChunkId() throws {
    let smpl = chunk("smpl", Data(count: 12) + le32(48) + Data(count: 20))
    let damaged = Data([0x01, 0x02, 0x03, 0x04]) + le32(0)
    let url = try write(wav(extra: [damaged, smpl]))
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(AudioRootNote.read(from: url) == nil)
}

@Test func readWalksAtMost64Chunks() throws {
    let smpl = chunk("smpl", Data(count: 12) + le32(48) + Data(count: 20))
    let filler = (0..<62).map { _ in chunk("junk", Data()) }  // fmt + data + 62 = 64 chunks
    let beyond = try write(wav(extra: filler + [smpl]))
    let within = try write(wav(extra: filler.dropLast() + [smpl]))
    defer { [beyond, within].forEach { try? FileManager.default.removeItem(at: $0) } }
    #expect(AudioRootNote.read(from: beyond) == nil)
    #expect(AudioRootNote.read(from: within) == 48)
}
