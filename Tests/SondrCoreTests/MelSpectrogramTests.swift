import Foundation
import Testing

@testable import SondrCore

private let melFixtures = [
    "edge_short_0p2s.wav",  // 1 s after padding: tiled 10x
    "kick_long_tail.wav",  // 1.2 s: tiled 8x then zero padded
    "sine_440.wav",
    "loop_drums_120.wav",
    "snare_basic.wav",
]

@Test(arguments: melFixtures)
func logMelMatchesHuggingFace(name: String) throws {
    let audio = try Fixtures.npy("golden/mel/\(name).audio.npy").floats
    let reference = try Fixtures.npy("golden/mel/\(name).features.npy")
    #expect(reference.shape == [1, 1, 1001, 64])

    let features = ClapMelExtractor().features(for: audio)
    #expect(features.count == 1001 * 64)

    let diffs = zip(features, reference.floats).map { abs($0 - $1) }
    let maxDiff = diffs.max() ?? .infinity
    let meanDiff = diffs.reduce(0, +) / Float(diffs.count)
    print("log-mel \(name): max abs diff \(maxDiff) dB, mean \(meanDiff) dB")
    #expect(maxDiff == 0)
}

@Test func logMelCropsAudioLongerThanWindow() throws {
    let long = (0..<(480_000 + 5_000)).map { Float(sin(Double($0) * 0.05)) }
    let extractor = ClapMelExtractor()
    #expect(extractor.features(for: long) == extractor.features(for: Array(long.prefix(480_000))))
}

@Test func logMelDiffersWhenAudioDiffers() throws {
    // Negative control: the parity check above must be able to fail.
    let audio = try Fixtures.npy("golden/mel/sine_440.wav.audio.npy").floats
    let reference = try Fixtures.npy("golden/mel/sine_440.wav.features.npy").floats
    let scaledNoise = audio.enumerated().map { $0.element + (($0.offset % 7 == 0) ? 0.01 : 0) }
    let features = ClapMelExtractor().features(for: scaledNoise)
    let maxDiff = zip(features, reference).map { abs($0 - $1) }.max() ?? 0
    #expect(maxDiff > 1)
}

@Test func logMelValuesAreInPlausibleRange() throws {
    let audio = try Fixtures.npy("golden/mel/sine_440.wav.audio.npy").floats
    let features = ClapMelExtractor().features(for: audio)
    print("sine_440 first values", features.prefix(4), "min", features.min()!, "max", features.max()!)
    #expect(features.min()! >= -100.0001)
    #expect(features.max()! > 0)
}

@Test func logMelSpeedIsReported() throws {
    let audio = try Fixtures.npy("golden/mel/loop_drums_120.wav.audio.npy").floats
    let extractor = ClapMelExtractor()
    _ = extractor.features(for: audio)
    let clock = ContinuousClock()
    let runs = 20
    let elapsed = clock.measure { for _ in 0..<runs { _ = extractor.features(for: audio) } }
    print("log-mel: \(elapsed / runs) per 10 s window (single thread)")
}
