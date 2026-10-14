import AppKit
import LustroCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings").font(.lTitle1)

                group("Language and appearance", symbol: "paintpalette") {
                    row("Language", "Follows your Mac unless you choose one. Português matches Brazil or Portugal.") {
                        HStack(spacing: 10) {
                            if app.languageNeedsRestart {
                                Button("Restart to Apply") { app.relaunch() }.buttonStyle(.plain).font(.lCaption).foregroundStyle(Theme.rust700)
                            }
                            Segmented(options: [(AppLanguage.system, String(localized: "System")), (.english, "English"), (.portuguese, "Português")],
                                      selection: $app.settings.language, ink: true)
                        }
                    }
                    row("Appearance", nil, last: true) {
                        Segmented(options: [(Appearance.system, String(localized: "System")), (.light, String(localized: "Light")), (.dark, String(localized: "Dark"))],
                                  selection: $app.settings.appearance, ink: true)
                    }
                }

                group("Removing files", symbol: "trash") {
                    row("When cleaning", "Trash lets you put anything back from History. Permanent deletion can't be undone.") {
                        Segmented(options: [(RemovalMode.trash, "Move to Trash"), (.permanent, "Delete permanently")],
                                  selection: $app.settings.removalMode, ink: true)
                    }
                    toggleRow("Dry run", "Show what would be removed without removing anything.", $app.settings.dryRun)
                    toggleRow("Reopen apps after cleaning", "Apps Lustro asked to quit are reopened in the background.",
                              $app.settings.reopenAppsAfterCleaning, last: true)
                }

                group("Preselection", symbol: "sparkles") {
                    row("Select automatically", "Smart preselects safe items and skips anything that needs a look. Caution items are never preselected.") {
                        Segmented(options: [(PreselectionMode.off, "Off"), (.smart, "Smart"), (.allSafe, "All safe")],
                                  selection: $app.settings.preselection, ink: true)
                    }
                    toggleRow("Keep the newest iPhone backup", "Older backups of the same device are still offered.", $app.settings.keepNewestBackup)
                    row("Dev Purge: preselect projects untouched for", nil, last: true) {
                        Segmented(options: [(14, "14 days"), (30, "30 days"), (90, "90 days")],
                                  selection: $app.settings.inactiveDaysForAutoSelect, ink: true)
                    }
                }

                group("Permissions", symbol: "checkmark.shield") {
                    row("Full Disk Access", "Needed for sandboxed app caches, Mail downloads and iPhone backups.", last: true) {
                        HStack(spacing: 10) {
                            if app.hasFullDiskAccess {
                                Chip(text: "Granted", tone: .safe)
                            } else {
                                Chip(text: "Not granted", tone: .neutral)
                                Button("Check Again") { app.refreshPermissions() }.buttonStyle(.plain).font(.lCaption).foregroundStyle(Theme.rust700)
                            }
                            Button("Open System Settings") { app.openFullDiskAccessSettings() }.buttonStyle(OutlineButtonStyle())
                        }
                    }
                }

                group("Cleanup categories", symbol: "list.bullet") {
                    if let catalog = app.catalog {
                        ForEach(Array(catalog.categories.enumerated()), id: \.element.id) { index, category in
                            let colors = Palette.tile(category.risk == .caution ? "red" : category.tint)
                            Toggle(isOn: Binding(
                                get: { !app.settings.disabledCategories.contains(category.id) },
                                set: { on in
                                    if on { app.settings.disabledCategories.removeAll { $0 == category.id } }
                                    else { app.settings.disabledCategories.append(category.id) }
                                }
                            )) {
                                HStack(spacing: 12) {
                                    Tile(symbol: category.icon ?? "folder", background: colors.background, foreground: colors.foreground, size: 30)
                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(spacing: 8) { Text(category.title).font(.lBodyStrong); RiskChip(risk: category.risk) }
                                        Text(category.section).font(.lCaption).foregroundStyle(Theme.textSecondary)
                                    }
                                }
                            }
                            .toggleStyle(LustroToggleStyle())
                            .padding(.horizontal, 20).padding(.vertical, 10)
                            .overlay(alignment: .bottom) {
                                if index < catalog.categories.count - 1 { Rectangle().fill(Theme.border).frame(height: 1) }
                            }
                        }
                    }
                }

                group("More categories", symbol: "shippingbox") {
                    Toggle(isOn: Binding(
                        get: { !app.settings.disabledCategories.contains(LeftoverScanner.groupID) },
                        set: { on in
                            if on { app.settings.disabledCategories.removeAll { $0 == LeftoverScanner.groupID } }
                            else { app.settings.disabledCategories.append(LeftoverScanner.groupID) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) { Text("Leftovers of removed apps").font(.lBodyStrong); RiskChip(risk: .review) }
                            Text("Settings and data of apps that are no longer installed. Never preselected.")
                                .font(.lCaption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .toggleStyle(LustroToggleStyle())
                    .padding(.horizontal, 20).padding(.vertical, 14)
                }

                group("Dev Purge folders", symbol: "folder") {
                    PathListEditor(paths: $app.settings.projectRoots,
                                   placeholder: "Using defaults: " + ProjectArtifactScanner.defaultRoots().map { $0.lastPathComponent }.joined(separator: ", "))
                }

                group("Ignore list", symbol: "eye.slash") {
                    PathListEditor(paths: $app.settings.ignoredPaths,
                                   placeholder: "Nothing ignored yet. Right-click any item and choose Always Ignore.", allowFiles: true)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .onAppear { app.refreshPermissions() }
    }

    private func group<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label { Text(title).overline() } icon: { Image(systemName: symbol).foregroundStyle(Theme.rust700) }
                .font(.system(size: 11, weight: .semibold))
            VStack(spacing: 0) { content() }
                .lustroCard()
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private func row<Control: View>(_ title: String, _ detail: String?, last: Bool = false, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.lBodyStrong)
                if let detail { Text(detail).font(.lCaption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(Theme.border).frame(height: 1) } }
    }

    private func toggleRow(_ title: String, _ detail: String, _ isOn: Binding<Bool>, last: Bool = false) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.lBodyStrong)
                Text(detail).font(.lCaption).foregroundStyle(Theme.textSecondary)
            }
        }
        .toggleStyle(LustroToggleStyle())
        .padding(.horizontal, 20).padding(.vertical, 14)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(Theme.border).frame(height: 1) } }
    }
}

struct PathListEditor: View {
    @Binding var paths: [String]
    let placeholder: String
    var allowFiles = false

    var body: some View {
        VStack(spacing: 0) {
            if paths.isEmpty {
                HStack {
                    Text(placeholder).font(.lCaption).foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            }
            ForEach(paths, id: \.self) { path in
                HStack(spacing: 12) {
                    Image(systemName: "folder").foregroundStyle(Theme.textSecondary)
                    Text(path).font(.lBodyStrong).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { paths.removeAll { $0 == path } } label: {
                        Image(systemName: "minus").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.caution)
                            .frame(width: 28, height: 28).background(Theme.caution.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain).help("Remove from list")
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            }
            HStack {
                Spacer()
                Button("Add…") { add() }.buttonStyle(.plain).font(.lCalloutStrong).foregroundStyle(Theme.rust700)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
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
