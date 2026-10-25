import SondrCore
import SwiftUI

/// Settings → Locations, minimal version: list, Add, Rescan, Remove.
/// Extension point: the full tab (editor sheet, tag rules, preview, multisample rules) replaces this file.
struct LocationsSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var importing = false
    @State private var removing: LocationInfo?

    private var busy: Bool { app.isScanning || app.isIndexing || app.isRetagging }

    var body: some View {
        Form {
            Section("Locations") {
                if app.locations.isEmpty {
                    Text("No folders yet. Sondr reads the audio files in them and never changes them.")
                        .foregroundStyle(.secondary)
                }
                ForEach(app.locations) { location in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label(URL(fileURLWithPath: location.path).lastPathComponent, systemImage: "folder")
                            Spacer()
                            Text("\(location.sampleCount.formatted()) samples").foregroundStyle(.secondary)
                        }
                        Text(location.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        HStack {
                            Button("Rescan") { Task { await app.rescan(location) } }
                            Button("Remove…", role: .destructive) { removing = location }
                        }
                        .controlSize(.small).disabled(busy)
                    }
                    .padding(.vertical, 2)
                }
                HStack {
                    Button("Add Location…") { importing = true }.disabled(busy)
                    Button("Rescan All") { Task { await app.rescanAll() } }.disabled(busy || app.locations.isEmpty)
                    if app.isScanning { Text("Scanning…").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { Task { await app.addLocation(url) } }
        }
        .confirmationDialog(
            "Remove “\(removing.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? "")” from the library?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing
        ) { location in
            Button("Remove from Library", role: .destructive) { Task { await app.removeLocation(location) } }
        } message: { location in
            Text("\(location.sampleCount.formatted()) samples that are only found here leave the library, with their tags. The audio files are not touched.")
        }
    }
}
