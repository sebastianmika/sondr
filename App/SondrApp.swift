import SondrCore
import SwiftUI

@main
struct SondrApp: App {
    @State private var model = AppModel(computeUnits: Preferences.savedComputeUnits)

    init() {
        SnapshotHook.installIfRequested()
    }

    var body: some Scene {
        WindowGroup("Sondr") {
            Group {
                // Development aid: show the Settings content in the main window (see SnapshotHook).
                if ProcessInfo.processInfo.environment["SONDR_OPEN_SETTINGS"] != nil {
                    SettingsView()
                } else {
                    RootView().frame(minWidth: 960, minHeight: 560)
                }
            }
            .environment(model)
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
