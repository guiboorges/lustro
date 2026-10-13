import AppKit

/// Development helper that renders the main window to a PNG and quits.
/// Used to produce README screenshots and to check layouts without screen-recording permission.
///
///     LIMPO_SNAPSHOT=/tmp/shot.png LIMPO_MODULE=devPurge LIMPO_AUTOSCAN=1 build/Limpo.app/Contents/MacOS/Limpo
@MainActor
enum DevSnapshot {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    static var initialModule: Module? { env["LIMPO_MODULE"].flatMap(Module.init(rawValue:)) }
    static var autoScan: Bool { env["LIMPO_AUTOSCAN"] == "1" }
    static var selectBundleID: String? { env["LIMPO_SELECT_APP"] }
    static var spaceLensRoot: String { env["LIMPO_SPACELENS_ROOT"] ?? "" }

    static func scheduleIfRequested() {
        guard let path = env["LIMPO_SNAPSHOT"] else { return }
        // Offscreen rendering skips the window background, so force light mode for legible captures.
        NSApp.appearance = NSAppearance(named: env["LIMPO_SNAPSHOT_DARK"] == "1" ? .darkAqua : .aqua)
        let delay = Double(env["LIMPO_SNAPSHOT_DELAY"] ?? "") ?? 8
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
