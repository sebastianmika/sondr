import SondrCore
import SwiftUI

enum SidebarItem: Hashable {
    case all, unsorted
    case cluster(Int)
}

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @Binding var selection: SidebarItem?
    let browse: BrowseModel
    @Binding var showingFailures: Bool
    @State private var managingTags = false
    @State private var tagSearch = ""

    var body: some View {
        VSplitView {
            List(selection: $selection) {
                Section {
                    row("All samples", count: app.stats.samples - app.stats.missing) { Image(systemName: "waveform") }
                        .tag(SidebarItem.all)
                    row("Unsorted", count: app.unsortedCount) { Image(systemName: "questionmark.folder") }
                        .tag(SidebarItem.unsorted)
                } header: {
                    Text("Library").sondrLabel()
                }
                Section {
                    ForEach(app.clusters) { cluster in
                        row(cluster.name, count: cluster.count) { ClusterMarker(color: clusterColor(cluster.id, app.palette)) }
                            .tag(SidebarItem.cluster(cluster.id))
                    }
                } header: {
                    Text("Clusters").sondrLabel()
                }
            }
            .scrollContentBackground(.hidden)
            .frame(minHeight: 120)
            if !app.tagCounts.isEmpty {
                tagPanel.frame(minHeight: 120, idealHeight: 260)
            }
        }
        .background(Theme.panel)
        .safeAreaInset(edge: .bottom) { JobsBar(showingFailures: $showingFailures) }
        .sheet(isPresented: $managingTags) { TagManagerView() }
        .onChange(of: selection) { _, item in apply(item) }
    }

    /// Tag header with search and manage link; only the tag list scrolls.
    private var tagPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Tags").sondrLabel()
                Spacer()
                Button("Manage tags") { managingTags = true }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            TextField("Search tags", text: $tagSearch)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            ScrollView {
                TagCloud(browse: browse, search: tagSearch)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// A sidebar row: icon, name, count in mono.
    private func row<Icon: View>(_ title: String, count: Int, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 8) {
            icon()
            Text(title)
            Spacer(minLength: 4)
            Text(count.formatted()).font(.sondrMono(size: 11.5)).foregroundStyle(Theme.textDim)
        }
    }

    private func apply(_ item: SidebarItem?) {
        var filter = browse.filter
        filter.cluster = nil
        switch item {
        case .unsorted: filter.cluster = .unsorted
        case .cluster(let id): filter.cluster = .cluster(id)
        case .all, nil: break
        }
        browse.filter = filter
    }
}

/// Most used tags among all samples; a click adds or removes the tag from the filter.
struct TagCloud: View {
    @Environment(AppModel.self) private var app
    let browse: BrowseModel
    var search = ""

    private var visibleTags: [TagCount] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? app.tagCounts : app.tagCounts.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(visibleTags, id: \.name) { tag in
                let active = browse.filter.tags.contains(tag.name)
                Button {
                    if active { browse.filter.tags.removeAll { $0 == tag.name } } else { browse.filter.tags.append(tag.name) }
                } label: {
                    TagChip(text: "\(tag.name) \(tag.count)", active: active)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Wraps its children into lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 240, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (subview, origin) in zip(subviews, result.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + lineHeight), origins)
    }
}
