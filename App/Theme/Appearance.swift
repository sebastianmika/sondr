import AppKit

/// Settings → General → Appearance. `system` follows macOS; the others pin the whole app (windows, Settings, sheets,
/// and the AppKit views behind SwiftUI's Table) through `NSApp.appearance`.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Sets the app's appearance; nil (system) hands the choice back to macOS.
    @MainActor func apply() {
        switch self {
        case .system: NSApplication.shared.appearance = nil
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// The stored choice. `SONDR_APPEARANCE=light|dark|system` overrides it (development aid for snapshots).
    static var saved: Appearance {
        let forced = ProcessInfo.processInfo.environment["SONDR_APPEARANCE"]
        return (forced ?? UserDefaults.standard.string(forKey: Preferences.appearance)).flatMap(Appearance.init(rawValue:)) ?? .system
    }
}
