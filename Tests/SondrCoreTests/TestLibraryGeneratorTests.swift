import Foundation
import Testing

@testable import SondrCore

private let bigEnabled = ProcessInfo.processInfo.environment["SONDR_BENCH"] != nil

private func tempFolder() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("sondr-lib-\(UUID().uuidString)")
}

private func files(in root: URL) -> [String] {
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
    return enumerator.compactMap { ($0 as? URL).flatMap { $0.pathExtension == "wav" ? $0.path : nil } }
}

@Test func generatorWritesTheRequestedNumberOfDistinctFiles() throws {
    let root = tempFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    try TestLibraryGenerator.generate(count: 1000, into: root)

    let paths = files(in: root)
    #expect(paths.count == 1000)
    let hashes = Set(try paths.map { try LibraryScanner.sha256(of: URL(fileURLWithPath: $0)) })
    #expect(hashes.count == 1000)
    #expect(try Data(contentsOf: URL(fileURLWithPath: paths[0])).count == 44 + 400)
}

@Test func generatorOutputDependsOnlyOnCountAndSeed() throws {
    let a = tempFolder(), b = tempFolder(), c = tempFolder()
    defer { for url in [a, b, c] { try? FileManager.default.removeItem(at: url) } }
    try TestLibraryGenerator.generate(count: 50, into: a)
    try TestLibraryGenerator.generate(count: 50, into: b)
    try TestLibraryGenerator.generate(count: 50, into: c, seed: 2)

    func listing(_ root: URL) throws -> [String] {
        let real = LibraryScanner.realURL(root).path
        return try files(in: root).sorted().map {
            "\($0.dropFirst(real.count)) \(try LibraryScanner.sha256(of: URL(fileURLWithPath: $0)))"
        }
    }
    #expect(try listing(a) == listing(b))
    #expect(try listing(a) != listing(c))
}

@Test func scannerIndexesTheGeneratedLibraryWithoutErrors() async throws {
    let root = tempFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    try TestLibraryGenerator.generate(count: 1000, into: root)
    let database = try LibraryDatabase(inMemory: ())
    let summary = try await LibraryScanner(database: database).scan(root: root)
    #expect(summary.new == 1000)
    #expect(summary.errors == 0)
    #expect(summary.duplicate == 0)
}

@Test func generatedNamesYieldTags() throws {
    let tagger = try Tagger.bundled()
    let tags = tagger.tags(for: TestLibraryGenerator.relativePath(index: 7))
    #expect(tags.count >= 3)
}

/// `SONDR_BENCH=1 swift test -c release --filter largeGeneratedLibrary`
@Test(.enabled(if: bigEnabled, "set SONDR_BENCH=1"))
func largeGeneratedLibraryIsGeneratedAndScanned() async throws {
    let root = tempFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = ContinuousClock()
    let generate = try clock.measure { try TestLibraryGenerator.generate(count: 100_000, into: root) }
    let database = try LibraryDatabase(url: root.appendingPathComponent("../\(UUID().uuidString).sqlite"))
    let scanner = try LibraryScanner(database: database)
    var first = ScanSummary()
    let firstScan = try await clock.measure { first = try await scanner.scan(root: root) }
    var second = ScanSummary()
    let secondScan = try await clock.measure { second = try await scanner.scan(root: root) }
    print("100k library: generate \(generate), first scan \(firstScan), rescan \(secondScan)")
    #expect(first.new == 100_000 && first.errors == 0)
    #expect(second.skipped == 100_000 && second.hashed == 0)
}
