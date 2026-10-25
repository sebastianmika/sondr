import Foundation
import Testing

@testable import SondrCore

/// Empty files with audio extensions: the preview only looks at names.
private func makeTree(_ names: [String]) throws -> URL {
    let made = FileManager.default.temporaryDirectory.appendingPathComponent("sondr-preview-\(UUID().uuidString)")
    for name in names {
        let url = made.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }
    return LibraryScanner.realURL(made)
}

private let names = [
    "Kicks/Hard_Kick_01.wav", "Kicks/Soft_Kick_02.wav", "Snares/Hard_Snare.wav", "Loops/Amen_90bpm.flac",
    "notes.txt", ".hidden.wav",
]

@Test func previewCountsMatchTheTaggerOnTheSamePaths() async throws {
    let root = try makeTree(names)
    defer { try? FileManager.default.removeItem(at: root) }
    let tagger = try Tagger.bundled()
    let preview = try await TagPreview.scan(root: root, tagger: tagger)
    #expect(preview.fileCount == 4)

    var expected: [String: Int] = [:]
    for name in names.prefix(4) {
        for tag in tagger.tags(for: root.lastPathComponent + "/" + name) { expected[tag, default: 0] += 1 }
    }
    let rows = try preview.rows()
    #expect(Dictionary(uniqueKeysWithValues: rows.map { ($0.tag, $0.count) }) == expected)
    #expect(rows.first?.count == rows.map(\.count).max())  // most common first
    #expect(rows.allSatisfy { $0.example.hasSuffix(".wav") || $0.example.hasSuffix(".flac") })
}

@Test func rulesMarkRowsAndNameTheRuleWithoutWalkingAgain() async throws {
    let root = try makeTree(names)
    let preview = try await TagPreview.scan(root: root, tagger: Tagger.bundled())
    try FileManager.default.removeItem(at: root)  // the disk is not needed any more

    let global = TagRule(kind: .text, pattern: "hard")
    let local = TagRule(kind: .glob, pattern: "k*")
    let rows = try preview.rows(global: [global], location: [local])
    let byTag = Dictionary(uniqueKeysWithValues: rows.map { ($0.tag, $0) })
    #expect(byTag["hard"]?.blockedBy == global && byTag["hard"]?.isGlobal == true)
    #expect(byTag["kick"]?.blockedBy == local && byTag["kick"]?.isGlobal == false)
    #expect(byTag["snare"]?.blockedBy == nil)
    #expect(try preview.rows().allSatisfy { $0.blockedBy == nil })
}

@Test func invalidRulesThrow() async throws {
    let root = try makeTree(names)
    defer { try? FileManager.default.removeItem(at: root) }
    let preview = try await TagPreview.scan(root: root, tagger: Tagger.bundled())
    #expect(throws: TagRuleError.self) { try preview.rows(global: [TagRule(kind: .regex, pattern: "(")]) }
}

@Test func previewShowsDefaultIgnoredTagsAsSuchAndNotAsUserRules() async throws {
    let root = try makeTree(["Kicks/01 Kick 808.wav", "Kicks/02 Kick.wav"])
    defer { try? FileManager.default.removeItem(at: root) }
    let preview = try await TagPreview.scan(root: root, tagger: Tagger.bundled())
    let rows = try preview.rows(global: [TagRule(kind: .text, pattern: "01")])
    let byTag = Dictionary(uniqueKeysWithValues: rows.map { ($0.tag, $0) })
    #expect(byTag["01"]?.isDefault == true && byTag["01"]?.blockedBy == nil)
    #expect(byTag["02"]?.isDefault == true)
    #expect(byTag["808"]?.isDefault == false && byTag["kick"]?.isDefault == false)
}

@Test func aCancelledPreviewThrows() async throws {
    let root = try makeTree(names)
    defer { try? FileManager.default.removeItem(at: root) }
    let tagger = try Tagger.bundled()
    let task = Task { try await TagPreview.scan(root: root, tagger: tagger) }
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
}

@Test func missingFolderThrows() async throws {
    let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
    await #expect(throws: ScanError.self) { _ = try await TagPreview.scan(root: missing, tagger: Tagger.bundled()) }
}

@Test func matchCountTellsHowManyTagsARuleWouldHide() async throws {
    let root = try makeTree(names)
    defer { try? FileManager.default.removeItem(at: root) }
    let preview = try await TagPreview.scan(root: root, tagger: Tagger.bundled())
    let all = try preview.rows()
    let rule = TagRule(kind: .glob, pattern: "*a*")
    #expect(try preview.matchCount(of: rule) == all.filter { $0.tag.contains("a") }.count)
}

/// `SONDR_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter previewCost`
@Test(.enabled(if: ProcessInfo.processInfo.environment["SONDR_BENCH"] != nil))
func previewCost() async throws {
    let folders = ["Kicks", "Snares", "Hats", "Pads/Warm", "Loops/Amen", "Vox/Chops", "FX/Risers"]
    let made = FileManager.default.temporaryDirectory.appendingPathComponent("sondr-preview-bench-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: made) }
    for folder in folders { try FileManager.default.createDirectory(at: made.appendingPathComponent(folder), withIntermediateDirectories: true) }
    for i in 0..<100_000 {
        let name = "\(folders[i % folders.count])/hard_sound_\(i)_v\(i % 3)_\(80 + i % 90)bpm.wav"
        FileManager.default.createFile(atPath: made.appendingPathComponent(name).path, contents: nil)
    }
    let start = Date()
    let preview = try await TagPreview.scan(root: made, tagger: Tagger.bundled())
    print("preview bench: \(preview.fileCount) files in \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
    let rowsStart = Date()
    _ = try preview.rows(global: [TagRule(kind: .glob, pattern: "h*")])
    print("preview bench: rows in \(String(format: "%.3f", Date().timeIntervalSince(rowsStart))) s")
}
