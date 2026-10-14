import AppKit
import LustroCore
import SwiftUI

@main
struct LustroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .frame(minWidth: 1000, minHeight: 640)
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
    case cleanup, devPurge, spaceLens, uninstaller, history, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cleanup: "Cleanup"
        case .devPurge: "Dev Purge"
        case .spaceLens: "Space Lens"
        case .uninstaller: "Uninstaller"
        case .history: "History"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .cleanup: "sparkles"
        case .devPurge: "hammer"
        case .spaceLens: "chart.pie"
        case .uninstaller: "shippingbox"
        case .history: "clock.arrow.circlepath"
        case .settings: "slider.horizontal.3"
        }
    }

    /// Module colours, matching the sidebar icons in the design.
    var tint: Color {
        switch self {
        case .cleanup: .blue
        case .devPurge: .orange
        case .spaceLens: .purple
        case .uninstaller: .pink
        case .history: .indigo
        case .settings: .gray
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
                    navItem(.cleanup, detail: cleanup.groups.isEmpty ? nil : cleanup.selectedSize.formattedBytes)
                    navItem(.devPurge, detail: devPurge.groups.isEmpty ? nil : devPurge.selectedSize.formattedBytes)
                    navItem(.spaceLens)
                    navItem(.uninstaller)
                }
                Section("Activity") {
                    navItem(.history, detail: app.historyEntries.isEmpty ? nil : "\(app.historyEntries.count) run\(app.historyEntries.count == 1 ? "" : "s")")
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    StorageCard(freeable: cleanup.selectedSize + devPurge.selectedSize)
                    Button { module = .settings } label: {
                        Label(Module.settings.title, systemImage: Module.settings.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(module == .settings ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            switch module ?? .cleanup {
            case .cleanup: CleanupView(model: cleanup)
            case .devPurge: DevPurgeView(model: devPurge)
            case .spaceLens: SpaceLensView(model: spaceLens)
            case .uninstaller: UninstallerView(model: uninstaller)
            case .history: HistoryView()
            case .settings: SettingsView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app.refreshPermissions()
            app.refreshDisk()
        }
        .task {
            guard DevSnapshot.autoScan, let catalog = app.catalog else { return }
            switch module {
            case .cleanup:
                let scanner = JunkScanner(catalog: catalog, policy: app.settings.policy(), hasFullDiskAccess: app.hasFullDiskAccess)
                cleanup.scan(preselection: app.settings.preselection) { await scanner.scan(progress: $0) }
            case .devPurge:
                let scanner = ProjectArtifactScanner(roots: app.settings.resolvedProjectRoots, policy: app.settings.policy())
                devPurge.scan(preselection: app.settings.preselection) { await scanner.scan(progress: $0) }
            case .spaceLens:
                spaceLens.build(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(DevSnapshot.spaceLensRoot))
            default:
                break
            }
        }
    }

    private func navItem(_ item: Module, detail: String? = nil) -> some View {
        HStack {
            Label {
                Text(item.title)
            } icon: {
                Image(systemName: item.symbol).foregroundStyle(item.tint)
            }
            Spacer()
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .tag(item)
    }
}

/// Disk usage card at the bottom of the sidebar.
struct StorageCard: View {
    @Environment(AppModel.self) private var app
    let freeable: Int64

    var body: some View {
        if let disk = app.disk {
            let used = max(disk.total - disk.available, 0)
            VStack(alignment: .leading, spacing: 8) {
                Label("Macintosh HD", systemImage: "internaldrive").font(.body.weight(.semibold))
                GeometryReader { geo in
                    let total = CGFloat(max(disk.total, 1))
                    HStack(spacing: 0) {
                        Rectangle().fill(.blue).frame(width: geo.size.width * CGFloat(max(used - freeable, 0)) / total)
                        Rectangle().fill(.orange).frame(width: geo.size.width * CGFloat(min(freeable, used)) / total)
                        Spacer(minLength: 0)
                    }
                    .background(Color.primary.opacity(0.08))
                }
                .frame(height: 6)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                Text("\(used.formattedBytes) of \(disk.total.formattedBytes) used" + (freeable > 0 ? " · \(freeable.formattedBytes) can be freed" : ""))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
