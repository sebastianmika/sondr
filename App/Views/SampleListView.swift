import SondrCore
import SwiftUI
import UniformTypeIdentifiers

struct SampleListView: View {
    @Environment(AppModel.self) private var app
    @Bindable var browse: BrowseModel
    let playback: PlaybackModel
    @Binding var selection: Set<Int64>
    @Environment(\.openSettings) private var openSettings
    @State private var sortOrder = [KeyPathComparator(\SampleRow.name)]
    @AppStorage(Preferences.showSoundMap) private var showSoundMap = false
    @AppStorage(Preferences.groupMultisamples) private var groupMultisamples = true
    @State private var scrollTarget: Int?

    private static let pageStep = 10

    var body: some View {
        VStack(spacing: 0) {
            if showSoundMap {
                ExplorePanel(browse: browse, selection: $selection)
                Divider()
            }
            table
        }
        .toolbar {
            ToolbarItem {
                Toggle(isOn: $showSoundMap) { Image(systemName: "chart.xyaxis.line") }
                    .help("Show the explore panel: the sound axes and the map. Drag on either to narrow the list")
            }
        }
    }

    private var table: some View {
        Table(of: SampleRow.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 6) {
                    Image(systemName: playback.playingID == row.id ? "speaker.wave.2.fill" : "waveform")
                        .foregroundStyle(playback.playingID == row.id ? Theme.signal : .secondary)
                        .frame(width: 16)
                    Text(row.name).lineLimit(1)
                    if let info = row.multisample { multisampleBadge(info, isGroupRow: isGroupRow(row)) }
                }
                .opacity(opacity(row))
                .task { await browse.loadMoreIfNeeded(at: row) }
            }
            .width(min: 140, ideal: 240)
            TableColumn("Cluster") { row in
                clusterCell(row).opacity(opacity(row))
            }
            .width(min: 70, ideal: 100)
            TableColumn("Tags") { row in
                Text((isGroupRow(row) ? row.multisample?.tags ?? row.tags : row.tags).joined(separator: ", "))
                    .font(.sondrMono(size: 11)).foregroundStyle(.secondary).lineLimit(1).opacity(opacity(row))
            }
            .width(min: 80, ideal: 230)
            TableColumn("Length", value: \.duration) { row in
                Text(formatDuration(row.duration)).font(.sondrMono(size: 12)).opacity(opacity(row))
            }
            .width(min: 50, ideal: 60, max: 80)
            TableColumn("Match") { row in
                Text(browse.scores[row.id].map { String(format: "%.0f%%", max($0, 0) * 100) } ?? "")
                    .font(.sondrMono(size: 12)).foregroundStyle(.secondary)
            }
            .width(min: 44, ideal: 50, max: 60)
        } rows: {
            ForEach(browse.rows) { row in
                if let group = row.multisample?.groupID, isGroupRow(row) {
                    DisclosureTableRow(row, isExpanded: expansion(of: group)) {
                        ForEach(browse.children(of: row)) { member in
                            TableRow(member).itemProvider { dragProvider(for: member) }
                        }
                    }
                    .itemProvider { dragProvider(for: row) }
                } else {
                    TableRow(row).itemProvider { dragProvider(for: row) }
                }
            }
        }
        // A Table whose rows switch between TableRow and DisclosureTableRow can keep stale rows; start afresh.
        .id(browse.showsGroups)
        .contextMenu(forSelectionType: Int64.self) { ids in
            if let row = browse.rows(for: ids).first, ids.count == 1 {
                Button("Play") { playback.play(row) }
                Button("Find Similar") { Task { await browse.showSimilar(to: row) } }.disabled(!app.modelsAvailable)
            }
            Button("Show in Finder") { reveal(ids) }
        } primaryAction: { ids in
            if let row = browse.rows(for: ids).first { playback.toggle(row) }
        }
        .onChange(of: groupMultisamples, initial: true) { _, on in browse.collapseGroups = on }
        .onChange(of: sortOrder) { _, order in
            guard let first = order.first else { return }
            browse.sort = SampleSort(sortKey(first.keyPath), ascending: first.order == .forward)
        }
        .onChange(of: selection) { _, ids in
            Task {
                if ids.count == 1, let id = ids.first { await browse.pin(id) }
                playback.selectionChanged(to: ids.count == 1 ? ids.first.flatMap { browse.row($0) } : nil)
            }
        }
        .onKeyPress(.space) {
            guard selection.count == 1, let row = selection.first.flatMap({ browse.row($0) }) else { return .ignored }
            playback.toggle(row)
            return .handled
        }
        .background(
            TableScroller(
                rowIndex: scrollTarget, rowCount: browse.visibleIDs.count,
                onArrow: { down, large in move(by: (down ? 1 : -1) * (large ? Self.pageStep : 1)) == .handled }))
        .searchable(text: $browse.searchText, placement: .toolbar, prompt: browse.mode == .keyword ? "Filter by name or folder" : "Describe a sound, e.g. “warm analog pad”")
        .toolbar {
            ToolbarItem {
                Picker("Search mode", selection: $browse.mode) {
                    Text("Keyword").tag(SearchMode.keyword)
                    Text("Describe").tag(SearchMode.text)
                }
                .pickerStyle(.segmented)
                .help("Keyword: words in names and folders. Describe: search by what it sounds like.")
            }
            ToolbarItem {
                Toggle(isOn: $groupMultisamples) { Image(systemName: "square.stack.3d.up") }
                    .help("Show a multisample (one instrument at several pitches) as one row")
            }
            ToolbarItem {
                Toggle(isOn: Bindable(playback).autoAudition) { Image(systemName: "speaker.wave.2") }
                    .help("Play samples as you select them")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { banners }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .overlay { emptyState }
    }

    // MARK: Pieces

    @ViewBuilder private var banners: some View {
        VStack(spacing: 0) {
            if !app.modelsAvailable {
                banner("The Core ML models were not found, so indexing and describe-search are off. Build them with tools/convert_clap/convert.py.", systemImage: "exclamationmark.triangle", tint: .orange)
            }
            switch browse.content {
            case .browse: EmptyView()
            case .textSearch(let text):
                banner("Best matches for “\(text)”", systemImage: "text.magnifyingglass", tint: Theme.signalText, clear: true)
            case .similar(_, let name):
                banner("Sounds like \(name)", systemImage: "waveform.badge.magnifyingglass", tint: Theme.signalText, clear: true)
            }
            if let error = browse.errorMessage { banner(error, systemImage: "xmark.octagon", tint: .red) }
            // Filter banners the explore panel will drive (map area, sound axes); inert until it sets them.
            if let area = browse.filter.sampleIDs {
                HStack {
                    Label("Area on the map: \(area.count.formatted()) samples", systemImage: "map").font(.caption)
                    Button { browse.filter.sampleIDs = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 4).background(Theme.panel)
            }
            if !browse.filter.dimRanges.isEmpty {
                HStack {
                    Label("Sound axes: " + Dim.allCases.filter { browse.filter.dimRanges[$0] != nil }.map { $0.rawValue }.joined(separator: ", "), systemImage: "chart.xyaxis.line").font(.caption)
                    Button { browse.filter.dimRanges = [:] } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 4).background(Theme.panel)
            }
            if !browse.filter.tags.isEmpty {
                HStack {
                    Text("Tags:").font(.caption).foregroundStyle(.secondary)
                    ForEach(browse.filter.tags, id: \.self) { tag in
                        Button { browse.filter.tags.removeAll { $0 == tag } } label: { Label(tag, systemImage: "xmark.circle.fill").font(.caption) }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 4).background(Theme.panel)
            }
        }
    }

    private func banner(_ text: String, systemImage: String, tint: Color, clear: Bool = false) -> some View {
        HStack {
            Label(text, systemImage: systemImage).foregroundStyle(tint).lineLimit(2)
            Spacer()
            if clear { Button("Clear") { Task { await browse.clearResults() } } }
        }
        .font(.callout).padding(.horizontal, 10).padding(.vertical, 6).background(Theme.panel)
    }

    private var footer: some View {
        HStack {
            Text(browse.content == .browse ? "\(browse.rows.count) of \(browse.total)" : "\(browse.total) results")
                .font(.sondrMono(size: 11)).foregroundStyle(Theme.textDim)
            if browse.isLoading { ProgressView().controlSize(.mini) }
            Spacer()
            if let error = playback.errorMessage { Text(error).font(.caption).foregroundStyle(.red).lineLimit(1) }
        }
        .padding(.horizontal, 10).padding(.vertical, 4).background(Theme.panel)
    }

    @ViewBuilder private var emptyState: some View {
        if browse.rows.isEmpty, !browse.isLoading, app.startup == .ready {
            if app.stats.samples == 0 {
                ContentUnavailableView {
                    Label("Your library is empty", systemImage: "folder.badge.plus")
                } description: {
                    Text("Add a folder with audio samples in Settings. Sondr reads them but never changes them.")
                } actions: {
                    Button("Add Folder…") {
                        UserDefaults.standard.set("locations", forKey: Preferences.settingsTab)
                        openSettings()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView.search
            }
        }
    }

    // MARK: Helpers

    /// A row that stands for its whole group; the members shown below it are plain rows.
    private func isGroupRow(_ row: SampleRow) -> Bool {
        row.multisample != nil && browse.showsGroups && browse.content == .browse
            && (row.multisample?.size ?? 0) > 1
    }

    private func expansion(of group: Int64) -> Binding<Bool> {
        Binding(
            get: { browse.isExpanded(group) },
            set: { expanded in Task { await browse.setExpanded(group, expanded) } })
    }

    @ViewBuilder private func multisampleBadge(_ info: MultisampleInfo, isGroupRow: Bool) -> some View {
        if isGroupRow {
            Text(info.lowLabel.isEmpty ? "\(info.size) samples" : "\(info.size) pitches \(info.lowLabel)–\(info.highLabel)")
                .font(.sondrMono(size: 10.5)).foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.hairline, lineWidth: 1))
        } else if let label = info.pitchLabel {
            Text(label).font(.sondrMono(size: 11)).foregroundStyle(.secondary)
        }
    }

    /// Members of an expanded group that do not match the filter are dimmed.
    private func opacity(_ row: SampleRow) -> Double { row.multisample?.matches == false ? 0.4 : 1 }

    /// A group row shows a dot for every cluster among its members, a single sample its own cluster.
    @ViewBuilder private func clusterCell(_ row: SampleRow) -> some View {
        let ids: [Int] = isGroupRow(row)
            ? row.multisample?.clusters ?? []
            : (row.clusterID.flatMap { ClusterAssigner.isUnsorted(score: row.clusterScore) ? nil : [$0] } ?? [])
        let found = ids.compactMap { id in app.clusters.first { $0.id == id } }
        if found.isEmpty {
            Text("–").foregroundStyle(.tertiary)
        } else if found.count == 1 {
            Label(found[0].name, systemImage: "square.fill")
                .labelStyle(ClusterLabelStyle(color: clusterColor(found[0].id, app.palette)))
        } else {
            HStack(spacing: 3) {
                ForEach(found) { cluster in
                    ClusterMarker(color: clusterColor(cluster.id, app.palette))
                }
            }
            .help(found.map(\.name).joined(separator: ", "))
        }
    }

    private func move(by offset: Int) -> KeyPress.Result {
        guard let id = browse.rowID(moving: offset, from: selection) else { return .ignored }
        selection = [id]
        scrollTarget = browse.visibleIDs.firstIndex(of: id)
        return .handled
    }

    private func sortKey(_ keyPath: PartialKeyPath<SampleRow>) -> SampleSortKey {
        keyPath == \SampleRow.duration ? .duration : .filename
    }

    private func reveal(_ ids: Set<Int64>) {
        let urls = browse.rows(for: ids).map { URL(fileURLWithPath: $0.canonicalPath) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// The audio file itself, so that Finder and DAWs get a real file. Missing files give nothing to drag.
    private func dragProvider(for row: SampleRow) -> NSItemProvider? {
        DragProvider.provider(path: row.canonicalPath, missing: row.missing)
    }
}

/// Reaches the NSTableView behind SwiftUI's Table: scrolls it to a selection made in code, which Table does not do
/// itself, takes keyboard focus when the user clicks in it, even from the search field, and moves the selection
/// for the arrow keys. SwiftUI's `onKeyPress` delivers only the first press of a held key here, so the arrows
/// are read from the event stream, where key repeats arrive too. One row per arrow, a page for Page Up/Down or
/// with Shift. `onArrow(down, large)` returns whether it handled the key.
private struct TableScroller: NSViewRepresentable {
    let rowIndex: Int?
    let rowCount: Int
    let onArrow: (_ down: Bool, _ large: Bool) -> Bool

    @MainActor final class Coordinator {
        var rowCount = 0
        var onArrow: (Bool, Bool) -> Bool = { _, _ in false }
        weak var view: NSView?
        nonisolated(unsafe) var monitor: Any?

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

        /// Up/Down (126/125) and Page Up/Down (116/121), repeats included. Command, Option and Control keep their meaning.
        func handleArrow(_ event: NSEvent) -> Bool {
            guard let window = view?.window, event.window === window,
                  event.modifierFlags.isDisjoint(with: [.command, .option, .control])
            else { return false }
            switch event.keyCode {
            case 125: return onArrow(true, event.modifierFlags.contains(.shift))
            case 126: return onArrow(false, event.modifierFlags.contains(.shift))
            case 121: return onArrow(true, true)
            case 116: return onArrow(false, true)
            default: return false
            }
        }

        func focusTableIfClicked(_ event: NSEvent) {
            guard let window = view?.window, event.window === window, let root = window.contentView,
                  let table = TableScroller.table(in: root, rows: rowCount),
                  table.hitTest(table.superview?.convert(event.locationInWindow, from: nil) ?? .zero) != nil,
                  window.firstResponder !== table else { return }
            DispatchQueue.main.async { window.makeFirstResponder(table) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.view = view
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { event in
            if event.type == .keyDown { return coordinator.handleArrow(event) ? nil : event }
            coordinator.focusTableIfClicked(event)
            return event
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.rowCount = rowCount
        context.coordinator.onArrow = onArrow
        guard let rowIndex else { return }
        DispatchQueue.main.async {
            guard let root = view.window?.contentView else { return }
            Self.table(in: root, rows: rowCount)?.scrollRowToVisible(rowIndex)
        }
    }

    /// The sidebar is a table too, so match on the row count.
    fileprivate static func table(in view: NSView, rows: Int) -> NSTableView? {
        if let table = view as? NSTableView, table.numberOfRows == rows { return table }
        return view.subviews.lazy.compactMap { table(in: $0, rows: rows) }.first
    }
}

struct ClusterLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            ClusterMarker(color: color)
            configuration.title.font(.sondrMono(size: 10.5)).textCase(.uppercase).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

func formatDuration(_ seconds: Double) -> String {
    seconds < 10 ? String(format: "%.2f s", seconds) : String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
}
