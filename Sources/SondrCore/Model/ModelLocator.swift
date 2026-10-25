import Foundation

/// Finds the folder with the converted Core ML models (`ClapAudio.mlpackage`, `ClapText.mlpackage`,
/// `model_version.txt`), built by `tools/convert_clap/convert.py`.
public enum ModelLocator {
    public static let requiredFiles = ["ClapAudio.mlpackage", "ClapText.mlpackage", "model_version.txt"]

    /// Places searched, in order.
    public static func candidates(
        environment: [String: String] = ProcessInfo.processInfo.environment, bundle: Bundle = .main
    ) -> [URL] {
        var urls: [URL] = []
        if let path = environment["SONDR_MODELS"] { urls.append(URL(fileURLWithPath: path)) }
        if let resources = bundle.resourceURL { urls.append(resources.appendingPathComponent("Models")) }
        urls.append(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Sondr/Models"))
        // Running from a source checkout (Xcode or `swift run`): <repo>/Models.
        urls.append(
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Models"))
        return urls
    }

    public static func isComplete(_ directory: URL) -> Bool {
        requiredFiles.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    /// The first complete models folder, or nil.
    public static func find(
        environment: [String: String] = ProcessInfo.processInfo.environment, bundle: Bundle = .main
    ) -> URL? {
        candidates(environment: environment, bundle: bundle).first(where: isComplete)
    }
}
