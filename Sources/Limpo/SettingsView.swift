import AppKit
import LimpoCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Section("Removing files") {
                Picker(selection: $app.settings.removalMode) {
                    Text("Move to Trash").tag(RemovalMode.trash)
                    Text("Delete permanently").tag(RemovalMode.permanent)
                } label: {
                    LabeledText("When cleaning", "Trash lets you restore anything from History until you empty it. Permanent deletion can't be undone.")
                }
                .pickerStyle(.segmented)
                Toggle(isOn: $app.settings.dryRun) {
                    LabeledText("Dry run", "Show what would be removed without removing anything.")
                }
                .toggleStyle(.switch)
                Toggle(isOn: $app.settings.reopenAppsAfterCleaning) {
                    LabeledText("Reopen apps after cleaning", "Apps Limpo asked to quit are reopened in the background.")
                }
                .toggleStyle(.switch)
            }

            Section {
                Picker(selection: $app.settings.preselection) {
                    Text("Off").tag(PreselectionMode.off)
                    Text("Smart").tag(PreselectionMode.smart)
                    Text("All safe").tag(PreselectionMode.allSafe)
                } label: {
                    LabeledText("Select automatically", "Smart preselects safe items and skips anything that needs a look.")
                }
                .pickerStyle(.segmented)
                Toggle(isOn: $app.settings.keepNewestBackup) {
                    LabeledText("Keep the newest iPhone backup", "Older backups of the same device are still offered.")
                }
                .toggleStyle(.switch)
                Picker("Dev Purge: preselect projects untouched for", selection: $app.settings.inactiveDaysForAutoSelect) {
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Preselection")
            } footer: {
                Text("Caution items, like iPhone backups and local AI models, are never preselected.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("Permissions") {
                LabeledContent {
                    HStack {
                        Label(app.hasFullDiskAccess ? "Granted" : "Not granted",
                              systemImage: app.hasFullDiskAccess ? "checkmark" : "xmark.circle")
                            .foregroundStyle(app.hasFullDiskAccess ? .green : .secondary)
                            .font(.callout.weight(.semibold))
                        Button("Open System Settings") { app.openFullDiskAccessSettings() }
                        Button("Check Again") { app.refreshPermissions() }
                    }
                } label: {
                    LabeledText("Full Disk Access", "Needed for sandboxed app caches, Mail downloads and iPhone backups. Without it those are skipped.")
                }
            }

            Section("Cleanup categories") {
                if let catalog = app.catalog {
                    ForEach(catalog.categories) { category in
                        Toggle(isOn: Binding(
                            get: { !app.settings.disabledCategories.contains(category.id) },
                            set: { on in
                                if on { app.settings.disabledCategories.removeAll { $0 == category.id } }
                                else { app.settings.disabledCategories.append(category.id) }
                            }
                        )) {
                            HStack(spacing: 10) {
                                IconTile(symbol: category.icon ?? "folder",
                                         tint: Palette.color(category.tint ?? Palette.tint(forSection: category.section)), size: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text(category.title)
                                        RiskBadge(risk: category.risk)
                                    }
                                    Text(category.section).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.switch)
                    }
                }
            }

            Section("Dev Purge folders") {
                PathListEditor(title: "Project folders", paths: $app.settings.projectRoots,
                               placeholder: "Using defaults: " + ProjectArtifactScanner.defaultRoots()
                                .map { $0.lastPathComponent }.joined(separator: ", "))
            }

            Section {
                PathListEditor(title: "Never scan or remove", paths: $app.settings.ignoredPaths,
                               placeholder: "Nothing ignored yet.", allowFiles: true)
            } header: {
                Text("Ignore list")
            } footer: {
                Text("Right-click any item and choose Always Ignore to add it here.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 520)
        .navigationTitle("Settings")
        .onAppear { app.refreshPermissions() }
    }
}

/// Title with a secondary explanation underneath, as used in macOS Settings.
struct LabeledText: View {
    let title: String
    let detail: String

    init(_ title: String, _ detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PathListEditor: View {
    let title: String
    @Binding var paths: [String]
    let placeholder: String
    var allowFiles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Button("Add…") { add() }
            }
            if paths.isEmpty {
                Text(placeholder).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(paths, id: \.self) { path in
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(path).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { paths.removeAll { $0 == path } } label: { Image(systemName: "minus.circle").foregroundStyle(.red) }
                        .buttonStyle(.plain)
                        .help("Remove from list")
                }
            }
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = allowFiles
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = url.path.abbreviatingHome
            if !paths.contains(path) { paths.append(path) }
        }
    }
}
