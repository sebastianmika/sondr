import SondrCore
import SwiftUI

/// Keys of the stored preferences.
enum Preferences {
    static let computeUnits = "computeUnits"
    static let autoAudition = "autoAudition"
    static let settingsTab = "settingsTab"
    static let showSoundMap = "showSoundMap"
    static let groupMultisamples = "groupMultisamples"

    static var savedComputeUnits: EmbeddingService.ComputeUnits {
        UserDefaults.standard.string(forKey: computeUnits).flatMap(EmbeddingService.ComputeUnits.init(rawValue:)) ?? .cpuAndGPU
    }
}

struct SettingsView: View {
    @AppStorage(Preferences.settingsTab) private var tab = ProcessInfo.processInfo.environment["SONDR_SETTINGS_TAB"] ?? "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            LocationsSettingsView()  // minimal list; the full editor replaces it
                .tabItem { Label("Locations", systemImage: "folder") }
                .tag("locations")
            // Extension point: a "Map" tab (tag "map") is added with the explore panel.
        }
        .frame(width: 760, height: 700)
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(Preferences.computeUnits) private var computeUnits = EmbeddingService.ComputeUnits.cpuAndGPU.rawValue
    @AppStorage(Preferences.autoAudition) private var autoAudition = false

    var body: some View {
        Form {
            Section("Library") {
                LabeledContent("Database") {
                    HStack {
                        Text(app.databasePath).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.databasePath)])
                        }
                    }
                }
                LabeledContent("Models") {
                    Text(app.modelsDirectory?.path ?? "Not found. Build them with tools/convert_clap/convert.py.")
                        .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                        .foregroundStyle(app.modelsAvailable ? .primary : .secondary)
                }
            }
            Section("Search model") {
                Picker("Run on", selection: $computeUnits) {
                    Text("GPU and CPU (fastest)").tag(EmbeddingService.ComputeUnits.cpuAndGPU.rawValue)
                    Text("All, including Neural Engine").tag(EmbeddingService.ComputeUnits.all.rawValue)
                    Text("CPU only").tag(EmbeddingService.ComputeUnits.cpuOnly.rawValue)
                }
                Text("Takes effect the next time Sondr starts. GPU and CPU measured fastest; the Neural Engine did not help.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Playback") {
                Toggle("Play samples as soon as they are selected", isOn: $autoAudition)
            }
        }
        .formStyle(.grouped)
    }
}
