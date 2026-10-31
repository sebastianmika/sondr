import SondrCore
import SwiftUI
import UniformTypeIdentifiers

/// Dock under the sample list for building a Tonverk drum kit: drop samples on the eight pads, or assign the
/// selected one. The list stays usable while it is open.
struct EldrumEditorView: View {
    let kit: EldrumKitModel
    let browse: BrowseModel
    @Binding var selection: Set<Int64>

    private var selected: SampleRow? {
        selection.count == 1 ? selection.first.flatMap { browse.row($0) } : nil
    }

    var body: some View {
        @Bindable var kit = kit
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tonverk Kit").font(.headline)
                TextField("Kit name", text: $kit.name).frame(maxWidth: 200)
                Spacer()
                Button("Open…", action: open)
                Button("Export…", action: export).disabled(!kit.canExport)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(0..<EldrumKit.pitches.count, id: \.self) { padView($0) }
            }
            if kit.lossy {
                Text("This kit has velocity layers or round robin. Exporting keeps only the first sample of each pad.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(10)
    }

    private func padView(_ index: Int) -> some View {
        let pad = kit.pads[index]
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Pad \(index + 1)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { assignSelected(to: index) } label: { Image(systemName: "arrow.down.to.line") }
                    .help("Assign the selected sample to pad \(index + 1)")
                    .disabled(selected == nil)
                if pad != nil {
                    Button { kit.clear(pad: index) } label: { Image(systemName: "xmark.circle") }.help("Clear pad \(index + 1)")
                }
            }
            .buttonStyle(.borderless)
            Text(pad?.title ?? "Empty").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(pad?.note ?? " ").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4])))
        .contentShape(Rectangle())
        .onTapGesture { if let id = pad?.sampleID { selection = [id] } }
        .help(pad?.sampleID == nil ? "" : "Show this sample in the list")
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in await kit.assign(path: url.path, to: index) } }
            }
            return true
        }
    }

    private func assignSelected(to index: Int) {
        guard let selected else { return }
        Task { await kit.assign(path: selected.canonicalPath, to: index) }
    }

    private func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "eldrum") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await kit.open(url) }
    }

    private func export() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        Task { await kit.export(into: parent) }
    }
}
