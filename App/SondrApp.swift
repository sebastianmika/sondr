import SondrCore
import SwiftUI

@main
struct SondrApp: App {
    @State private var model = AppModel(computeUnits: Preferences.savedComputeUnits)

    init() {
        Appearance.saved.apply()
        SnapshotHook.installIfRequested()
    }

    var body: some Scene {
        WindowGroup("Sondr") {
            Group {
                // Development aid: show the Settings content in the main window (see SnapshotHook).
                if ProcessInfo.processInfo.environment["SONDR_SHOW_EDITOR"] != nil {
                    EditorSnapshot()
                } else if ProcessInfo.processInfo.environment["SONDR_OPEN_SETTINGS"] != nil {
                    SettingsView()
                } else {
                    RootView().frame(minWidth: 960, minHeight: 560)
                }
            }
            .environment(model)
            .tint(Theme.signal)
            .task { await model.start() }
        }
        .defaultSize(width: 1280, height: 780)
        .commands {
            SidebarCommands()
        }

        Settings {
            SettingsView().environment(model).tint(Theme.signal)
        }
    }
}

/// Development aid (`SONDR_SHOW_EDITOR=1`): the location editor for the first location, in the main window.
private struct EditorSnapshot: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let location = app.locations.first {
            LocationEditor(mode: .edit(location))
        } else {
            ProgressView()
        }
    }
}
