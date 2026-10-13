import LimpoCore
import SwiftUI

struct CleanupView: View {
    @Environment(AppModel.self) private var app
    let model: ReviewModel

    var body: some View {
        if let catalog = app.catalog {
            let scanner = JunkScanner(
                catalog: catalog,
                policy: app.settings.policy(),
                hasFullDiskAccess: app.hasFullDiskAccess,
                disabledCategories: Set(app.settings.disabledCategories)
            )
            ReviewView(model: model, title: "Cleanup",
                       subtitle: "Caches, logs and leftovers from apps, developer tools and AI tools.",
                       symbol: "sparkles",
                       scanner: { progress in await scanner.scan(progress: progress) }) {
                VStack(spacing: 8) {
                    Text("\(scanner.activeCategories.count) categories ready to scan")
                        .font(.title3)
                    if !app.hasFullDiskAccess {
                        FullDiskAccessHint()
                    }
                }
            }
        } else {
            ContentUnavailableView("Rules could not be loaded", systemImage: "exclamationmark.triangle",
                                   description: Text(app.catalogError ?? ""))
        }
    }
}

struct DevPurgeView: View {
    @Environment(AppModel.self) private var app
    let model: ReviewModel

    var body: some View {
        let roots = app.settings.resolvedProjectRoots
        let scanner = ProjectArtifactScanner(
            roots: roots,
            policy: app.settings.policy(),
            inactiveDaysForAutoSelect: app.settings.inactiveDaysForAutoSelect
        )
        ReviewView(model: model, title: "Dev Purge",
                   subtitle: "node_modules, build folders, virtualenvs and other artifacts your projects can rebuild.",
                   symbol: "hammer",
                   scanner: { progress in await scanner.scan(progress: progress) }) {
            VStack(spacing: 8) {
                Text("Looks for projects in:").font(.title3)
                Text(roots.map { $0.path.abbreviatingHome }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                Text("Projects untouched for \(app.settings.inactiveDaysForAutoSelect)+ days are preselected. Change folders in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct FullDiskAccessHint: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield").foregroundStyle(.orange)
            Text("Grant Full Disk Access to also clean sandboxed app caches, Mail downloads and device backups.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Open Settings") { app.openFullDiskAccessSettings() }.buttonStyle(.link)
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 560)
    }
}
