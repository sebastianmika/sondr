import SondrCore
import SwiftUI

/// Library numbers, progress and cancel, at the bottom of the sidebar.
struct JobsBar: View {
    @Environment(AppModel.self) private var app
    @Binding var showingFailures: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let scan = app.scanStatus {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scanning \(URL(fileURLWithPath: scan.location).lastPathComponent)…").sondrLabel()
                    if let progress = scan.progress, progress.found > 0 {
                        LEDProgress(value: Double(progress.processed), total: Double(progress.found))
                        Text("\(progress.processed) of \(progress.found) files").font(.sondrMono(size: 10.5)).foregroundStyle(Theme.textDim)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            ForEach(Array(app.scanQueue.enumerated()), id: \.offset) { _, item in
                Text("Queued: \(item.url.lastPathComponent)").font(.sondrMono(size: 10.5)).foregroundStyle(Theme.textDim)
            }
            if let retag = app.retagProgress {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Updating tags").sondrLabel()
                    LEDProgress(value: Double(retag.done), total: Double(max(retag.total, 1)))
                    Text("\(retag.done.formatted()) of \(retag.total.formatted())").font(.sondrMono(size: 10.5)).foregroundStyle(Theme.textDim)
                }
            }
            if let recluster = app.reclusterProgress {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sorting into clusters").sondrLabel()
                    LEDProgress(value: Double(recluster.done), total: Double(max(recluster.total, 1)))
                    HStack {
                        Text("\(recluster.done.formatted()) of \(recluster.total.formatted())").font(.sondrMono(size: 10.5)).foregroundStyle(Theme.textDim)
                        Spacer()
                        Button("Cancel") { app.cancelRecluster() }.controlSize(.small)
                    }
                }
            }
            if let index = app.indexProgress {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Indexing").sondrLabel()
                    LEDProgress(value: Double(index.done + index.failed), total: Double(max(index.total, 1)))
                    HStack {
                        Text("\(index.done + index.failed) of \(index.total)").font(.sondrMono(size: 10.5)).foregroundStyle(Theme.textDim)
                        Spacer()
                        Button("Cancel") { app.cancelIndexing() }.controlSize(.small)
                    }
                }
            } else if app.stats.failed > 0 {
                Button("\(app.stats.failed) failed") { showingFailures = true }.buttonStyle(.link)
            }
            ForEach(Array(app.notices.enumerated()), id: \.offset) { _, text in
                Text(text).font(.sondrMono(size: 10.5)).foregroundStyle(Theme.signal)
            }
            Text(summary).font(.sondrMono(size: 10.5)).foregroundStyle(Theme.textDim)
        }
        .padding(10)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
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
