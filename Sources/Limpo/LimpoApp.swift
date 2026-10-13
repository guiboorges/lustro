import AppKit
import LimpoCore
import SwiftUI

@main
struct LimpoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowToolbarStyle(.unified(showsTitle: false))

        Settings {
            SettingsView().environment(app)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (e.g. `swift run`) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        DevSnapshot.scheduleIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum Module: String, CaseIterable, Identifiable {
    case cleanup, devPurge, spaceLens, uninstaller, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cleanup: "Cleanup"
        case .devPurge: "Dev Purge"
        case .spaceLens: "Space Lens"
        case .uninstaller: "Uninstaller"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .cleanup: "sparkles"
        case .devPurge: "hammer"
        case .spaceLens: "circle.hexagongrid"
        case .uninstaller: "trash.square"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var module: Module? = DevSnapshot.initialModule ?? .cleanup
    // Models live here so results survive switching between modules.
    @State private var cleanup = ReviewModel()
    @State private var devPurge = ReviewModel()
    @State private var spaceLens = SpaceLensModel()
    @State private var uninstaller = UninstallerModel()

    var body: some View {
        NavigationSplitView {
            List(selection: $module) {
                Section {
                    ForEach([Module.cleanup, .devPurge, .spaceLens, .uninstaller]) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                Section {
                    Label(Module.settings.title, systemImage: Module.settings.symbol).tag(Module.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch module ?? .cleanup {
            case .cleanup: CleanupView(model: cleanup)
            case .devPurge: DevPurgeView(model: devPurge)
            case .spaceLens: SpaceLensView(model: spaceLens)
            case .uninstaller: UninstallerView(model: uninstaller)
            case .settings: SettingsView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app.refreshPermissions()
        }
        .task {
            guard DevSnapshot.autoScan, let catalog = app.catalog else { return }
            switch module {
            case .cleanup:
                let scanner = JunkScanner(catalog: catalog, policy: app.settings.policy(), hasFullDiskAccess: app.hasFullDiskAccess)
                cleanup.scan { await scanner.scan(progress: $0) }
            case .devPurge:
                let scanner = ProjectArtifactScanner(roots: app.settings.resolvedProjectRoots, policy: app.settings.policy())
                devPurge.scan { await scanner.scan(progress: $0) }
            case .spaceLens:
                spaceLens.build(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(DevSnapshot.spaceLensRoot))
            default:
                break
            }
        }
    }
}
