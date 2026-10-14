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
                .frame(minWidth: 1240, minHeight: 780)
                .tint(Theme.orange500)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1340, height: 860)

        Settings {
            SettingsView()
                .environment(app)
                .padding(28)
                .frame(width: 760, height: 720)
                .background(Theme.canvas)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        Typeface.registerBundledFonts()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (e.g. `swift run`) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        DevSnapshot.scheduleIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum Module: String, CaseIterable, Identifiable {
    case overview, cleanup, devPurge, spaceLens, uninstaller, maintenance, devActivity, history, settings
    var id: String { rawValue }

    /// The English name, as stored in History.
    var englishTitle: String {
        switch self {
        case .overview: "Overview"
        case .cleanup: "Cleanup"
        case .devPurge: "Dev Purge"
        case .spaceLens: "Space Lens"
        case .uninstaller: "Uninstaller"
        case .maintenance: "Maintenance"
        case .devActivity: "Dev Activity"
        case .history: "History"
        case .settings: "Settings"
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .overview: "Overview"
        case .cleanup: "Cleanup"
        case .devPurge: "Dev Purge"
        case .spaceLens: "Space Lens"
        case .uninstaller: "Uninstaller"
        case .maintenance: "Maintenance"
        case .devActivity: "Dev Activity"
        case .history: "History"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "internaldrive"
        case .cleanup: "sparkles"
        case .devPurge: "hammer"
        case .spaceLens: "chart.pie"
        case .uninstaller: "shippingbox"
        case .maintenance: "gauge.with.needle"
        case .devActivity: "terminal"
        case .history: "clock.arrow.circlepath"
        case .settings: "slider.horizontal.3"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var module: Module = DevSnapshot.initialModule ?? .overview
    // Models live here so results survive switching between modules.
    @State private var cleanup = ReviewModel()
    @State private var devPurge = ReviewModel()
    @State private var spaceLens = SpaceLensModel()
    @State private var uninstaller = UninstallerModel()
    @State private var maintenance = MaintenanceModel()
    @State private var devActivity = DevActivityModel()

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(module: $module, cleanup: cleanup, devPurge: devPurge, maintenance: maintenance, devActivity: devActivity)
            panel
                .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding([.top, .bottom, .trailing], 10)
        }
        .background(Theme.frameGradient)
        .ignoresSafeArea()
        .font(.lBody)
        .foregroundStyle(Theme.textPrimary)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app.refreshPermissions()
            app.refreshDisk()
        }
        .task {
            if !DevSnapshot.isActive { app.applyAppearance() }
            startInitialScans()
            maintenance.startSampling()
            devActivity.startSampling()
        }
    }

    @ViewBuilder private var panel: some View {
        switch module {
        case .overview: OverviewView(module: $module, cleanup: cleanup, devPurge: devPurge, spaceLens: spaceLens, rescan: rescanAll)
        case .cleanup: CleanupView(model: cleanup)
        case .devPurge: DevPurgeView(model: devPurge)
        case .spaceLens: SpaceLensView(model: spaceLens)
        case .uninstaller: UninstallerView(model: uninstaller)
        case .maintenance: MaintenanceView(model: maintenance)
        case .devActivity: DevActivityView(model: devActivity)
        case .history: HistoryView()
        case .settings: SettingsView()
        }
    }

    /// Scanning only reads the disk, so the Overview can show real numbers on launch.
    private func startInitialScans() {
        if DevSnapshot.autoScan, module == .spaceLens {
            spaceLens.build(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(DevSnapshot.spaceLensRoot))
        }
        if cleanup.phase == .idle { scanCleanup() }
        if devPurge.phase == .idle { scanDevPurge() }
    }

    private func rescanAll() {
        scanCleanup()
        scanDevPurge()
    }

    private func scanCleanup() {
        guard let catalog = app.catalog else { return }
        cleanup.scan(preselection: app.settings.preselection, using: app.cleanupScanner(catalog: catalog))
    }

    private func scanDevPurge() {
        let scanner = ProjectArtifactScanner(roots: app.settings.resolvedProjectRoots, policy: app.settings.policy(),
                                             inactiveDaysForAutoSelect: app.settings.inactiveDaysForAutoSelect)
        devPurge.scan(preselection: app.settings.preselection) { await scanner.scan(progress: $0) }
    }
}

/// Navigation on the gradient frame.
struct Sidebar: View {
    @Environment(AppModel.self) private var app
    @Binding var module: Module
    let cleanup: ReviewModel
    let devPurge: ReviewModel
    let maintenance: MaintenanceModel
    let devActivity: DevActivityModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.card)
                    .frame(width: 34, height: 34)
                    .overlay { Image(systemName: "sparkles").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.rust700) }
                Text("Lustro").font(.lTitle2).foregroundStyle(Theme.onBrand)
            }
            .padding(.leading, 4).padding(.top, 46).padding(.bottom, 26)

            Text("Navigation").overline(Theme.onBrandMuted).padding(.leading, 6).padding(.bottom, 6)
            item(.overview)
            item(.cleanup, detail: cleanup.groups.isEmpty ? nil : cleanup.selectedSize.formattedBytes)
            item(.devPurge, detail: devPurge.groups.isEmpty ? nil : devPurge.selectedSize.formattedBytes)
            item(.spaceLens)
            item(.uninstaller)
            item(.maintenance, detail: maintenance.runaway == nil ? nil : String(localized: "1 alert"))
            item(.devActivity, detail: orphanDetail)
            item(.history, detail: app.historyEntries.isEmpty ? nil : app.historyEntries.count == 1 ? String(localized: "1 run")
                 : String(localized: "\(app.historyEntries.count) runs"))
            Spacer()
            StorageCard(freeable: cleanup.selectedSize + devPurge.selectedSize)
                .padding(.bottom, 8)
            item(.settings)
        }
        .padding(.horizontal, 18).padding(.bottom, 14)
        .frame(width: 244)
    }

    private var orphanDetail: String? {
        let count = devActivity.report.orphans.count
        return count == 0 ? nil : count == 1 ? String(localized: "1 orphan") : String(localized: "\(count) orphans")
    }

    private func item(_ item: Module, detail: String? = nil) -> some View {
        let selected = module == item
        return Button { module = item } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(selected ? Color.white : Color.white.opacity(0.16))
                    .frame(width: 30, height: 30)
                    .overlay {
                        Image(systemName: item.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(selected ? Theme.rust700 : Theme.onBrand)
                    }
                Text(item.title).font(selected ? .lBodyStrong : .lBody).foregroundStyle(Theme.onBrand)
                    .lineLimit(1).fixedSize()
                Spacer(minLength: 2)
                if let detail {
                    Text(detail).font(.lCaption).foregroundStyle(Theme.onBrandMuted).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.75)
                }
            }
            .padding(.leading, 8).padding(.trailing, 10)
            .frame(height: 44)
            .background(selected ? Color.white.opacity(0.24) : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Disk usage, as a glass card on the gradient.
struct StorageCard: View {
    @Environment(AppModel.self) private var app
    let freeable: Int64

    var body: some View {
        if let disk = app.disk {
            let used = max(disk.total - disk.available, 0)
            VStack(alignment: .leading, spacing: 10) {
                Label { Text("Macintosh HD").font(.lCalloutStrong) } icon: { Image(systemName: "internaldrive") }
                    .foregroundStyle(Theme.onBrand)
                GeometryReader { geo in
                    let total = CGFloat(max(disk.total, 1))
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.24))
                        Capsule().fill(Color.white).frame(width: geo.size.width * CGFloat(used) / total)
                    }
                }
                .frame(height: 6)
                Text(freeable > 0 ? "\(used.formattedBytes) of \(disk.total.formattedBytes) used\n\(freeable.formattedBytes) can be freed"
                     : "\(used.formattedBytes) of \(disk.total.formattedBytes) used")
                    .font(.lCaption).foregroundStyle(Theme.onBrandMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}
