import Accelerate
import Foundation
import Testing

@testable import SondrCore

private let audioDir = "audio/"

/// How closely `ours` follows `reference`: relative RMS error at lag 0 and the lag
/// (in samples, within +-maxLag) at which the two correlate best.
private func compare(_ ours: [Float], _ reference: [Float], maxLag: Int = 1500)
    -> (relativeError: Float, bestLag: Int, countDiff: Int)
{
    let n = min(ours.count, reference.count)
    var diff = [Float](repeating: 0, count: n)
    vDSP_vsub(reference, 1, ours, 1, &diff, 1, vDSP_Length(n))
    let errRMS = vDSP.rootMeanSquare(diff)
    let refRMS = max(vDSP.rootMeanSquare(Array(reference.prefix(n))), 1e-12)

    var best = (lag: 0, score: -Float.infinity)
    let window = n - 2 * maxLag
    if window > 0 {
        for lag in -maxLag...maxLag {
            var dot: Float = 0
            ours.withUnsafeBufferPointer { a in
                reference.withUnsafeBufferPointer { b in
                    vDSP_dotpr(
                        a.baseAddress! + maxLag + lag, 1, b.baseAddress! + maxLag, 1, &dot,
                        vDSP_Length(window))
                }
            }
            if dot > best.score { best = (lag, dot) }
        }
    }
    return (errRMS / refRMS, best.lag, ours.count - reference.count)
}

/// Mean log-mel (dB) over time per mel bin: insensitive to small time shifts, close to what
/// the model sees. Final proof is the embedding parity test of Story 1.5.
private func spectralProfile(_ audio: [Float]) -> [Float] {
    let mel = ClapMelExtractor().features(for: audio)
    let bins = ClapMelExtractor.melBins
    let frames = mel.count / bins
    return (0..<bins).map { m in (0..<frames).map { mel[$0 * bins + m] }.reduce(0, +) / Float(frames) }
}

/// Mean absolute difference (dB) of the spectral profiles over bins where the reference is
/// audible (> -70 dB), or NaN if there is nothing to compare. Both signals are cut to the same
/// length, ending where the reference stops being active (> 1e-3), so that padding and a few
/// samples of codec delay do not change how much tiling and zero padding each side gets. Bins at
/// the floor are ignored: they hold resampler noise on synthetic pure tones, not signal.
private func profileDifference(_ ours: [Float], _ reference: [Float]) -> Float {
    let active = (reference.lastIndex { abs($0) > 1e-3 } ?? 0) + 1
    let n = min(ours.count, reference.count, active)
    let pa = spectralProfile(Array(ours.prefix(n)))
    let pb = spectralProfile(Array(reference.prefix(n)))
    let audible = zip(pa, pb).filter { $0.1 > -70 }
    guard !audible.isEmpty else { return .nan }
    return audible.map { abs($0.0 - $0.1) }.reduce(0, +) / Float(audible.count)
}

private func report(_ name: String, _ ours: [Float], _ reference: [Float]) {
    let r = compare(ours, reference)
    let profile = profileDifference(ours, reference)
    print(
        "decode \(name): rel.err \(r.relativeError), count diff \(r.countDiff), "
            + "spectral profile diff \(profile) dB")
}

/// Same rate as the model: decoding must be (nearly) bit exact.
@Test(arguments: [
    "bits24_kick.wav", "float32_snare.wav", "pluck.aif", "bass.caf", "loop_drums_90_stereo.wav",
    "loop_12s.flac",
])
func audioLoaderIsAlmostExactAt48kHz(name: String) throws {
    let reference = try Fixtures.npy("golden/decoded/\(name).npy").floats
    let ours = try AudioLoader.load(url: Fixtures.url(audioDir + name))
    report(name, ours, reference)
    #expect(ours.count == reference.count)
    #expect(compare(ours, reference).relativeError < 1e-4)
}

/// Lossless, other rates: resampler filters differ from librosa's soxr near the band edge.
@Test(arguments: [
    ("sr22050_pad.wav", Float(1e-4)), ("sr44100_sine.wav", 1e-4),
    ("sr96000_hat.wav", 0.3), ("stereo_44100_loop.flac", 0.1),
])
func audioLoaderResamplesLikeLibrosa(name: String, maxError: Float) throws {
    let reference = try Fixtures.npy("golden/decoded/\(name).npy").floats
    let ours = try AudioLoader.load(url: Fixtures.url(audioDir + name))
    report(name, ours, reference)
    #expect(abs(ours.count - reference.count) <= 2)
    #expect(compare(ours, reference).relativeError < maxError)
    let profile = profileDifference(ours, reference)
    #expect(profile < 0.5, "profile diff \(profile)")  // NaN (nothing compared) fails too
}

/// Lossy codecs: AVFoundation and libsndfile trim encoder delay differently (mp3 keeps ~1700
/// extra samples), so only the spectrum is compared.
@Test(arguments: ["lead.mp3", "pad.mp3", "pluck.m4a"])
func audioLoaderDecodesLossyFormatsWithSimilarSpectrum(name: String) throws {
    let reference = try Fixtures.npy("golden/decoded/\(name).npy").floats
    let ours = try AudioLoader.load(url: Fixtures.url(audioDir + name))
    report(name, ours, reference)
    #expect(abs(ours.count - reference.count) <= 2000)
    let profile = profileDifference(ours, reference)
    #expect(profile < 1.5, "profile diff \(profile)")  // NaN (nothing compared) fails too
}

@Test func audioLoaderOutputIsNormalisedAndBounded() throws {
    for name in ["sr44100_sine.wav", "loop_12s.flac", "edge_short_0p2s.wav", "lead.mp3"] {
        let audio = try AudioLoader.load(url: Fixtures.url(audioDir + name))
        let peak = audio.map(abs).max() ?? 0
        #expect(abs(peak - 1) < 1e-5, "\(name) peak \(peak)")
        #expect(audio.count >= 48_000 && audio.count <= 480_000, "\(name) count \(audio.count)")
    }
}

@Test func audioLoaderPadsShortFilesToOneSecond() throws {
    let audio = try AudioLoader.load(url: Fixtures.url(audioDir + "edge_very_short.wav"))
    #expect(audio.count == 48_000)
    #expect(audio.suffix(1000).allSatisfy { $0 == 0 })
}

@Test func audioLoaderCropsLongFilesToTenSeconds() throws {
    for name in ["loop_12s.flac", "loop_15s.flac"] {
        let audio = try AudioLoader.load(url: Fixtures.url(audioDir + name))
        #expect(audio.count == 480_000, "\(name)")
    }
}

@Test func audioLoaderKeepsSilenceAsSilence() throws {
    let audio = try AudioLoader.load(url: Fixtures.url(audioDir + "edge_silence.wav"))
    #expect(audio.count == 48_000)
    #expect(audio.allSatisfy { $0 == 0 })
}

@Test(arguments: ["truncated_header.wav", "not_audio.wav", "empty.wav"])
func audioLoaderThrowsOnCorruptFiles(name: String) {
    #expect(throws: AudioLoadError.self) {
        try AudioLoader.load(url: Fixtures.url(audioDir + "corrupt/" + name))
    }
}

@Test func audioLoaderThrowsOnMissingFile() {
    #expect(throws: AudioLoadError.self) {
        try AudioLoader.load(url: URL(fileURLWithPath: "/nonexistent/nope.wav"))
    }
}

@Test func audioLoaderDoesNotModifyTheFile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let copy = dir.appendingPathComponent("kick.wav")
    try FileManager.default.copyItem(at: Fixtures.url(audioDir + "kick_short.wav"), to: copy)

    let before = try FileManager.default.attributesOfItem(atPath: copy.path)
    let bytes = try Data(contentsOf: copy)
    _ = try AudioLoader.load(url: copy)

    let after = try FileManager.default.attributesOfItem(atPath: copy.path)
    #expect(after[.modificationDate] as? Date == before[.modificationDate] as? Date)
    #expect(after[.size] as? Int == before[.size] as? Int)
    #expect(try Data(contentsOf: copy) == bytes)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["kick.wav"])
}

@Test func mp3GaplessTagIsReadFromLameHeader() throws {
    let bytes = try Data(contentsOf: Fixtures.url(audioDir + "lead.mp3"))
    // ffmpeg/LAME: 576 samples encoder delay, 1152 samples padding.
    #expect(Mp3Gapless.parse(Array(bytes.prefix(4096))) == Mp3Gapless(startSkip: 576, endTrim: 1152))
    #expect(Mp3Gapless.read(from: Fixtures.url(audioDir + "kick_short.wav")) == nil)
    #expect(Mp3Gapless.parse([UInt8](repeating: 0, count: 100)) == nil)
}

@Test func mp3IsTrimmedToTheOriginalLength() throws {
    // lead.mp3 was encoded from exactly 1.5 s at 48 kHz.
    let audio = try AudioLoader.load(url: Fixtures.url(audioDir + "lead.mp3"))
    #expect(audio.count == 72_000)
}
