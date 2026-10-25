import Foundation
import GRDB

/// Tells the pitch label (`C3`) of a file's root note for name disambiguation, or `nil` when the
/// stem already names a pitch or the file has no root note. Wired up by the multisample code.
public typealias PitchLabel = @Sendable (_ stem: String, _ url: URL) -> String?

/// The name shown for a file (`samples.name`).
enum SampleName {
    private static let leadingNumber = try! NSRegularExpression(pattern: "^([0-9]+)(?:[ _-]+|\\.(?=\\D))")  // swiftlint:disable:this force_try

    /// The file name without a leading track number (`01 Kick.wav` is `Kick.wav`).
    ///
    /// When another sample in the same folder already has that name, the root note from `pitchLabel`
    /// is appended (`Kick C3.wav`). If that is taken too, or there is no pitch, the removed number is
    /// appended (`Kick 01.wav`).
    static func display(
        _ db: Database, path: String, excluding sampleID: Int64 = -1, pitchLabel: PitchLabel? = nil
    ) throws -> String {
        let url = URL(fileURLWithPath: path)
        let filename = url.lastPathComponent
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        guard let match = leadingNumber.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
            let number = Range(match.range(at: 1), in: stem), let whole = Range(match.range, in: stem),
            whole.upperBound < stem.endIndex
        else { return filename }
        let rest = String(stem[whole.upperBound...])
        let directory = url.deletingLastPathComponent().path
        func taken(_ name: String) throws -> Bool {
            // rtrim with the path's own non-slash characters leaves the folder, so only siblings match.
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM samples WHERE name = ? AND id != ? AND rtrim(canonical_path, replace(canonical_path, '/', '')) = ?)",
                arguments: [name, sampleID, directory + "/"]) ?? false
        }
        if try !taken(rest + ext) { return rest + ext }
        if let label = pitchLabel?(rest, url) {
            let withPitch = "\(rest) \(label)" + ext
            if try !taken(withPitch) { return withPitch }
        }
        return "\(rest) \(stem[number])" + ext
    }
}
