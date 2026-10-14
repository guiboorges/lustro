import AppKit
import LimpoCore
import Observation
import SwiftUI

@MainActor @Observable
final class SpaceLensModel {
    private(set) var index: SpaceIndex?
    private(set) var isBuilding = false
    private(set) var progressMessage = ""
    private(set) var path: [URL] = []
    private(set) var children: [SpaceNode] = []
    var selection = Set<String>()
    private(set) var lastReport: RemovalReport?
    private var task: Task<Void, Never>?

    var current: URL? { path.last }
    var currentSize: Int64 { children.reduce(0) { $0 + $1.size } }
    var selectedNodes: [SpaceNode] { children.filter { selection.contains($0.id) } }

    func build(root: URL) {
        task?.cancel()
        isBuilding = true
        progressMessage = "Measuring \(root.path.abbreviatingHome)…"
        lastReport = nil
        let index = SpaceIndex(root: root)
        let progress: ProgressHandler = { [weak self] p in
            Task { @MainActor in self?.progressMessage = p.message }
        }
        task = Task {
            await Task.detached(priority: .userInitiated) { index.build(progress: progress) }.value
            guard !Task.isCancelled else { return }
            self.index = index
            path = [index.root]
            reloadChildren()
            isBuilding = false
        }
    }

    func cancel() {
        task?.cancel()
        isBuilding = false
    }

    func open(_ node: SpaceNode) {
        guard node.isDirectory else { return }
        path.append(node.url)
        reloadChildren()
    }

    func go(to level: Int) {
        guard level < path.count else { return }
        path = Array(path.prefix(level + 1))
        reloadChildren()
    }

    func reloadChildren() {
        guard let index, let current else { return }
        children = index.children(of: current)
        selection = []
    }

    func remove(with remover: Remover, onFinished: @escaping @MainActor (RemovalReport) -> Void) {
        let nodes = selectedNodes
        let items = nodes.map { ScanItem(url: $0.url, size: $0.size, isDirectory: $0.isDirectory) }
        task = Task {
            let report = await Task.detached { await remover.remove(items) }.value
            lastReport = report
            if !report.dryRun {
                for item in report.removed { index?.forget(item.url, size: item.size) }
            }
            reloadChildren()
            onFinished(report)
        }
    }

    /// Stable colour per entry, following the design's treemap palette.
    func color(for node: SpaceNode) -> Color {
        guard let index = children.firstIndex(of: node) else { return .gray }
        return node.isDirectory ? Palette.sequence[index % Palette.sequence.count] : .gray
    }
}

struct SpaceLensView: View {
    @Environment(AppModel.self) private var app
    let model: SpaceLensModel
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(title: "Space Lens", subtitle: "See what takes up space. Click a block to look inside.",
                         symbol: Module.spaceLens.symbol, tint: Module.spaceLens.tint) {
                if model.isBuilding {
                    Button("Stop") { model.cancel() }
                } else {
                    Button("Choose Folder…") { chooseFolder() }
                    Button(model.index == nil ? "Scan Home" : "Rescan") {
                        model.build(root: model.index?.root ?? FileManager.default.homeDirectoryForCurrentUser)
                    }
                }
            }
            if model.isBuilding {
                ScanningView(message: model.progressMessage, fraction: nil)
            } else if model.index == nil {
                VStack(spacing: 16) {
                    IconTile(symbol: Module.spaceLens.symbol, tint: Module.spaceLens.tint, size: 72)
                    Text("Measure your home folder to see where your space goes.").font(.title3)
                    Button { model.build(root: FileManager.default.homeDirectoryForCurrentUser) } label: {
                        Label("Scan Home Folder", systemImage: "magnifyingglass").padding(.horizontal, 12).padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    if !app.hasFullDiskAccess { FullDiskAccessHint() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                browser
            }
        }
        .confirmationDialog("Remove \(model.selectedNodes.count) item\(model.selectedNodes.count == 1 ? "" : "s")?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button(app.settings.removalMode == .permanent ? "Delete Permanently" : "Move to Trash",
                   role: app.settings.removalMode == .permanent ? .destructive : nil) {
                model.remove(with: Remover(policy: app.settings.policy(), mode: app.settings.removalMode,
                                           dryRun: app.settings.dryRun)) { report in
                    app.record(module: "Space Lens", report: report, rules: [:], quitApps: [])
                }
            }
        } message: {
            Text("Protected folders such as Documents, Desktop or Library are always skipped.")
        }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            HStack {
                Breadcrumbs(path: model.path) { model.go(to: $0) }
                if let index = model.index {
                    Text("\(model.currentSize.formattedBytes) · \(index.scannedFiles.formatted()) files scanned")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 28).padding(.bottom, 12)
            if let report = model.lastReport {
                ReportBanner(report: report) {}.padding(.horizontal, 28).padding(.bottom, 8)
            }
            HStack(spacing: 16) {
                Treemap(model: model)
                    .padding(6)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                SpaceList(model: model)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
                    .frame(width: 360)
            }
            .padding(.horizontal, 28).padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text(model.selection.isEmpty
                     ? "Select items to remove · protected folders like Documents and Library can't be selected"
                     : "\(model.selectedNodes.map(\.name).joined(separator: ", ")) selected")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                let size = model.selectedNodes.reduce(Int64(0)) { $0 + $1.size }
                Text(size.formattedBytes).font(.title3.monospacedDigit().weight(.semibold))
                Button(app.settings.removalMode == .permanent ? "Delete…" : "Move to Trash…") { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .tint(app.settings.removalMode == .permanent ? .red : .accentColor)
                    .controlSize(.large)
                    .disabled(model.selection.isEmpty)
            }
            .padding(.horizontal, 28).padding(.vertical, 12)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK, let url = panel.url { model.build(root: url) }
    }
}

struct Breadcrumbs: View {
    let path: [URL]
    let go: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(path.enumerated()), id: \.offset) { index, url in
                    if index > 0 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                    Button(index == 0 ? url.path.abbreviatingHome : url.lastPathComponent) { go(index) }
                        .buttonStyle(.plain)
                        .foregroundStyle(index == path.count - 1 ? .primary : .secondary)
                        .fontWeight(index == path.count - 1 ? .semibold : .regular)
                }
                Spacer()
            }
        }
    }
}

struct SpaceList: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: SpaceLensModel

    var body: some View {
        List(model.children) { node in
            HStack(spacing: 8) {
                Checkbox(state: model.selection.contains(node.id) ? .on : .off) {
                    if model.selection.contains(node.id) { model.selection.remove(node.id) } else { model.selection.insert(node.id) }
                }
                .disabled(!app.settings.policy().isAllowed(node.url))
                .opacity(app.settings.policy().isAllowed(node.url) ? 1 : 0.3)
                Image(nsImage: NSWorkspace.shared.icon(forFile: node.url.path)).resizable().frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(node.name).lineLimit(1).truncationMode(.middle)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.06))
                            Capsule().fill(model.color(for: node)).frame(width: max(geo.size.width * share(node), 3))
                        }
                    }
                    .frame(height: 4)
                }
                Text(node.size.formattedBytes).font(.callout.monospacedDigit()).frame(minWidth: 70, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .listRowBackground(model.selection.contains(node.id) ? Color.accentColor.opacity(0.1) : Color.clear)
            .onTapGesture(count: 2) { model.open(node) }
            .contextMenu {
                if node.isDirectory { Button("Open") { model.open(node) } }
                Button("Show in Finder") { app.reveal(node.url) }
            }
        }
        .listStyle(.inset)
    }

    private func share(_ node: SpaceNode) -> CGFloat {
        let total = max(model.currentSize, 1)
        return CGFloat(Double(node.size) / Double(total))
    }
}

/// Squarified treemap of the largest entries; click a folder to open it.
struct Treemap: View {
    let model: SpaceLensModel
    @State private var hovered: String?
    private var nodes: [SpaceNode] { model.children }

    var body: some View {
        GeometryReader { geo in
            let shown = Array(nodes.filter { $0.size > 0 }.prefix(60))
            let rects = Squarify.layout(sizes: shown.map { Double($0.size) }, in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(zip(shown, rects)), id: \.0.id) { node, rect in
                    let color = model.color(for: node)
                    let selected = model.selection.contains(node.id)
                    RoundedRectangle(cornerRadius: 8)
                        .fill(color.opacity(hovered == node.id ? 1 : 0.82))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white, lineWidth: selected ? 3 : 0))
                        .overlay(alignment: .topLeading) {
                            if rect.width > 70 && rect.height > 38 {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(node.name).font(.callout.weight(.semibold)).lineLimit(1)
                                    Text(node.size.formattedBytes).font(.caption)
                                }
                                .foregroundStyle(.white)
                                .padding(8)
                            }
                        }
                        .frame(width: max(rect.width - 4, 0), height: max(rect.height - 4, 0))
                        .offset(x: rect.minX + 2, y: rect.minY + 2)
                        .onHover { hovered = $0 ? node.id : nil }
                        .onTapGesture { model.open(node) }
                        .help("\(node.name) — \(node.size.formattedBytes)")
                }
            }
        }
    }
}

extension Treemap {
    /// `hashValue` is seeded per launch; colours should stay the same between runs.
    static func stableHash(_ s: String) -> UInt64 {
        s.utf8.reduce(5381) { ($0 &* 33) &+ UInt64($1) }
    }
}

/// Squarified treemap layout (Bruls, Huizing & van Wijk).
enum Squarify {
    static func layout(sizes: [Double], in rect: CGRect) -> [CGRect] {
        let total = sizes.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return sizes.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / total
        let areas = sizes.map { $0 * scale }
        var result: [CGRect] = []
        var remaining = rect
        var row: [Double] = []
        var queue = areas[...]

        func worst(_ row: [Double], _ side: Double) -> Double {
            guard let maxA = row.max(), let minA = row.min(), minA > 0 else { return .infinity }
            let s = row.reduce(0, +)
            return max(side * side * maxA / (s * s), (s * s) / (side * side * minA))
        }

        func place(_ row: [Double]) {
            let s = row.reduce(0, +)
            if remaining.width >= remaining.height {
                let w = s / Double(remaining.height)
                var y = remaining.minY
                for a in row {
                    let h = a / w
                    result.append(CGRect(x: remaining.minX, y: y, width: w, height: h))
                    y += h
                }
                remaining = CGRect(x: remaining.minX + w, y: remaining.minY, width: max(remaining.width - w, 0), height: remaining.height)
            } else {
                let h = s / Double(remaining.width)
                var x = remaining.minX
                for a in row {
                    let w = a / h
                    result.append(CGRect(x: x, y: remaining.minY, width: w, height: h))
                    x += w
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + h, width: remaining.width, height: max(remaining.height - h, 0))
            }
        }

        while let next = queue.first {
            let side = Double(min(remaining.width, remaining.height))
            if row.isEmpty || worst(row + [next], side) <= worst(row, side) {
                row.append(next)
                queue = queue.dropFirst()
            } else {
                place(row)
                row = []
            }
        }
        if !row.isEmpty { place(row) }
        return result
    }
}
