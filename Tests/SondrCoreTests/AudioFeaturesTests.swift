import Foundation
import Testing

@testable import SondrCore

private struct Manifest: Decodable {
    struct Entry: Decodable {
        let name: String
        let dims10s: [String: Double]
        enum CodingKeys: String, CodingKey { case name, dims10s = "dims_10s" }
    }
    let audio: [Entry]
}

@Test func rawDimsStayCloseToLegacyOnAllFixturesViaOurDecoder() throws {
    let manifest = try JSONDecoder().decode(
        Manifest.self, from: Data(contentsOf: Fixtures.url("golden/manifest.json")))
    var worst: (Double, String) = (0, "")
    for entry in manifest.audio {
        let audio = try AudioLoader.load(url: Fixtures.url("audio/\(entry.name)"))
        let dims = AudioFeatures.rawDims(
            audio: audio, sampleRate: 48000, duration: Double(audio.count) / 48000)
        for dim in Dim.allCases {
            let expected = entry.dims10s[dim.rawValue]!
            let relative = abs(dims[dim] - expected) / max(abs(expected), 1e-6)
            if relative > worst.0 { worst = (relative, "\(entry.name) \(dim)") }
            // Through our own decoder: files that are resampled or lossy differ a little from
            // librosa's decode (other resampler filter, codec noise floor), so allow 15%.
            #expect(
                relative < 0.15 || abs(dims[dim] - expected) < 1e-6,
                "\(entry.name) \(dim): \(dims[dim]) vs \(expected)")
        }
    }
    print("dims: worst relative difference \(worst.0) (\(worst.1)) over \(manifest.audio.count) files")
}

/// The algorithm alone: the reference decode of each file goes in, so decoder and resampler
/// differences cannot hide a bug. Must agree to 1e-3 relative.
@Test func rawDimsMatchLegacyOnReferenceDecodes() throws {
    let manifest = try JSONDecoder().decode(
        Manifest.self, from: Data(contentsOf: Fixtures.url("golden/manifest.json")))
    var checked = 0
    var worst: (Double, String) = (0, "")
    for entry in manifest.audio {
        guard FileManager.default.fileExists(atPath: Fixtures.url("golden/decoded/\(entry.name).npy").path)
        else { continue }
        let audio = try Fixtures.npy("golden/decoded/\(entry.name).npy").floats
        let dims = AudioFeatures.rawDims(
            audio: audio, sampleRate: 48000, duration: Double(audio.count) / 48000)
        checked += 1
        for dim in Dim.allCases {
            let expected = entry.dims10s[dim.rawValue]!
            let relative = abs(dims[dim] - expected) / max(abs(expected), 1e-6)
            if relative > worst.0 { worst = (relative, "\(entry.name) \(dim)") }
            #expect(relative < 1e-3 || abs(dims[dim] - expected) < 1e-6, "\(entry.name) \(dim): \(dims[dim]) vs \(expected)")
        }
    }
    print("dims on reference decodes: worst \(worst.0) (\(worst.1)) over \(checked) files")
    #expect(checked >= 10)
}

@Test func emptyAudioGivesZeroDims() {
    let dims = AudioFeatures.rawDims(audio: [], sampleRate: 48000, duration: 0)
    #expect(Dim.allCases.allSatisfy { dims[$0] == 0 })
}

@Test func durationDimIsCappedAtEightSeconds() {
    let silence = [Float](repeating: 0, count: 4800)
    #expect(AudioFeatures.rawDims(audio: silence, sampleRate: 48000, duration: 4)[.duration] == 0.5)
    #expect(AudioFeatures.rawDims(audio: silence, sampleRate: 48000, duration: 30)[.duration] == 1)
}

@Test func tinyClipsDoNotCrash() {
    for count in [1, 2, 100, 1023, 1024, 1025] {
        let audio = (0..<count).map { Float(sin(Double($0) * 0.3)) }
        let dims = AudioFeatures.rawDims(audio: audio, sampleRate: 48000, duration: Double(count) / 48000)
        #expect(Dim.allCases.allSatisfy { dims[$0].isFinite }, "count \(count)")
    }
}
