import AVFoundation
import Foundation

/// One line of file metadata: a stable key (`file.bitDepth`, `riff.smpl.rootNote`, ...) and the value as text.
public struct MetadataItem: Equatable, Sendable, Identifiable {
    public let key: String
    public let value: String
    public var id: String { key + "\u{0}" + value }
}

/// Everything we can tell about a file besides the audio itself: encoding details, file attributes,
/// tags AVFoundation reports (ID3, iTunes atoms, ...) and, for WAV, header chunks (see ``RiffMetadata``).
///
/// Read from the file on demand and never stored. Read-only: the file is not modified.
public enum AudioMetadata {
    /// Reads the metadata of one file.
    ///
    /// - Parameter url: Audio file readable by AVFoundation.
    /// - Returns: Technical items first, then embedded tags and chunks in file order. Empty if the file cannot be read.
    public static func read(url: URL) async -> [MetadataItem] {
        technical(url) + (await embedded(url)) + RiffMetadata.read(from: url)
    }

    private static func technical(_ url: URL) -> [MetadataItem] {
        var items: [MetadataItem] = []
        if let file = try? AVAudioFile(forReading: url) {
            let description = file.fileFormat.streamDescription.pointee
            if description.mBitsPerChannel > 0 {
                items.append(MetadataItem(key: "file.bitDepth", value: "\(description.mBitsPerChannel) bit"))
            }
            items.append(MetadataItem(key: "file.codec", value: fourCC(description.mFormatID)))
        }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
            if let size = attributes[.size] as? Int64 {
                items.append(
                    MetadataItem(key: "file.size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))
            }
            if let modified = attributes[.modificationDate] as? Date {
                items.append(MetadataItem(key: "file.modified", value: modified.formatted(date: .abbreviated, time: .shortened)))
            }
        }
        return items
    }

    private static func embedded(_ url: URL) async -> [MetadataItem] {
        let asset = AVURLAsset(url: url)
        var items: [MetadataItem] = []
        if let rate = try? await asset.load(.tracks).first?.load(.estimatedDataRate), rate > 0 {
            items.append(MetadataItem(key: "file.bitRate", value: "\(Int((rate / 1000).rounded())) kbit/s"))
        }
        guard let all = try? await asset.load(.metadata) else { return items }
        for item in all {
            let key = "avf." + (item.identifier?.rawValue ?? item.commonKey?.rawValue ?? item.key.map { "\($0)" } ?? "unknown")
            if let text = try? await item.load(.stringValue), !text.isEmpty {
                items.append(MetadataItem(key: key, value: text))
            } else if let number = try? await item.load(.numberValue) {
                items.append(MetadataItem(key: key, value: number.stringValue))
            } else if let data = try? await item.load(.dataValue) {
                items.append(MetadataItem(key: key, value: "\(data.count) bytes"))
            }
        }
        return items
    }

    private static func fourCC(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        let text = String(decoding: bytes, as: UTF8.self)
        return text.allSatisfy { $0.isASCII && !$0.isNewline } ? text.trimmingCharacters(in: .whitespaces) : "\(code)"
    }
}
