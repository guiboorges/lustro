import AppKit
import CoreServices
import LustroCore
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
        HStack(spacing: 18) {
            appList.frame(width: 300)
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { if model.apps.isEmpty { model.load(ignoredPaths: app.settings.ignoredURLs) } }
        .onChange(of: model.apps) { _, apps in
            if let id = DevSnapshot.selectBundleID, model.selectedAppID == nil {
                model.selectedAppID = apps.first { $0.bundleID == id }?.id
            }
        }
        .onChange(of: model.selectedAppID) { _, _ in
            if let selected = model.selectedApp { model.plan(for: selected, ignoredPaths: app.settings.ignoredURLs) }
        }
    }

    private var appList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Uninstaller").font(.lTitle1)
                Spacer()
                Button { model.load(ignoredPaths: app.settings.ignoredURLs) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                    .help("Reload apps").disabled(model.isLoading)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
                TextField("Search \(model.apps.count) apps", text: $model.search).textFieldStyle(.plain).font(.lCallout)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
            Group {
                if model.isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(model.filteredApps) { item in
                                let selected = model.selectedAppID == item.id
                                Button { model.selectedAppID = item.id } label: {
                                    HStack(spacing: 12) {
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 32, height: 32)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.name).font(selected ? .lCalloutStrong : .lCallout).lineLimit(1)
                                            Text(item.version.map { "Version \($0)" } ?? item.bundleID)
                                                .font(.lCaption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                                        }
                                        Spacer()
                                        Text(item.size.formattedBytes).font(.lCaption).foregroundStyle(Theme.textSecondary).monospacedDigit()
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                                    .background(selected ? Theme.peach50 : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(selected ? Theme.orange300 : .clear))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(8)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .lustroCard()
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    @ViewBuilder private var detail: some View {
        if let selected = model.selectedApp {
            VStack(spacing: 16) {
                HStack(spacing: 18) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: selected.url.path)).resizable().frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selected.name).font(.lTitle1)
                        Text([selected.bundleID, selected.version.map { "Version \($0)" }].compactMap { $0 }.joined(separator: " · "))
                            .font(.lCallout).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                        if let last = model.lastUsed(selected) {
                            Label("Last opened \(last.relativeDescription)", systemImage: "clock").font(.lCaption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(model.review.totalSize.formattedBytes).font(.lMetricSmall).monospacedDigit()
                        Text("app + \(max(model.review.allItems.count - 1, 0)) support files").font(.lCaption).foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(20)
                .lustroCard(radius: 22)

                if !model.runningInstances(of: selected).isEmpty {
                    note(symbol: "exclamationmark.triangle", tint: Theme.review,
                         text: "\(selected.name) is running. It will be asked to quit before uninstalling.")
                }
                note(symbol: "checkmark.shield", tint: Theme.safe,
                     text: "Support files are matched by the exact bundle ID \(selected.bundleID) — never by a similar name.")

                switch model.review.phase {
                case .scanning:
                    ScanningView(message: "Looking for support files…", fraction: nil)
                default:
                    if let report = model.review.lastReport {
                        ReportBanner(report: report) { model.review.dismissReport() }
                    }
                    ReviewList(model: model.review)
                    ActionBar(model: model.review, module: "Uninstaller", extraAllowedRoots: Uninstaller().searchRoots,
                              actionTitle: "Uninstall") { removed in model.appRemoved(removed) }
                }
            }
        } else {
            PanelPlaceholder(symbol: "shippingbox", title: "Select an app",
                             message: "Lustro removes the app together with its preferences, caches, containers and saved state. Apple apps are not listed because macOS needs them.") { EmptyView() }
        }
    }

    private func note(symbol: String, tint: Color, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.lCallout)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
