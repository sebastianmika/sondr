import Foundation

/// Drag-out payload. A file-URL provider (not `NSItemProvider(contentsOf:)`, which makes SwiftUI hand receivers a
/// cached copy under Library/Caches with a generic name) so Finder and DAWs see the original path and file name.
public enum DragProvider {
    /// Nil when the sample is missing or the file is gone: nothing is dragged.
    public static func provider(path: String, missing: Bool) -> NSItemProvider? {
        let url = URL(fileURLWithPath: path)
        guard !missing, FileManager.default.fileExists(atPath: url.path) else { return nil }
        let provider = NSItemProvider(object: url as NSURL)
        provider.suggestedName = url.lastPathComponent
        return provider
    }
}
