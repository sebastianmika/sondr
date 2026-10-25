import AppKit

/// Development aid: with `SONDR_SNAPSHOT=<path>.png` the app writes a picture of its window after
/// a few seconds and quits. Lets the UI be checked on a machine without screen-capture access.
/// `SONDR_OPEN_SETTINGS=1` shows the Settings content in the main window instead
/// (`SONDR_SETTINGS_TAB` picks the tab); the real Settings window cannot be opened from a script.
enum SnapshotHook {
    @MainActor static func installIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["SONDR_SNAPSHOT"] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["SONDR_SNAPSHOT_DELAY"] ?? "") ?? 4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let window = NSApp.windows.first(where: { $0.isVisible })
            guard let view = window?.contentView?.superview ?? NSApp.windows.first?.contentView,
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else {
                FileHandle.standardError.write(Data("snapshot: no window\n".utf8))
                exit(1)
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }
}
