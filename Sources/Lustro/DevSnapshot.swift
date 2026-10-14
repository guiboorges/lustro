import AppKit

/// Development helper that renders the main window to a PNG and quits.
/// Used to produce README screenshots and to check layouts without screen-recording permission.
///
///     SNAPSHOTS=1 scripts/build-app.sh
///     LUSTRO_SNAPSHOT=/tmp/shot.png LUSTRO_MODULE=devPurge LUSTRO_AUTOSCAN=1 build/Lustro.app/Contents/MacOS/Lustro
///
/// Only compiled into snapshot builds. In a normal build whoever launches Lustro could use these
/// variables to make it scan and write files with the permissions granted to it.
@MainActor
enum DevSnapshot {
    private static var env: [String: String] {
        #if LUSTRO_SNAPSHOTS
        ProcessInfo.processInfo.environment
        #else
        [:]
        #endif
    }

    static var isActive: Bool { env["LUSTRO_SNAPSHOT"] != nil }
    static var initialModule: Module? { env["LUSTRO_MODULE"].flatMap(Module.init(rawValue:)) }
    static var autoScan: Bool { env["LUSTRO_AUTOSCAN"] == "1" }
    static var selectBundleID: String? { env["LUSTRO_SELECT_APP"] }
    static var spaceLensRoot: String { env["LUSTRO_SPACELENS_ROOT"] ?? "" }

    static func scheduleIfRequested() {
        guard let path = env["LUSTRO_SNAPSHOT"] else { return }
        // Offscreen rendering skips the window background, so force light mode for legible captures.
        NSApp.appearance = NSAppearance(named: env["LUSTRO_SNAPSHOT_DARK"] == "1" ? .darkAqua : .aqua)
        let delay = Double(env["LUSTRO_SNAPSHOT_DELAY"] ?? "") ?? 8
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }
}
