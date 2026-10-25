import SondrCore
import SwiftUI

/// Library numbers, Index button, progress and cancel, at the bottom of the sidebar.
struct JobsBar: View {
    @Environment(AppModel.self) private var app
    @Binding var showingFailures: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let scan = app.scanStatus {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scanning \(URL(fileURLWithPath: scan.location).lastPathComponent)…").font(.caption)
                    if let progress = scan.progress, progress.found > 0 {
                        ProgressView(value: Double(progress.processed), total: Double(progress.found))
                        Text("\(progress.processed) of \(progress.found) files").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            if let retag = app.retagProgress {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Updating tags").font(.caption)
                    ProgressView(value: Double(retag.done), total: Double(max(retag.total, 1)))
                    Text("\(retag.done.formatted()) of \(retag.total.formatted())").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let index = app.indexProgress {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Indexing").font(.caption)
                    ProgressView(value: Double(index.done + index.failed), total: Double(max(index.total, 1)))
                    HStack {
                        Text("\(index.done + index.failed) of \(index.total)").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { app.cancelIndexing() }.controlSize(.small)
                    }
                }
            } else {
                HStack {
                    Button {
                        Task { await app.startIndexing() }
                    } label: {
                        Label(app.stats.pending > 0 ? "Index \(app.stats.pending)" : "Index", systemImage: "sparkles")
                    }
                    .disabled(app.stats.pending == 0 || app.isScanning || !app.modelsAvailable)
                    .help(app.modelsAvailable ? "Compute embeddings for samples that have none" : "Core ML models not found")
                    Button {
                        Task { await app.rescanAll() }
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .disabled(app.locations.isEmpty || app.isScanning || app.isIndexing || app.isRetagging)
                    .help("Look for new, moved and removed files in all locations")
                    Spacer()
                    if app.stats.failed > 0 {
                        Button("\(app.stats.failed) failed") { showingFailures = true }.buttonStyle(.link)
                    }
                }
            }
            Text(summary).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.bar)
    }

    private var summary: String {
        let s = app.stats
        var text = "\(s.samples) samples, \(s.indexed) indexed"
        if s.missing > 0 { text += ", \(s.missing) missing" }
        return text
    }
}

/// Samples that could not be indexed, with the reason.
struct FailuresView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [SampleRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Files that could not be indexed").font(.headline)
            if rows.isEmpty {
                Text("None.").foregroundStyle(.secondary)
            } else {
                Table(rows) {
                    TableColumn("File") { Text($0.relPath).lineLimit(1).help($0.canonicalPath) }
                    TableColumn("Reason") { Text($0.embedError ?? "").lineLimit(2) }
                }
            }
            HStack {
                Button("Try Again") {
                    Task {
                        dismiss()
                        await app.startIndexing(retryFailed: true)
                    }
                }
                .disabled(rows.isEmpty || !app.modelsAvailable)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 380)
        .task {
            guard let database = app.database else { return }
            let filter = { () -> SampleFilter in
                var f = SampleFilter()
                f.embedState = "failed"
                return f
            }()
            rows = (try? await database.writer.read { try SampleQuery.browse($0, filter: filter, limit: 1000).rows }) ?? []
        }
    }
}
