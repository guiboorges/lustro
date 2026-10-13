import AppKit
import LimpoCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Section("Removing files") {
                Picker("When cleaning", selection: $app.settings.removalMode) {
                    Text("Move to Trash (recommended)").tag(RemovalMode.trash)
                    Text("Delete permanently").tag(RemovalMode.permanent)
                }
                .pickerStyle(.radioGroup)
                Toggle("Dry run: show what would be removed without removing anything", isOn: $app.settings.dryRun)
            }

            Section("Permissions") {
                LabeledContent("Full Disk Access") {
                    HStack {
                        Label(app.hasFullDiskAccess ? "Granted" : "Not granted",
                              systemImage: app.hasFullDiskAccess ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(app.hasFullDiskAccess ? .green : .secondary)
                        Button("Open System Settings") { app.openFullDiskAccessSettings() }
                        Button("Check Again") { app.refreshPermissions() }
                    }
                }
                Text("Needed to clean sandboxed app caches and logs, Mail downloads and device backups. Without it those categories are skipped.")
                    .font(.caption).foregroundStyle(.secondary)
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
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(category.title)
                                    RiskBadge(risk: category.risk)
                                }
                                Text(category.section).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("Dev Purge") {
                Stepper("Preselect projects untouched for \(app.settings.inactiveDaysForAutoSelect) days or more",
                        value: $app.settings.inactiveDaysForAutoSelect, in: 0...365, step: 5)
                PathListEditor(title: "Project folders", paths: $app.settings.projectRoots,
                               placeholder: "Using defaults: " + ProjectArtifactScanner.defaultRoots()
                                .map { $0.lastPathComponent }.joined(separator: ", "))
            }

            Section("Ignore list") {
                PathListEditor(title: "Never scan or remove", paths: $app.settings.ignoredPaths,
                               placeholder: "Nothing ignored. Right-click any item and choose Always Ignore.",
                               allowFiles: true)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 520)
        .onAppear { app.refreshPermissions() }
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
                    Button { paths.removeAll { $0 == path } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
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
