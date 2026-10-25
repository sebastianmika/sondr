import Foundation
import GRDB
import Testing

@testable import SondrCore

private func le(_ value: UInt32, bytes: Int) -> Data { Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }) }

private func chunk(_ id: String, _ body: Data) -> Data {
    Data(id.utf8) + le(UInt32(body.count), bytes: 4) + body + (body.count % 2 == 1 ? Data([0]) : Data())
}

/// A tiny 8-bit mono WAV; `note` adds a `smpl` chunk with that root note.
private func wav(note: Int?, samples: Int) -> Data {
    let format = chunk("fmt ", le(1, bytes: 2) + le(1, bytes: 2) + le(8000, bytes: 4) + le(8000, bytes: 4) + le(1, bytes: 2) + le(8, bytes: 2))
    let smpl = note.map { chunk("smpl", Data(count: 12) + le(UInt32($0), bytes: 4) + Data(count: 20)) } ?? Data()
    let body = Data("WAVE".utf8) + format + smpl + chunk("data", Data((0..<samples).map { UInt8($0 * 37 % 256) }))
    return Data("RIFF".utf8) + le(UInt32(body.count), bytes: 4) + body
}

@Test func scannerPitchLabelDisambiguatesClashingNamesByRootNote() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sondr-pitch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try wav(note: nil, samples: 400).write(to: root.appendingPathComponent("01 Kick.wav"))
    try wav(note: 48, samples: 500).write(to: root.appendingPathComponent("02 Kick.wav"))

    let database = try LibraryDatabase(inMemory: ())
    let scanner = try LibraryScanner(database: database, pitchLabel: MultisampleNames.scannerPitchLabel)
    _ = try await scanner.scan(root: LibraryScanner.realURL(root))

    let names = try await database.writer.read { try String.fetchAll($0, sql: "SELECT name FROM samples ORDER BY name") }
    #expect(names == ["Kick C3.wav", "Kick.wav"])
}

@Test func scannerPitchLabelIsNilWhenTheStemNamesAPitchOrThereIsNoNote() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
    try wav(note: 48, samples: 100).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(MultisampleNames.scannerPitchLabel("Kick", url) == "C3")
    #expect(MultisampleNames.scannerPitchLabel("Kick C4", url) == nil)
    #expect(MultisampleNames.scannerPitchLabel("Kick", URL(fileURLWithPath: "/nonexistent.wav")) == nil)
}
