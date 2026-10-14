import AppKit
import LustroCore
import SwiftUI

/// Everything Lustro removed, with one-click restore for items still in the Trash.
struct HistoryView: View {
    @Environment(AppModel.self) private var app
    @State private var expanded = Set<UUID>()
    @State private var failures: [String: String] = [:]

    var body: some View {
        VStack(spacing: 16) {
            PanelHeader(title: "History", subtitle: "Everything Lustro removed. Items still in the Trash go back exactly where they were.") {
                Button("Open Trash") {
                    NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
                }
                .buttonStyle(OutlineButtonStyle())
            }
            if app.historyEntries.isEmpty {
                PanelPlaceholder(symbol: "clock.arrow.circlepath", title: "No removals yet",
                                 message: "When you clean something, it shows up here so you can put it back.") { EmptyView() }
            } else {
                kpis
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if !failures.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Some items couldn't be put back", systemImage: "exclamationmark.triangle.fill")
                                    .font(.lCalloutStrong).foregroundStyle(Theme.review)
                                ForEach(failures.sorted(by: { $0.key < $1.key }), id: \.key) { path, reason in
                                    Text("\(path.abbreviatingHome): \(reason)").font(.lCaption).foregroundStyle(Theme.textSecondary)
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.review.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        ForEach(days, id: \.title) { day in
                            Text(day.title).overline().padding(.top, 4)
                            ForEach(day.entries) { entry in
                                RunCard(entry: entry, expanded: expanded.contains(entry.id),
                                        toggle: { toggle(entry.id) },
                                        restore: { items in failures = app.restore(entry, items: items) })
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
            Label("History stays on this Mac, in ~/Library/Application Support/Lustro/history.json.", systemImage: "folder")
                .font(.lCaption).foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { app.reloadHistory() }
    }

    private var kpis: some View {
        let monthStart = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? .distantPast
        let thisMonth = app.historyEntries.filter { $0.date >= monthStart && !$0.dryRun }
        let freed = thisMonth.reduce(Int64(0)) { $0 + $1.totalSize }
        let restorable = app.historyEntries.flatMap { $0.restorableItems() }.reduce(Int64(0)) { $0 + $1.size }
        let putBack = app.historyEntries.flatMap(\.items).filter(\.restored)
        return HStack(spacing: 16) {
            KPICard(label: "Removed this month", value: number(freed), unit: unit(freed),
                    detail: thisMonth.count == 1 ? "across 1 run" : "across \(thisMonth.count) runs")
            KPICard(label: "Restorable now", value: number(restorable), unit: unit(restorable), detail: "still in the Trash")
            KPICard(label: "Put back", value: "\(putBack.count)", unit: putBack.count == 1 ? String(localized: "item") : String(localized: "items"),
                    detail: putBack.first.map { LocalizedStringKey(URL(fileURLWithPath: $0.originalPath).lastPathComponent) } ?? "nothing yet")
        }
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
            if calendar.isDateInToday(entry.date) { title = String(localized: "Today") }
            else if calendar.isDateInYesterday(entry.date) { title = String(localized: "Yesterday") }
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
            HStack(spacing: 14) {
                Button(action: toggle) {
                    HStack(spacing: 14) {
                        Tile(symbol: symbol, background: status == .deletedPermanently ? Theme.caution.opacity(0.12) : Theme.peach100,
                             foreground: status == .deletedPermanently ? Theme.caution : Theme.rust700, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(entry.dryRun ? String(localized: "\(moduleName) (dry run)") : moduleName).font(.lBodyStrong)
                                StatusChip(status: status)
                            }
                            Text(subtitle).font(.lCaption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                        Spacer()
                        Text(entry.totalSize.formattedBytes).font(.lTitle3).monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if !restorable.isEmpty {
                    Button(restorable.count == entry.items.count ? "Restore All" : "Restore \(restorable.count)") { restore(nil) }
                        .buttonStyle(InkButtonStyle())
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            if expanded {
                ForEach(entry.items) { item in
                    HStack(spacing: 12) {
                        Image(systemName: "doc").foregroundStyle(Theme.textSecondary).frame(width: 15)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(URL(fileURLWithPath: item.originalPath).lastPathComponent).font(.lCalloutStrong)
                                .foregroundStyle(item.restored ? Theme.textTertiary : Theme.textPrimary)
                            Text(URL(fileURLWithPath: item.originalPath).deletingLastPathComponent().path.abbreviatingHome)
                                .font(.lCaption).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Text(item.size.formattedBytes).font(.lCaption).foregroundStyle(Theme.textSecondary).monospacedDigit()
                        if item.restored {
                            Chip(text: "Restored", tone: .safe)
                        } else if restorable.contains(item.id) {
                            Button { restore([item.id]) } label: { Label("Put Back", systemImage: "arrow.uturn.backward") }
                                .buttonStyle(PillButtonStyle())
                        } else {
                            Text(entry.mode == .permanent ? "Deleted" : "Gone from Trash").font(.lCaption).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .padding(.leading, 72).padding(.trailing, 18).padding(.vertical, 10)
                    .background(Theme.sunken)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
                }
            }
        }
        .lustroCard()
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var subtitle: String {
        var parts = [entry.date.formatted(date: .omitted, time: .shortened),
                     entry.items.count == 1 ? String(localized: "1 item") : String(localized: "\(entry.items.count) items")]
        if !entry.quitApps.isEmpty {
            parts.append(String(localized: "\(entry.quitApps.formatted(.list(type: .and))) quit and reopened"))
        }
        return parts.joined(separator: " · ")
    }

    /// History stores the English module name; show it in the current language.
    private var moduleName: String {
        Module.allCases.first { $0.englishTitle == entry.module }.map { String(localized: $0.title) } ?? entry.module
    }

    private var symbol: String {
        if entry.dryRun { return "eye" }
        switch entry.module {
        case "Dev Purge": return Module.devPurge.symbol
        case "Space Lens": return Module.spaceLens.symbol
        case "Uninstaller": return Module.uninstaller.symbol
        default: return Module.cleanup.symbol
        }
    }
}

struct StatusChip: View {
    let status: HistoryEntry.Status

    var body: some View {
        switch status {
        case .inTrash: Chip(text: "In Trash", tone: .review)
        case .partlyRestored: Chip(text: "Partly restored", tone: .review)
        case .restored: Chip(text: "Restored", tone: .safe)
        case .emptied: Chip(text: "Trash emptied", tone: .neutral)
        case .deletedPermanently: Chip(text: "Deleted permanently", tone: .caution)
        case .simulation: Chip(text: "Simulation", tone: .neutral)
        }
    }
}
