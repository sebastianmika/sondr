import AVFoundation
import Foundation
import Testing

@testable import SondrCore

@Suite struct TonverkWavTests {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tonverkwav-\(UUID().uuidString)")

    private func tone(_ name: String, rate: Double, bits: Int, float: Bool = false, channels: Int = 1, ext: String = "wav") throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).\(ext)")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: bits, AVLinearPCMIsFloatKey: float,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(rate / 2))!
        buffer.frameLength = buffer.frameCapacity
        for c in 0..<channels {
            for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![c][i] = 0.5 * sinf(Float(i) * 0.05) }
        }
        try file.write(from: buffer)
        return url
    }

    @Test func matchingFileIsCopiedByteForByte() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try tone("a", rate: 48_000, bits: 24)
        let out = dir.appendingPathComponent("out.wav")
        try TonverkWav.prepare(source: source, destination: out)
        #expect(try Data(contentsOf: out) == Data(contentsOf: source))
    }

    @Test(arguments: [(44_100.0, 16, false, 1), (96_000.0, 24, false, 2), (48_000.0, 16, false, 1)])
    func otherFormatsAreConverted(rate: Double, bits: Int, float: Bool, channels: Int) throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try tone("b", rate: rate, bits: bits, float: float, channels: channels)
        let out = dir.appendingPathComponent("out.wav")
        try TonverkWav.prepare(source: source, destination: out)
        let result = try AVAudioFile(forReading: out)
        #expect(TonverkWav.isTarget(result, url: out))
        #expect(Int(result.fileFormat.channelCount) == channels)
        #expect(abs(Double(result.length) - 24_000) < 100)  // half a second at 48 kHz
    }

    @Test func threeChannelsAreRejected() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try tone("c", rate: 48_000, bits: 24, channels: 3)
        #expect(throws: TonverkWavError.unsupportedChannels(3)) {
            try TonverkWav.prepare(source: source, destination: dir.appendingPathComponent("o.wav"))
        }
    }
}
