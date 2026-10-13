import AppKit
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
        review.scan { _ in Uninstaller(ignoredPaths: ignoredPaths).removalPlan(for: app) }
    }

    func appRemoved(_ removed: [ScanItem]) {
        let removedPaths = Set(removed.map(\.url.path))
        if let app = selectedApp, removedPaths.contains(app.url.standardizedFileURL.path) {
            apps.removeAll { $0.id == app.id }
        }
    }

    func runningInstances(of app: InstalledApp) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
    }
}

struct UninstallerView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: UninstallerModel

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(title: "Uninstaller", subtitle: "Remove apps together with the files they leave behind.",
                         symbol: "trash.square") {
                Button("Reload") { model.load(ignoredPaths: app.settings.ignoredURLs) }
                    .disabled(model.isLoading)
            }
            Divider()
            HSplitView {
                appList.frame(minWidth: 260, idealWidth: 300, maxWidth: 380, maxHeight: .infinity)
                detail.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { if model.apps.isEmpty { model.load(ignoredPaths: app.settings.ignoredURLs) } }
        .onChange(of: model.apps) { _, apps in
            if let id = DevSnapshot.selectBundleID, model.selectedAppID == nil {
                model.selectedAppID = apps.first { $0.bundleID == id }?.id
            }
        }
    }

    private var appList: some View {
        VStack(spacing: 0) {
            TextField("Search apps", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .padding(10)
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
                .onChange(of: model.selectedAppID) { _, _ in
                    if let selected = model.selectedApp { model.plan(for: selected, ignoredPaths: app.settings.ignoredURLs) }
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let selected = model.selectedApp {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: selected.url.path)).resizable().frame(width: 48, height: 48)
                    VStack(alignment: .leading) {
                        Text(selected.name).font(.title3.weight(.semibold))
                        Text(selected.bundleID).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                }
                .padding(16)
                if !model.runningInstances(of: selected).isEmpty {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("\(selected.name) is running. Quit it before uninstalling.")
                        Spacer()
                        Button("Quit \(selected.name)") {
                            model.runningInstances(of: selected).forEach { $0.terminate() }
                        }
                    }
                    .padding(10)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 16)
                }
                switch model.review.phase {
                case .scanning:
                    ScanningView(message: "Looking for support files…", fraction: nil)
                default:
                    if let report = model.review.lastReport {
                        ReportBanner(report: report) { model.review.dismissReport() }.padding(12)
                    }
                    ReviewList(model: model.review)
                    Divider()
                    ActionBar(model: model.review, extraAllowedRoots: Uninstaller().searchRoots,
                              actionTitle: "Uninstall…") { removed in model.appRemoved(removed) }
                }
            }
        } else {
            ContentUnavailableView("Select an app", systemImage: "app.dashed",
                                   description: Text("Apple apps are not listed because macOS needs them."))
        }
    }
}
