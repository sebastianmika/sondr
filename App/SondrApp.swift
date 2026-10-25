import SondrCore
import SwiftUI

@main
struct SondrApp: App {
    @State private var model = AppModel(computeUnits: Preferences.savedComputeUnits)

    init() {
        switch ProcessInfo.processInfo.environment["SONDR_APPEARANCE"] {
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
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
            .tint(Color(red: 1, green: 0.353, blue: 0.122))
            .task { await model.start() }
        }
        .defaultSize(width: 1280, height: 780)
        .commands {
            SidebarCommands()
        }

        Settings {
            SettingsView().environment(model)
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
