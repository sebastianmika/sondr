import Accelerate
import Foundation

/// What the index job and cluster code need from the embedding model. ``EmbeddingService`` is the
/// real one; tests use stubs.
public protocol Embedder: Sendable {
    /// Identifies the model files; stored with the embeddings.
    func modelVersion() async throws -> String
    func embed(audio clips: [[Float]]) async throws -> [[Float]]
    func embed(text: String) async throws -> [Float]
}

extension EmbeddingService: Embedder {}

/// Embeddings are stored as little-endian Float16: half the size of Float32 (1 KiB per sample),
/// and the audio tower already runs in fp16, so nothing the model knows is lost.
public enum EmbeddingCodec {
    public static func encode(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * 2)
        for value in vector {
            withUnsafeBytes(of: Float16(value).bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Returns `nil` if `data` is not exactly `EmbeddingService.embeddingSize` half floats.
    public static func decode(_ data: Data) -> [Float]? {
        guard data.count == EmbeddingService.embeddingSize * 2 else { return nil }
        return data.withUnsafeBytes { raw in
            (0..<EmbeddingService.embeddingSize).map { i in
                Float(Float16(bitPattern: UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))))
            }
        }
    }

    /// Decodes into `destination` (512 Floats) without allocating. Returns false for bad input.
    public static func decode(_ data: Data, into destination: UnsafeMutablePointer<Float>) -> Bool {
        let count = EmbeddingService.embeddingSize
        guard data.count == count * 2 else { return false }
        data.withUnsafeBytes { raw in
            var source = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: raw.baseAddress!), height: 1, width: vImagePixelCount(count),
                rowBytes: count * 2)
            var target = vImage_Buffer(
                data: destination, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
            vImageConvert_Planar16FtoPlanarF(&source, &target, vImage_Flags(kvImageNoFlags))
        }
        return true
    }
}
