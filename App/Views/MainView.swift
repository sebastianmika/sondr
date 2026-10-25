import SondrCore
import SwiftUI

/// Sidebar, sample table and detail pane.
struct MainView: View {
    @Environment(AppModel.self) private var app
    @State private var browse: BrowseModel?
    @State private var playback = PlaybackModel()
    @AppStorage(Preferences.autoAudition) private var autoAudition = false
    @State private var selection = Set<Int64>()
    @State private var sidebar: SidebarItem? = .all
    @State private var showingFailures = false

    var body: some View {
        Group {
            if let browse {
                NavigationSplitView {
                    SidebarView(selection: $sidebar, browse: browse, showingFailures: $showingFailures)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
                } content: {
                    SampleListView(browse: browse, playback: playback, selection: $selection)
                        .navigationSplitViewColumnWidth(min: 400, ideal: 520)
                } detail: {
                    DetailView(browse: browse, playback: playback, selection: selection)
                        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 400)
                }
            } else {
                ProgressView()
            }
        }
        .environment(playback)
        .onAppear { playback.autoAudition = autoAudition }
        .onChange(of: autoAudition) { _, value in playback.autoAudition = value }
        .onChange(of: playback.autoAudition) { _, value in autoAudition = value }
        .task {
            if browse == nil {
                let model = BrowseModel(app: app)
                browse = model
                await model.reload()
                if ProcessInfo.processInfo.environment["SONDR_SELECT_FIRST"] != nil, let first = model.rows.first {
                    selection = [first.id]  // development aid, see SnapshotHook
                }
            }
        }
        .onChange(of: app.libraryVersion) { _, _ in
            guard let browse else { return }
            Task { await browse.reload() }
        }
        .sheet(isPresented: $showingFailures) { FailuresView() }
        .alert(
            "Sondr",
            isPresented: Binding(get: { app.message != nil }, set: { if !$0 { app.message = nil } }),
            actions: { Button("OK") { app.message = nil } },
            message: { Text(app.message ?? "") })
    }
}
