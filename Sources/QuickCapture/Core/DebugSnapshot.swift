import AppKit

/// Development aid: when the app is started with `QC_SNAPSHOT_DIR=/some/folder`, posting the distributed
/// notification `QuickCaptureSnapshot` saves every visible window of the app as a PNG in that folder.
/// It draws the app's own views, so it needs no Screen Recording permission. Does nothing otherwise.
/// See docs/development.md.
enum DebugSnapshot {
    static func installIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["QC_SNAPSHOT_DIR"], !dir.isEmpty else { return }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("QuickCaptureSnapshot"),
                                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { save(to: URL(fileURLWithPath: dir, isDirectory: true)) }
        }
    }

    @MainActor
    private static func save(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (index, window) in NSApp.windows.enumerated() where window.isVisible || window.isMiniaturized {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = window.title.isEmpty ? "window-\(index)" : window.title
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }
}
