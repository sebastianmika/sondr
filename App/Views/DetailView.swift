import SondrCore
import SwiftUI

struct DetailView: View {
    @Environment(AppModel.self) private var app
    let browse: BrowseModel
    let playback: PlaybackModel
    let selection: Set<Int64>

    var body: some View {
        if selection.count > 1 {
            MultiSelectionDetail(rows: browse.rows.filter { selection.contains($0.id) }, count: selection.count)
        } else if let id = selection.first, let row = browse.row(id) {
            SampleDetail(row: row, browse: browse, playback: playback)
                .id(row.id)
        } else {
            ContentUnavailableView("No selection", systemImage: "waveform", description: Text("Select a sample to see its details."))
        }
    }
}

private struct SampleDetail: View {
    @Environment(AppModel.self) private var app
    let row: SampleRow
    let browse: BrowseModel
    let playback: PlaybackModel
    @State private var paths: [String] = []
    @State private var spectrogram: Data?
    @State private var ranges: [Dim: DimStats.Range] = [:]
    @State private var metadata: (main: [(name: String, value: String)], extended: [MetadataItem]) = ([], [])

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(row.name).font(.title3.bold()).textSelection(.enabled)
                SoundTile(
                    waveform: row.waveThumb, spectrogram: spectrogram, duration: row.duration,
                    progress: playback.playingID == row.id ? playback.progress : nil)
                HStack {
                    Button { playback.toggle(row) } label: {
                        Label(playback.playingID == row.id ? "Stop" : "Play", systemImage: playback.playingID == row.id ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(SignalButtonStyle())
                    Button { Task { await browse.showSimilar(to: row) } } label: {
                        Label("Find Similar", systemImage: "waveform.badge.magnifyingglass")
                    }
                    .disabled(row.embedState != "done" || !app.modelsAvailable)
                }
                if row.missing {
                    Label("The file is gone from disk.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if row.embedState == "failed" {
                    Label(row.embedError ?? "Indexing failed.", systemImage: "xmark.octagon").foregroundStyle(.red)
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow { Text("Length").foregroundStyle(.secondary); Text(formatDuration(row.duration)).font(.sondrMono(size: 12)) }
                    GridRow { Text("Format").foregroundStyle(.secondary); Text("\(row.format.uppercased()), \(Int(row.sampleRate)) Hz, \(row.channels == 1 ? "mono" : "\(row.channels) ch")").font(.sondrMono(size: 12)) }
                    GridRow {
                        Text("Cluster").foregroundStyle(.secondary)
                        Text(clusterText)
                    }
                    GridRow { Text("State").foregroundStyle(.secondary); Text(row.embedState).font(.sondrMono(size: 12)) }
                }
                .font(.callout)

                section("Tags") {
                    TagEditor(ids: [row.id], tags: row.tags)
                }

                if let dims = row.dims, dims.count == Dim.allCases.count {
                    section("Sound") {
                        VStack(spacing: 4) {
                            ForEach(Array(Dim.allCases.enumerated()), id: \.offset) { index, dim in
                                let value = ranges[dim]?.normalise(dims[index]) ?? dims[index]
                                HStack {
                                    Text(dim.rawValue).sondrLabel().frame(width: 118, alignment: .leading)
                                    LEDProgress(value: min(max(value, 0), 1), total: 1)
                                }
                            }
                        }
                    }
                }

                section(paths.count > 1 ? "Found in \(paths.count) places" : "Location") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(paths, id: \.self) { path in
                            HStack(alignment: .top) {
                                Text(path).font(.sondrMono(size: 10.5)).textSelection(.enabled).lineLimit(3)
                                Spacer(minLength: 4)
                                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
                                    Image(systemName: "magnifyingglass.circle")
                                }
                                .buttonStyle(.borderless).help("Show in Finder")
                            }
                        }
                    }
                }

                if !metadata.main.isEmpty {
                    section("File metadata") {
                        metadataGrid(metadata.main.map { ($0.name, $0.value) })
                    }
                }
                if !metadata.extended.isEmpty {
                    DisclosureGroup("More metadata (\(metadata.extended.count))") {
                        metadataGrid(metadata.extended.map { ($0.key, $0.value) })
                            .padding(.top, 4)
                    }
                    .font(.caption.bold()).foregroundStyle(.secondary)
                }
            }
            .padding(14)
        }
        .task {
            guard let database = app.database else { return }
            let id = row.id
            spectrogram = try? await database.writer.read { try SpectrogramThumbnail.load($0, sampleID: id) }
            paths = (try? await database.writer.read { try LibraryInfo.paths($0, sampleID: id) }) ?? []
            ranges = (try? await database.writer.read { try DimStats.ranges($0) }) ?? [:]
            if !row.missing {
                metadata = MetadataCatalog.standard.split(await AudioMetadata.read(url: URL(fileURLWithPath: row.canonicalPath)))
            }
        }
    }

    private var clusterText: String {
        guard let id = row.clusterID, let score = row.clusterScore, let cluster = app.clusters.first(where: { $0.id == id }) else {
            return "–"
        }
        return ClusterAssigner.isUnsorted(score: score) ? "Unsorted (closest: \(cluster.name), \(Int(score * 100))%)" : "\(cluster.name) (\(Int(score * 100))%)"
    }

    private func metadataGrid(_ lines: [(String, String)]) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                GridRow {
                    Text(line.0).foregroundStyle(.secondary)
                    Text(line.1).font(.sondrMono(size: 11)).textSelection(.enabled).lineLimit(4)
                }
            }
        }
        .font(.caption.weight(.regular))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).sondrLabel()
            content()
        }
    }
}

/// Peaks as vertical bars, with a playhead while the sample plays.
/// Waveform and spectrogram in one rounded tile with a single playhead across both.
///
/// The spectrogram is the signal colour at an opacity that follows the level, so silence is the
/// tile itself. It is baked into pixels, so it is redrawn when the appearance changes.
struct SoundTile: View {
    let waveform: Data?
    let spectrogram: Data?
    let duration: Double
    let progress: Double?
    @Environment(\.colorScheme) private var colorScheme
    private let waveformHeight: CGFloat = 46
    private let spectrogramHeight: CGFloat = 96
    private let inset: CGFloat = 8

    var body: some View {
        VStack(spacing: 8) {
            WaveformView(thumb: waveform, progress: progress)
                .frame(height: waveformHeight)
            spectrogramPicture
                .frame(height: spectrogramHeight)
            timeAxis
        }
        .padding(inset)
        .overlay {
            if let progress {
                GeometryReader { proxy in
                    Rectangle().fill(Theme.text).frame(width: 1.5)
                        .offset(x: inset + (proxy.size.width - 2 * inset) * progress - 0.75)
                        .padding(.vertical, 4)
                }
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 2))
        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.hairline, lineWidth: 1))
        .help("Waveform on top. Spectrogram below: time left to right, low to high frequency bottom to top.")
    }

    @ViewBuilder private var spectrogramPicture: some View {
        if let image = Self.image(from: spectrogram, accent: Self.accentRGB(for: colorScheme)) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .overlay(alignment: .leading) { frequencyAxis }
                .clipShape(RoundedRectangle(cornerRadius: 2))
        } else {
            Text("No spectrogram yet. Press Index.").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var frequencyAxis: some View {
        GeometryReader { proxy in
            ForEach([(100.0, "100"), (1000, "1k"), (10_000, "10k")], id: \.0) { hz, label in
                let y = proxy.size.height * (1 - SpectrogramThumbnail.axisPosition(forFrequency: hz))
                HStack(spacing: 3) {
                    Text(label).font(.sondrMono(size: 9))
                    Rectangle().frame(width: 5, height: 0.5)
                }
                .foregroundStyle(.secondary)
                .position(x: 22, y: y)
            }
        }
    }

    private var timeAxis: some View {
        HStack {
            Text("0 s")
            Spacer()
            Text(String(format: "%.1f s", min(max(duration, 1), 10) / 2))
            Spacer()
            Text(String(format: "%.1f s", min(max(duration, 1), 10)))
        }
        .font(.sondrMono(size: 9))
        .foregroundStyle(.secondary)
    }

    static func accentRGB(for scheme: ColorScheme) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let signal = ThemeTokens.signal.value(for: scheme == .dark ? .dark : .light)
        return (signal.red, signal.green, signal.blue)
    }

    static func image(from thumb: Data?, accent: (red: UInt8, green: UInt8, blue: UInt8)) -> CGImage? {
        guard let pixels = SpectrogramThumbnail.pixels(from: thumb, accent: accent),
            let provider = CGDataProvider(data: Data(pixels) as CFData)
        else { return nil }
        return CGImage(
            width: SpectrogramThumbnail.columns, height: SpectrogramThumbnail.bands, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: SpectrogramThumbnail.columns * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Peak bars; the part already played is drawn in the signal colour. Meant to sit in a ``SoundTile``.
struct WaveformView: View {
    let thumb: Data?
    let progress: Double?

    var body: some View {
        Canvas { context, size in
            guard let thumb, !thumb.isEmpty else {
                context.fill(Path(CGRect(x: 0, y: size.height / 2 - 0.5, width: size.width, height: 1)), with: .color(.secondary.opacity(0.4)))
                return
            }
            let count = thumb.count
            let barWidth = size.width / CGFloat(count)
            for (i, peak) in thumb.enumerated() {
                let h = max(1, CGFloat(peak) / 255 * size.height)
                let rect = CGRect(x: CGFloat(i) * barWidth, y: (size.height - h) / 2, width: max(barWidth - 0.5, 0.5), height: h)
                let played = progress.map { Double(i) / Double(count) <= $0 } ?? false
                context.fill(Path(rect), with: .color(played ? Theme.signal : .secondary.opacity(0.75)))
            }
        }
    }
}

/// Tag chips with a remove button, and a field to add a tag to `ids`.
struct TagEditor: View {
    @Environment(AppModel.self) private var app
    let ids: [Int64]
    /// Tags to show as removable chips.
    let tags: [String]
    @State private var newTag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 4) {
                ForEach(tags, id: \.self) { tag in
                    HStack(spacing: 4) {
                        Text(tag).font(.sondrMono(size: 10.5)).foregroundStyle(Theme.textMid)
                        Button { Task { await app.removeTag(tag, from: ids) } } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove “\(tag)”")
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.hairline, lineWidth: 1))
                }
            }
            TextField(ids.count > 1 ? "Add a tag to \(ids.count) samples" : "Add a tag", text: $newTag)
                .textFieldStyle(.roundedBorder).controlSize(.small)
                .onSubmit {
                    let name = newTag
                    newTag = ""
                    Task { await app.addTag(name, to: ids) }
                }
        }
    }
}

private struct MultiSelectionDetail: View {
    let rows: [SampleRow]
    let count: Int

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(count) samples selected").font(.title3.bold())
                Text("Tags on any of them. Removing one takes it off all selected samples.")
                    .font(.caption).foregroundStyle(.secondary)
                TagEditor(ids: rows.map(\.id), tags: Array(Set(rows.flatMap(\.tags))).sorted())
            }
            .padding(14)
        }
    }
}
