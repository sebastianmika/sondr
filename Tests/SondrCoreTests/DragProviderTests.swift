import Foundation
import Testing

@testable import SondrCore

private func load(_ provider: NSItemProvider) async throws -> URL {
    try await withCheckedThrowingContinuation { cont in
        _ = provider.loadObject(ofClass: URL.self) { url, error in
            if let url { cont.resume(returning: url) } else { cont.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
        }
    }
}

private func makeFile(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try Data([0]).write(to: url)
    return url
}

@Test func dragProviderYieldsOriginalPathAndName() async throws {
    let file = try makeFile("Kick 01.wav")
    let provider = try #require(DragProvider.provider(path: file.path, missing: false))
    let url = try await load(provider)
    #expect(url.path == file.path)
    #expect(url.lastPathComponent == "Kick 01.wav")
    #expect(provider.suggestedName == "Kick 01.wav")
    #expect(provider.registeredTypeIdentifiers.contains("public.file-url"))
    #expect(!provider.hasItemConformingToTypeIdentifier("public.audio"))
}

@Test func dragProviderIsNilForMissingSample() throws {
    let file = try makeFile("a.wav")
    #expect(DragProvider.provider(path: file.path, missing: true) == nil)
    try FileManager.default.removeItem(at: file)
    #expect(DragProvider.provider(path: file.path, missing: false) == nil)
}

@Test func dragProvidersAreIndependent() async throws {
    let a = try makeFile("a.wav"), b = try makeFile("b.wav")
    let pa = try #require(DragProvider.provider(path: a.path, missing: false))
    let pb = try #require(DragProvider.provider(path: b.path, missing: false))
    #expect(try await load(pa).path == a.path)
    #expect(try await load(pb).path == b.path)
}
