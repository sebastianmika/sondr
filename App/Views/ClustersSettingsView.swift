import AppKit
import SondrCore
import SwiftUI

/// Settings → Clusters: name, colour and description of every cluster, applied with one button.
struct ClustersSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var rows: [ClusterDefinition] = []
    @State private var nextNewId = -1

    private var saved: [ClusterDefinition] {
        app.clusters.map { ClusterDefinition(id: $0.id, name: $0.name, color: $0.color, keywords: $0.keywords) }
    }

    private var busy: Bool { app.isScanning || app.isIndexing || app.isRetagging || app.isReclustering }
    private var editable: Bool { app.modelsAvailable && !busy }
    private var isDirty: Bool { rows != saved }
    private var isValid: Bool {
        !rows.isEmpty
            && rows.allSatisfy {
                !$0.name.trimmingCharacters(in: .whitespaces).isEmpty && !$0.keywords.trimmingCharacters(in: .whitespaces).isEmpty
            }
    }

    var body: some View {
        Form {
            Section("Clusters") {
                ForEach($rows) { $row in
                    ClusterRow(row: $row, count: app.clusters.first { $0.id == row.id }?.count, editable: editable, canDelete: rows.count > 1) {
                        rows.removeAll { $0.id == row.id }
                    }
                }
                Button("Add Cluster", systemImage: "plus") { addRow() }.disabled(!editable)
                Text("The description is turned into a point in the same sound space as your samples by the CLAP model, and every sample goes to the cluster whose point is closest. Use words that describe how the sounds sound, for example \"kick drum thump bass\".")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Apply") {
                HStack {
                    Button("Apply") { Task { await app.saveClusters(rows) } }
                        .disabled(!editable || !isDirty || !isValid)
                    Button("Revert") { rows = saved }.disabled(!isDirty || busy)
                    if app.isReclustering { ProgressView().controlSize(.small) }
                }
                if let why = disabledReason { Label(why, systemImage: "info.circle").font(.callout) }
                Text("Renaming or recolouring a cluster is instant. Changing a description, or adding or removing a cluster, sorts all samples again in the background. That can take a while on a big library. Sondr stays usable, and you can cancel it in the sidebar; it continues the next time Sondr starts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { rows = saved }
        .onChange(of: app.clusters) { _, _ in rows = saved }
    }

    private var disabledReason: String? {
        if !app.modelsAvailable { return "The Core ML models were not found, so clusters cannot be changed. Even renaming needs them for now." }
        if app.isReclustering { return "Sorting into clusters is running." }
        if busy { return "A scan, index or tag update is running. Clusters can be changed when it has finished." }
        if !isValid { return "Every cluster needs a name and a description." }
        return nil
    }

    private func addRow() {
        let colour = ClusterPalette.generatedHex(forCluster: (app.clusters.map(\.id).max() ?? 0) + rows.count + 1)
        rows.append(ClusterDefinition(id: nextNewId, name: "", color: colour, keywords: ""))
        nextNewId -= 1
    }
}

private struct ClusterRow: View {
    @Binding var row: ClusterDefinition
    let count: Int?
    let editable: Bool
    let canDelete: Bool
    let delete: () -> Void

    private var colour: Binding<Color> {
        Binding(
            get: {
                let rgb = ClusterPalette.RGB(hex: row.color) ?? ClusterPalette.unsorted
                return Color(red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
            },
            set: {
                guard let c = NSColor($0).usingColorSpace(.sRGB) else { return }
                func byte(_ v: CGFloat) -> UInt8 { UInt8((v * 255).rounded()) }
                row.color = ClusterPalette.RGB(red: byte(c.redComponent), green: byte(c.greenComponent), blue: byte(c.blueComponent)).hex
            })
    }

    var body: some View {
        HStack {
            ColorPicker("Colour", selection: colour, supportsOpacity: false).labelsHidden()
            TextField("Name", text: $row.name, prompt: Text("Name")).labelsHidden().frame(width: 120)
            TextField("Description", text: $row.keywords, prompt: Text("Description, embedded by CLAP and compared with each sound"))
                .labelsHidden()
            Text(count.map { "\($0.formatted())" } ?? "new").font(.sondrMono(size: 11)).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing).help("Samples in this cluster")
            Button("Delete", systemImage: "trash", action: delete)
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .disabled(!editable || !canDelete)
                .help(canDelete ? "Delete this cluster" : "At least one cluster is needed")
        }
        .textFieldStyle(.roundedBorder)
        .disabled(!editable)
    }
}
