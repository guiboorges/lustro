import AppKit
import CoreServices
import LimpoCore
import Observation
import SwiftUI

@MainActor @Observable
final class UninstallerModel {
    private(set) var apps: [InstalledApp] = []
    private(set) var isLoading = false
    var selectedAppID: String?
    var search = ""
    let review = ReviewModel()

    var selectedApp: InstalledApp? { apps.first { $0.id == selectedAppID } }

    var filteredApps: [InstalledApp] {
        search.isEmpty ? apps : apps.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search)
        }
    }

    func load(ignoredPaths: [URL]) {
        isLoading = true
        Task {
            apps = await Task.detached(priority: .userInitiated) {
                Uninstaller(ignoredPaths: ignoredPaths).installedApps()
            }.value
            isLoading = false
        }
    }

    func plan(for app: InstalledApp, ignoredPaths: [URL]) {
        review.scan(preselection: .smart) { _ in Uninstaller(ignoredPaths: ignoredPaths).removalPlan(for: app) }
    }

    func appRemoved(_ removed: [ScanItem]) {
        let removedPaths = Set(removed.map(\.url.path))
        if let app = selectedApp, removedPaths.contains(app.url.standardizedFileURL.path) {
            apps.removeAll { $0.id == app.id }
            selectedAppID = nil
        }
    }

    func runningInstances(of app: InstalledApp) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
    }

    /// When the app was last opened, from Spotlight metadata.
    func lastUsed(_ app: InstalledApp) -> Date? {
        guard let item = MDItemCreate(nil, app.url.path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

struct UninstallerView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: UninstallerModel

    var body: some View {
        HStack(spacing: 0) {
            appList
                .frame(width: 290)
                .background(.quaternary.opacity(0.2))
                .overlay(alignment: .trailing) { Divider() }
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { if model.apps.isEmpty { model.load(ignoredPaths: app.settings.ignoredURLs) } }
        .onChange(of: model.apps) { _, apps in
            if let id = DevSnapshot.selectBundleID, model.selectedAppID == nil {
                model.selectedAppID = apps.first { $0.bundleID == id }?.id
            }
        }
    }

    private var appList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Uninstaller").font(.title2.weight(.bold))
                Spacer()
                Button { model.load(ignoredPaths: app.settings.ignoredURLs) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Reload apps")
                    .disabled(model.isLoading)
            }
            .padding(.horizontal, 14).padding(.top, 20)
            TextField("Search \(model.apps.count) apps", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 14)
            if model.isLoading {
                ScanningView(message: "Finding apps…", fraction: nil)
            } else {
                List(model.filteredApps, selection: $model.selectedAppID) { item in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name).lineLimit(1)
                            Text(item.version.map { "Version \($0)" } ?? item.bundleID)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(item.size.formattedBytes).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(item.id)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .onChange(of: model.selectedAppID) { _, _ in
                    if let selected = model.selectedApp { model.plan(for: selected, ignoredPaths: app.settings.ignoredURLs) }
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let selected = model.selectedApp {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 16) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: selected.url.path)).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selected.name).font(.title.weight(.bold))
                        Text([selected.bundleID, selected.version.map { "Version \($0)" }].compactMap { $0 }.joined(separator: " · "))
                            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        if let last = model.lastUsed(selected) {
                            Label("Last opened \(last.relativeDescription)", systemImage: "clock")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 14)

                if !model.runningInstances(of: selected).isEmpty {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("\(selected.name) is running. It will be asked to quit before uninstalling.")
                        Spacer()
                    }
                    .padding(10)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 24).padding(.bottom, 8)
                }
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield").foregroundStyle(.green)
                    Text("Support files are matched by the exact bundle ID \(selected.bundleID) — never by a similar name.")
                        .font(.callout)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 24).padding(.bottom, 8)

                switch model.review.phase {
                case .scanning:
                    ScanningView(message: "Looking for support files…", fraction: nil)
                default:
                    if let report = model.review.lastReport {
                        ReportBanner(report: report) { model.review.dismissReport() }.padding(.horizontal, 24)
                    }
                    ReviewList(model: model.review)
                    ActionBar(model: model.review, module: "Uninstaller", extraAllowedRoots: Uninstaller().searchRoots,
                              actionTitle: "Uninstall…") { removed in model.appRemoved(removed) }
                }
            }
        } else {
            ContentUnavailableView("Select an app", systemImage: "shippingbox",
                                   description: Text("Apple apps are not listed because macOS needs them."))
        }
    }
}
