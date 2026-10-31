import AVFoundation
import Foundation
import Testing

@testable import SondrCore

@Suite struct EldrumExportTests {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eldrumexport-\(UUID().uuidString)")

    private func wav(_ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100.0, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1_000)!
        buffer.frameLength = 1_000
        try file.write(from: buffer)
        return url
    }

    @Test func writesMappingWavsAndSidecar() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let kick = try wav("Käse Kick.wav")
        var sources: [EldrumExport.Source?] = Array(repeating: nil, count: 8)
        sources[0] = .init(contentHash: "h1", path: kick.path)
        let eldrum = try EldrumExport.write(name: "My Kit", sources: sources, into: dir)

        let folder = eldrum.deletingLastPathComponent()
        #expect(folder.lastPathComponent == "My Kit")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("1_K_se Kick.wav").path))
        let kit = try EldrumKit.parse(String(contentsOf: eldrum, encoding: .utf8))
        #expect(kit.slots[0] == "1_K_se Kick.wav")
        #expect(kit.slots[1] == nil)
        let sidecar = try EldrumSidecar.decode(Data(contentsOf: EldrumSidecar.url(forEldrum: eldrum)))
        #expect(sidecar.slots == [.init(pad: 0, contentHash: "h1", originalPath: kick.path, filename: "1_K_se Kick.wav")])
    }

    @Test func existingFolderIsNotOverwritten() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sources: [EldrumExport.Source?] = Array(repeating: nil, count: 8)
        try EldrumExport.write(name: "Kit", sources: sources, into: dir)
        #expect(throws: EldrumExportError.self) { try EldrumExport.write(name: "Kit", sources: sources, into: dir) }
    }

    @Test func failedExportLeavesNoFolder() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var sources: [EldrumExport.Source?] = Array(repeating: nil, count: 8)
        sources[3] = .init(contentHash: "x", path: dir.appendingPathComponent("missing.wav").path)
        #expect(throws: (any Error).self) { try EldrumExport.write(name: "Kit", sources: sources, into: dir) }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Kit").path))
    }
}
