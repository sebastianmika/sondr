import SondrCore
import SwiftUI
import UniformTypeIdentifiers

/// Builds a Tonverk drum kit: drop library samples on the eight pads, export, or open a kit to see and change its pads.
struct EldrumEditorView: View {
    private struct Pad {
        var source: EldrumExport.Source
        var title: String
        var note: String?
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = "My Kit"
    @State private var pads = [Pad?](repeating: nil, count: EldrumKit.pitches.count)
    @State private var lossy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tonverk Drum Kit").font(.headline)
            TextField("Kit name", text: $name)
                .onChange(of: name) { _, value in name = String(value.prefix(EldrumKit.maxNameLength)) }
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                ForEach(0..<2, id: \.self) { row in
                    GridRow {
                        ForEach(0..<4, id: \.self) { column in padView(row * 4 + column) }
                    }
                }
            }
            if lossy {
                Text("This kit has velocity layers or round robin. Exporting keeps only the first sample of each pad.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("Drag samples from the list onto a pad.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Open…", action: open)
                Button("Export…", action: export).disabled(name.isEmpty || pads.allSatisfy { $0 == nil })
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
    }

    private func padView(_ index: Int) -> some View {
        let pad = pads[index]
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Pad \(index + 1)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if pad != nil { Button("Clear") { pads[index] = nil }.buttonStyle(.borderless).font(.caption) }
            }
            Text(pad?.title ?? "Empty").lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            Text(pad?.note ?? " ").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(8)
        .frame(width: 140, height: 84, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4])))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in await drop(url, onto: index) } }
            }
            return true
        }
    }

    private func drop(_ url: URL, onto index: Int) async {
        let path = url.path
        do {
            let source = try await app.database?.writer.read { try EldrumLoad.source($0, path: path) }
            guard let source else {
                app.message = "\(url.lastPathComponent) is not in the library. Add its folder as a location first."
                return
            }
            pads[index] = Pad(source: source, title: url.lastPathComponent)
        } catch { app.message = error.localizedDescription }
    }

    private func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "eldrum") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                guard let loaded = try await app.database?.writer.read({ try EldrumLoad.load(eldrum: url, db: $0) }) else { return }
                name = loaded.kit.name
                lossy = loaded.kit.lossy
                pads = zip(loaded.pads, loaded.sources).map { pad, source in
                    guard let pad, let source else { return nil }
                    switch pad.link {
                    case .linked(_, let path, _):
                        return Pad(source: source, title: URL(fileURLWithPath: path).lastPathComponent, note: nil)
                    case .notInLibrary(let originalPath, _):
                        return Pad(source: source, title: pad.filename, note: "Not in library (was \(URL(fileURLWithPath: originalPath).lastPathComponent))")
                    case .unknown:
                        return Pad(source: source, title: pad.filename, note: "Origin unknown")
                    }
                }
            } catch { app.message = error.localizedDescription }
        }
    }

    private func export() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        if app.locations.contains(where: { parent.path.hasPrefix($0.path) }) {
            app.message = "Pick a folder outside your library locations."
            return
        }
        let name = name
        let sources = pads.map { $0?.source }
        Task {
            do {
                let eldrum = try await Task.detached { try EldrumExport.write(name: name, sources: sources, into: parent) }.value
                app.message = "Exported \(eldrum.deletingLastPathComponent().path)"
            } catch { app.message = error.localizedDescription }
        }
    }
}
