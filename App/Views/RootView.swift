import SondrCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        switch app.startup {
        case .loading:
            ProgressView("Opening library…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let reason):
            ContentUnavailableView {
                Label("The library could not be opened", systemImage: "exclamationmark.triangle")
            } description: {
                Text(reason)
            }
        case .ready:
            MainView()
        }
    }
}
