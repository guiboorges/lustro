import LimpoCore
import SwiftUI

/// Header + scan/review list + action bar, shared by Cleanup and Dev Purge.
struct ReviewView<EmptyContent: View>: View {
    @Environment(AppModel.self) private var app
    let model: ReviewModel
    let title: String
    let subtitle: String
    let symbol: String
    let scanner: @Sendable (@escaping ProgressHandler) async -> [ScanGroup]
    @ViewBuilder var emptyContent: EmptyContent

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(title: title, subtitle: subtitle, symbol: symbol) {
                if model.phase == .scanning {
                    Button("Stop") { model.cancel() }
                } else {
                    Button(model.groups.isEmpty ? "Scan" : "Scan Again") { model.scan(using: scanner) }
                        .keyboardShortcut("r")
                        .disabled(model.phase == .removing)
                }
            }
            Divider()
            content
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle:
            VStack(spacing: 16) {
                emptyContent
                Button { model.scan(using: scanner) } label: {
                    Label("Scan", systemImage: "magnifyingglass").padding(.horizontal, 12).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .scanning:
            ScanningView(message: model.progressMessage, fraction: model.progressFraction)
        case .reviewing, .removing:
            if model.groups.isEmpty {
                ContentUnavailableView("Nothing to clean", systemImage: "sparkles",
                                       description: Text(model.lastReport == nil ? "Everything here is already tidy." : "All selected items were removed."))
                    .overlay(alignment: .top) { reportBanner }
            } else {
                VStack(spacing: 0) {
                    reportBanner
                    ReviewList(model: model)
                    Divider()
                    ActionBar(model: model)
                }
            }
        }
    }

    @ViewBuilder private var reportBanner: some View {
        if let report = model.lastReport {
            ReportBanner(report: report) { model.dismissReport() }
                .padding([.horizontal, .top], 12)
        }
    }
}

struct ModuleHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            actions
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

struct ScanningView: View {
    let message: String
    let fraction: Double?

    var body: some View {
        VStack(spacing: 14) {
            if let fraction {
                ProgressView(value: fraction).frame(width: 280)
            } else {
                ProgressView().controlSize(.large)
            }
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ReviewList: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: ReviewModel

    var body: some View {
        List {
            ForEach(model.sections, id: \.name) { section in
                Section(section.name) {
                    ForEach(section.groups) { group in
                        GroupRow(model: model, group: group)
                        if model.expanded.contains(group.id) {
                            ForEach(group.items) { item in
                                ItemRow(model: model, item: item)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}

struct Checkbox: View {
    let state: ReviewModel.CheckState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
            .font(.system(size: 15))
            .foregroundStyle(state == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state == .on ? "Selected" : state == .mixed ? "Partly selected" : "Not selected")
    }

    private var symbol: String {
        switch state {
        case .on: "checkmark.square.fill"
        case .mixed: "minus.square.fill"
        case .off: "square"
        }
    }
}

struct GroupRow: View {
    @Bindable var model: ReviewModel
    let group: ScanGroup

    var body: some View {
        HStack(spacing: 10) {
            Checkbox(state: model.state(of: group)) { model.toggle(group) }
            Button {
                if model.expanded.contains(group.id) { model.expanded.remove(group.id) } else { model.expanded.insert(group.id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(model.expanded.contains(group.id) ? 90 : 0))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(group.title).font(.body.weight(.medium))
                            RiskBadge(risk: group.risk)
                        }
                        Text(group.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(group.totalSize.formattedBytes).font(.body.monospacedDigit())
                        Text(itemSummary)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    /// Names for small groups ("node_modules · .next"), a count otherwise.
    private var itemSummary: String {
        if group.items.count <= 3 {
            return group.items.map(\.url.lastPathComponent).joined(separator: " · ")
        }
        return "\(group.items.count) items"
    }
}

struct ItemRow: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: ReviewModel
    let item: ScanItem

    var body: some View {
        HStack(spacing: 10) {
            Checkbox(state: model.selection.contains(item.id) ? .on : .off) { model.toggle(item) }
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(item.url.deletingLastPathComponent().path.abbreviatingHome)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            if let date = item.lastModified {
                Text(date, format: .relative(presentation: .named))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(item.size.formattedBytes).font(.callout.monospacedDigit()).frame(minWidth: 70, alignment: .trailing)
        }
        .padding(.leading, 28)
        .contextMenu {
            Button("Show in Finder") { app.reveal(item.url) }
            Button("Always Ignore") {
                app.ignore(item.url)
                model.selection.remove(item.id)
            }
        }
    }
}

struct RiskBadge: View {
    let risk: RiskLevel

    var body: some View {
        switch risk {
        case .safe: EmptyView()
        case .review:
            Text("Review").font(.caption2.weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.orange.opacity(0.18), in: Capsule())
                .foregroundStyle(.orange)
        case .caution:
            Text("Caution").font(.caption2.weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.red.opacity(0.18), in: Capsule())
                .foregroundStyle(.red)
        }
    }
}

struct ActionBar: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: ReviewModel
    var extraAllowedRoots: [URL] = []
    var actionTitle: String?
    var onRemoved: (@MainActor ([ScanItem]) -> Void)?
    @State private var confirming = false

    private var permanent: Bool { app.settings.removalMode == .permanent }

    var body: some View {
        HStack(spacing: 12) {
            Checkbox(state: model.selection.isEmpty ? .off : model.selection.count == model.allItems.count ? .on : .mixed) {
                model.selectAll(model.selection.isEmpty)
            }
            Text("\(model.selectedItems.count) of \(model.allItems.count) selected")
                .foregroundStyle(.secondary)
            Spacer()
            if model.phase == .removing {
                ProgressView(value: model.progressFraction ?? 0).frame(width: 120)
            }
            if app.settings.dryRun {
                Label("Dry run", systemImage: "eye").font(.caption).foregroundStyle(.secondary)
            }
            Text(model.selectedSize.formattedBytes).font(.title3.monospacedDigit().weight(.semibold))
            Button(actionTitle ?? (permanent ? "Delete…" : "Move to Trash…")) { confirming = true }
                .buttonStyle(.borderedProminent)
                .tint(permanent ? .red : .accentColor)
                .controlSize(.large)
                .disabled(model.selection.isEmpty || model.phase == .removing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button(permanent ? "Delete Permanently" : "Move to Trash", role: permanent ? .destructive : nil) {
                let remover = Remover(policy: app.settings.policy(extraAllowedRoots: extraAllowedRoots),
                                      mode: app.settings.removalMode, dryRun: app.settings.dryRun)
                model.remove(with: remover, onRemoved: onRemoved)
            }
        } message: {
            Text(confirmMessage)
        }
    }

    private var confirmTitle: String {
        "\(permanent ? "Delete" : "Move") \(model.selectedItems.count) item\(model.selectedItems.count == 1 ? "" : "s") (\(model.selectedSize.formattedBytes))?"
    }

    private var confirmMessage: String {
        if app.settings.dryRun { return "Dry run is on: nothing will actually be removed." }
        return permanent
            ? "This cannot be undone. Items already in the Trash are always deleted permanently."
            : "You can restore items from the Trash until you empty it. Items already in the Trash are deleted permanently."
    }
}

struct ReportBanner: View {
    let report: RemovalReport
    let dismiss: () -> Void
    @State private var showFailures = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: report.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(report.failures.isEmpty ? .green : .orange)
                Text(summary).font(.callout.weight(.medium))
                Spacer()
                if !report.failures.isEmpty {
                    Button(showFailures ? "Hide Details" : "Details") { showFailures.toggle() }.buttonStyle(.link)
                }
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            if showFailures {
                ForEach(report.failures) { failure in
                    Text("\(failure.url.path.abbreviatingHome): \(failure.reason)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var summary: String {
        let verb = report.dryRun ? "Would free" : (report.mode == .trash ? "Moved to Trash" : "Freed")
        var text = "\(verb) \(report.freedBytes.formattedBytes) · \(report.removed.count) item\(report.removed.count == 1 ? "" : "s")"
        if !report.failures.isEmpty { text += " · \(report.failures.count) skipped" }
        return text
    }
}

extension String {
    var abbreviatingHome: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return hasPrefix(home) ? "~" + dropFirst(home.count) : self
    }
}
