import SondrCore
import SwiftUI

/// The explore panel above the list: the sound axes or the 2D map.
struct ExplorePanel: View {
    let browse: BrowseModel
    @AppStorage(Preferences.explorerTab) private var tab = "axes"
    @AppStorage(Preferences.explorerHeight) private var height = 380.0
    @State private var heightAtDragStart: Double?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Explore", selection: $tab) {
                    Text("Axes").tag("axes")
                    Text("Map").tag("map")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            Group {
                if tab == "map" {
                    // Extension point: replace with the map canvas when the Map module lands.
                    Text("Map coming soon").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ParallelCoordinatesView(browse: browse)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipped()
            handle
        }
    }

    /// Drag to make the panel taller or shorter (160...700 pt).
    private var handle: some View {
        ZStack {
            Divider()
            Capsule().fill(.tertiary).frame(width: 36, height: 3)
        }
        .frame(height: 10)
        .contentShape(Rectangle())
        .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let start = heightAtDragStart ?? height
                    heightAtDragStart = start
                    height = min(max(start + drag.translation.height, 160), 700)
                }
                .onEnded { _ in heightAtDragStart = nil })
    }
}
