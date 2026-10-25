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

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                Label("All samples", systemImage: "waveform").badge(app.stats.samples - app.stats.missing)
                    .tag(SidebarItem.all)
                Label("Unsorted", systemImage: "questionmark.folder").badge(app.unsortedCount)
                    .tag(SidebarItem.unsorted)
            }
            Section("Clusters") {
                ForEach(app.clusters) { cluster in
                    Label {
                        Text(cluster.name)
                    } icon: {
                        Circle().fill(clusterColor(cluster.id, app.palette)).frame(width: 9, height: 9)
                    }
                    .badge(cluster.count)
                    .tag(SidebarItem.cluster(cluster.id))
                }
            }
            if !app.tagCounts.isEmpty {
                Section {
                    TagCloud(browse: browse)
                    Button("Manage Tags…") { managingTags = true }.buttonStyle(.borderless)
                } header: {
                    Text("Tags")
                }
            }
        }
        .safeAreaInset(edge: .bottom) { JobsBar(showingFailures: $showingFailures) }
        .sheet(isPresented: $managingTags) { TagManagerView() }
        .onChange(of: selection) { _, item in apply(item) }
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

func clusterColor(_ id: Int, _ palette: ClusterPalette) -> Color {
    let rgb = palette.rgb(forCluster: id)
    return Color(red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
}

/// Most used tags among all samples; a click adds or removes the tag from the filter.
struct TagCloud: View {
    @Environment(AppModel.self) private var app
    let browse: BrowseModel

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(app.tagCounts, id: \.name) { tag in
                let active = browse.filter.tags.contains(tag.name)
                Button {
                    if active { browse.filter.tags.removeAll { $0 == tag.name } } else { browse.filter.tags.append(tag.name) }
                } label: {
                    Text("\(tag.name) \(tag.count)")
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(active ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(active ? Color.white : Color.primary)
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
