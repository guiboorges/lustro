import AppKit
import LimpoCore
import SwiftUI

/// Everything Limpo removed, with one-click restore for items still in the Trash.
struct HistoryView: View {
    @Environment(AppModel.self) private var app
    @State private var expanded = Set<UUID>()
    @State private var failures: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(title: "History", subtitle: "Everything Limpo removed. Items still in the Trash can be put back where they were.",
                         symbol: "clock.arrow.circlepath", tint: Module.history.tint) {
                Button("Open Trash") {
                    NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
                }
            }
            if app.historyEntries.isEmpty {
                ContentUnavailableView("No removals yet", systemImage: "clock",
                                       description: Text("When you clean something, it shows up here so you can undo it."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if !failures.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Some items couldn't be put back", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                ForEach(failures.sorted(by: { $0.key < $1.key }), id: \.key) { path, reason in
                                    Text("\(path.abbreviatingHome): \(reason)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(10)
                            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        }
                        ForEach(days, id: \.title) { day in
                            Text(day.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(day.entries) { entry in
                                RunCard(entry: entry, expanded: expanded.contains(entry.id),
                                        toggle: { toggle(entry.id) },
                                        restore: { items in failures = app.restore(entry, items: items) })
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 20)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text("History is stored only on this Mac, in ~/Library/Application Support/Limpo/history.json.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 28).padding(.vertical, 10)
            .overlay(alignment: .top) { Divider() }
        }
        .onAppear { app.reloadHistory() }
    }

    private func toggle(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private var days: [(title: String, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [HistoryEntry]] = [:]
        for entry in app.historyEntries {
            let title: String
            if calendar.isDateInToday(entry.date) { title = "Today" }
            else if calendar.isDateInYesterday(entry.date) { title = "Yesterday" }
            else { title = entry.date.formatted(date: .complete, time: .omitted) }
            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(entry)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }
}

struct RunCard: View {
    let entry: HistoryEntry
    let expanded: Bool
    let toggle: () -> Void
    let restore: (Set<String>?) -> Void

    var body: some View {
        let status = entry.status()
        let restorable = Set(entry.restorableItems().map(\.id))
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: toggle) {
                    HStack(spacing: 12) {
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        IconTile(symbol: symbol, tint: entry.dryRun ? .gray : tint)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(entry.module + (entry.dryRun ? " (dry run)" : "")).font(.body.weight(.semibold))
                                StatusBadge(status: status)
                            }
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if !restorable.isEmpty {
                    Button(restorable.count == entry.items.count ? "Restore All" : "Restore \(restorable.count)") { restore(nil) }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(.quaternary.opacity(0.25))
            if expanded {
                ForEach(entry.items) { item in
                    Divider()
                    HStack(spacing: 10) {
                        Image(systemName: "doc").foregroundStyle(.secondary).frame(width: 14)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(URL(fileURLWithPath: item.originalPath).lastPathComponent)
                                .foregroundStyle(item.restored ? .secondary : .primary)
                            Text(URL(fileURLWithPath: item.originalPath).deletingLastPathComponent().path.abbreviatingHome)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(item.size.formattedBytes).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        if item.restored {
                            Text("Restored").font(.caption.weight(.semibold)).foregroundStyle(.green)
                        } else if restorable.contains(item.id) {
                            Button { restore([item.id]) } label: { Label("Put Back", systemImage: "arrow.uturn.backward") }
                                .buttonStyle(.link).font(.caption.weight(.semibold))
                        } else {
                            Text(entry.mode == .permanent ? "Deleted" : "Gone from Trash").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.leading, 54).padding(.trailing, 14).padding(.vertical, 7)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }

    private var subtitle: String {
        var parts = [entry.date.formatted(date: .omitted, time: .shortened),
                     "\(entry.items.count) item\(entry.items.count == 1 ? "" : "s") · \(entry.totalSize.formattedBytes)"]
        if !entry.quitApps.isEmpty { parts.append("quit and reopened \(entry.quitApps.joined(separator: ", "))") }
        return parts.joined(separator: " · ")
    }

    private var symbol: String {
        switch entry.module {
        case "Dev Purge": Module.devPurge.symbol
        case "Space Lens": Module.spaceLens.symbol
        case "Uninstaller": Module.uninstaller.symbol
        default: Module.cleanup.symbol
        }
    }

    private var tint: Color {
        switch entry.module {
        case "Dev Purge": Module.devPurge.tint
        case "Space Lens": Module.spaceLens.tint
        case "Uninstaller": Module.uninstaller.tint
        default: Module.cleanup.tint
        }
    }
}

struct StatusBadge: View {
    let status: HistoryEntry.Status

    var body: some View {
        switch status {
        case .inTrash: Badge(text: "In Trash", tint: .blue)
        case .partlyRestored: Badge(text: "Partly restored", tint: .blue)
        case .restored: Badge(text: "Restored", tint: .green)
        case .emptied: Badge(text: "Trash emptied", tint: .gray)
        case .deletedPermanently: Badge(text: "Deleted permanently", tint: .red)
        case .simulation: Badge(text: "Simulation", tint: .orange)
        }
    }
}
