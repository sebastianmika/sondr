import AVFoundation
import Foundation

/// Gets a sample into the Tonverk's safe format: 24-bit 48 kHz PCM WAV, mono or stereo.
public enum TonverkWav {
    public static let sampleRate = 48_000.0

    /// Copies `source` to `destination` if it already is 24-bit 48 kHz integer PCM WAV, else converts it.
    public static func prepare(source: URL, destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        guard (1...2).contains(input.fileFormat.channelCount) else {
            throw TonverkWavError.unsupportedChannels(Int(input.fileFormat.channelCount))
        }
        if isTarget(input, url: source) {
            try FileManager.default.copyItem(at: source, to: destination)
        } else {
            try convert(input, to: destination)
        }
    }

    static func isTarget(_ file: AVAudioFile, url: URL) -> Bool {
        let settings = file.fileFormat.settings
        return url.pathExtension.lowercased() == "wav"
            && file.fileFormat.sampleRate == sampleRate
            && settings[AVLinearPCMBitDepthKey] as? Int == 24
            && settings[AVLinearPCMIsFloatKey] as? Bool == false
    }

    private static func convert(_ input: AVAudioFile, to destination: URL) throws {
        let format = input.processingFormat
        let channels = format.channelCount
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false),
            let converter = AVAudioConverter(from: format, to: target),
            let inBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(input.length))
        else { throw TonverkWavError.conversionFailed }
        try input.read(into: inBuffer, frameCount: AVAudioFrameCount(input.length))

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let output = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let chunk = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 16_384) else { throw TonverkWavError.conversionFailed }
        var supplied = false
        // The converter hands back a bounded number of frames per call, so drain it until it reports the end.
        while true {
            var error: NSError?
            let status = converter.convert(to: chunk, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return inBuffer
            }
            if status == .error { throw error ?? TonverkWavError.conversionFailed }
            try output.write(from: chunk)
            if status == .endOfStream { break }
        }
    }
}

public enum TonverkWavError: Error, LocalizedError, Equatable {
    case unsupportedChannels(Int)
    case conversionFailed

    public var errorDescription: String? {
        switch self {
        case .unsupportedChannels(let count): return "Only mono and stereo samples fit a Tonverk pad (this has \(count) channels)."
        case .conversionFailed: return "The sample could not be converted to 24-bit 48 kHz WAV."
        }
    }
}
