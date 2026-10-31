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
    @State private var importing = false
    @State private var adding: LocationEditor.Mode?
    @State private var kit: EldrumKitModel?
    @AppStorage(Preferences.showTonverkKit) private var showingKit = false

    var body: some View {
        Group {
            if let browse {
                NavigationSplitView {
                    SidebarView(selection: $sidebar, browse: browse, showingFailures: $showingFailures, addLocation: { importing = true })
                        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
                } content: {
                    VStack(spacing: 0) {
                        SampleListView(browse: browse, playback: playback, selection: $selection, addLocation: { importing = true })
                        if showingKit, let kit {
                            Divider()
                            EldrumEditorView(kit: kit, browse: browse, selection: selection)
                        }
                    }
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
                kit = EldrumKitModel(app: app)
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
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { adding = .add(url) }
        }
        .sheet(item: $adding) { LocationEditor(mode: $0) }
        .toolbar { ToolbarItem { Toggle(isOn: $showingKit) { Label("Tonverk Kit", systemImage: "square.grid.4x3.fill") }.help("Show the Tonverk drum kit builder under the list") } }
        .alert(
            "Sondr",
            isPresented: Binding(get: { app.message != nil }, set: { if !$0 { app.message = nil } }),
            actions: { Button("OK") { app.message = nil } },
            message: { Text(app.message ?? "") })
    }
}
