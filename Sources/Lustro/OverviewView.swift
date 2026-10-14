import LustroCore
import SwiftUI

/// Home dashboard: what can be freed, disk usage, junk by type, largest folders.
struct OverviewView: View {
    @Environment(AppModel.self) private var app
    @Binding var module: Module
    let cleanup: ReviewModel
    let devPurge: ReviewModel
    let spaceLens: SpaceLensModel
    let rescan: () -> Void

    private var scanning: Bool { cleanup.phase == .scanning || devPurge.phase == .scanning }

    var body: some View {
        VStack(spacing: 20) {
            PanelHeader(title: "Overview", subtitle: subtitle) {
                Button("Open History") { module = .history }.buttonStyle(OutlineButtonStyle())
                Button(scanning ? "Scanning…" : "Scan Again") { rescan() }
                    .buttonStyle(InkButtonStyle())
                    .disabled(scanning)
            }
            kpis
            HStack(alignment: .top, spacing: 20) {
                DiskGaugeCard(junk: cleanup.totalSize).frame(width: 270)
                JunkByTypeCard(model: cleanup) { module = .cleanup }.frame(width: 290)
                LargestFoldersCard(model: spaceLens) { module = .spaceLens }
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 20) {
                ActionPill(dark: true,
                           progress: cleanup.totalSize > 0 ? Double(cleanup.selectedSize) / Double(cleanup.totalSize) : 0,
                           ringLabel: shortSize(cleanup.selectedSize),
                           title: cleanup.phase == .scanning ? "Scanning…" : "Cleanup ready",
                           detail: "\(cleanup.selectedItems.count) items · " + (app.settings.removalMode == .trash ? "all go to the Trash" : "deleted permanently")) {
                    module = .cleanup
                }
                let inactive = devPurge.groups.filter(\.autoSelect)
                ActionPill(dark: false,
                           progress: devPurge.groups.isEmpty ? 0 : Double(inactive.count) / Double(devPurge.groups.count),
                           ringLabel: "\(inactive.count)", tint: Theme.safe,
                           title: "Dev Purge",
                           detail: "\(inactive.count) inactive project\(inactive.count == 1 ? "" : "s") · \(inactive.reduce(Int64(0)) { $0 + $1.totalSize }.formattedBytes)") {
                    module = .devPurge
                }
                SafeByDesignCard().frame(width: 290)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var subtitle: String {
        if scanning { return "Scanning… nothing is removed until you review it" }
        if let date = cleanup.lastScanDate {
            return "Last scan \(date.relativeTime) · nothing is removed until you review it"
        }
        return "Nothing is removed until you review it"
    }

    private var kpis: some View {
        let restorable = app.historyEntries.flatMap { $0.restorableItems() }
        let runs = app.historyEntries.filter { !$0.restorableItems().isEmpty }.count
        let disk = app.disk
        let used = disk.map { max($0.total - $0.available, 0) } ?? 0
        return HStack(spacing: 20) {
            KPICard(label: "Can be freed", value: number(cleanup.selectedSize), unit: unit(cleanup.selectedSize),
                    detail: "of \(cleanup.totalSize.formattedBytes) found · \(cleanup.selectedItems.count) items",
                    bars: cleanup.sectionTotals.map { Double($0.total) }.sorted())
            KPICard(label: "Disk used", value: number(used), unit: unit(used),
                    detail: disk.map { "of \($0.total.formattedBytes) · \($0.available.formattedBytes) free" } ?? "")
            KPICard(label: "Restorable", value: number(restorable.reduce(0) { $0 + $1.size }), unit: unit(restorable.reduce(0) { $0 + $1.size }),
                    detail: runs == 0 ? "nothing in the Trash from Lustro" : "still in the Trash · \(runs) run\(runs == 1 ? "" : "s")")
        }
    }
}

// MARK: - Byte formatting split into number + unit ("8.9" + "GB")

private func parts(_ bytes: Int64) -> (String, String) {
    if bytes <= 0 { return ("0", "GB") }
    let text = bytes.formattedBytes
    guard let space = text.lastIndex(where: { $0 == " " || $0 == "\u{00A0}" }) else { return (text, "") }
    return (String(text[..<space]), String(text[text.index(after: space)...]))
}
func number(_ bytes: Int64) -> String { parts(bytes).0 }
func unit(_ bytes: Int64) -> String { parts(bytes).1 }
func shortSize(_ bytes: Int64) -> String { bytes == 0 ? "0" : parts(bytes).0 }

// MARK: - Cards

struct DiskGaugeCard: View {
    @Environment(AppModel.self) private var app
    let junk: Int64

    var body: some View {
        let disk = app.disk
        let total = Double(max(disk?.total ?? 1, 1))
        let used = Double(max((disk?.total ?? 0) - (disk?.available ?? 0), 0))
        VStack(spacing: 12) {
            Text("Disk usage").font(.lTitle3).frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            ZStack(alignment: .bottom) {
                GaugeArc(from: 0, to: 1).stroke(Theme.sand, style: StrokeStyle(lineWidth: 28, lineCap: .butt))
                GaugeArc(from: 0, to: used / total)
                    .stroke(LinearGradient(colors: [Theme.orange300, Color(hex: 0xD9520F)], startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 28, lineCap: .butt))
                GaugeArc(from: max(0, (used - Double(junk)) / total), to: used / total)
                    .stroke(Theme.chartInk, style: StrokeStyle(lineWidth: 28, lineCap: .butt))
                Text("\(Int((used / total * 100).rounded()))%").font(.lMetric).padding(.bottom, 2)
            }
            .frame(width: 200, height: 112)
            Spacer(minLength: 0)
            Text(junk > 0 ? "\(junk.formattedBytes) of it is junk Lustro can remove" : "Scan to see how much is junk")
                .font(.lCaption).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .frame(maxHeight: .infinity)
        .lustroCard()
    }
}

/// Upper half-circle arc between two fractions (0 = left, 1 = right).
struct GaugeArc: Shape {
    let from: Double
    let to: Double

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width / 2, rect.height) - 14
        let center = CGPoint(x: rect.midX, y: rect.maxY)
        var path = Path()
        path.addArc(center: center, radius: radius,
                    startAngle: .degrees(180 + 180 * from), endAngle: .degrees(180 + 180 * min(to, 1)), clockwise: false)
        return path
    }
}

struct JunkByTypeCard: View {
    let model: ReviewModel
    let open: () -> Void

    var body: some View {
        let totals = model.sectionTotals
        let total = max(model.totalSize, 1)
        VStack(alignment: .leading, spacing: 12) {
            Text("Junk by type").font(.lTitle3)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(number(model.totalSize)).font(.lMetric).monospacedDigit()
                Text("\(unit(model.totalSize)) found").font(.lCallout).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            ForEach(Array(totals.enumerated()), id: \.element.name) { index, section in
                HStack(spacing: 8) {
                    Circle().fill(Palette.sectionColor(index)).frame(width: 8, height: 8)
                    Text(section.name).font(.lCallout)
                    Spacer()
                    Text("\(Int((Double(section.total) / Double(total) * 100).rounded()))%")
                        .font(.lCalloutStrong).foregroundStyle(Theme.textSecondary).monospacedDigit()
                }
            }
            if totals.isEmpty {
                Text(model.phase == .scanning ? "Scanning…" : "Run a scan to see what's taking space.")
                    .font(.lCallout).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            Button(action: open) { Text("Review in Cleanup").frame(maxWidth: .infinity) }
                .buttonStyle(OutlineButtonStyle())
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .frame(maxHeight: .infinity)
        .lustroCard()
    }
}

struct LargestFoldersCard: View {
    let model: SpaceLensModel
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: open) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Largest folders").font(.lTitle3)
                        Text(model.current.map { $0.path.abbreviatingHome + " · from Space Lens" } ?? "From Space Lens")
                            .font(.lCaption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Theme.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if model.children.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "chart.pie").font(.system(size: 28)).foregroundStyle(Theme.orange300)
                    Text("Map your disk to see what takes up space.").font(.lCallout).foregroundStyle(Theme.textSecondary)
                    Button("Open Space Lens", action: open).buttonStyle(OutlineButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                MiniTreemap(nodes: Array(model.children.prefix(8)))
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .lustroCard()
    }
}

struct MiniTreemap: View {
    let nodes: [SpaceNode]

    var body: some View {
        GeometryReader { geo in
            let rects = Squarify.layout(sizes: nodes.map { Double($0.size) }, in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(zip(nodes.indices, rects)), id: \.0) { index, rect in
                    let color = Theme.chart[index % Theme.chart.count]
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(color)
                        .overlay(alignment: .topLeading) {
                            if rect.width > 64 && rect.height > 42 {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(nodes[index].name).font(.lCalloutStrong).lineLimit(1)
                                    Text(nodes[index].size.formattedBytes).font(.lCaption).opacity(0.75)
                                }
                                .foregroundStyle(Theme.isDark(color) ? Theme.onBrand : Theme.textPrimary)
                                .padding(10)
                            }
                        }
                        .frame(width: max(rect.width - 6, 0), height: max(rect.height - 6, 0))
                        .offset(x: rect.minX + 3, y: rect.minY + 3)
                }
            }
        }
    }
}

struct ActionPill: View {
    let dark: Bool
    let progress: Double
    let ringLabel: String
    var tint: Color = Theme.orange500
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Ring(progress: progress, label: ringLabel, tint: tint, onDark: dark, size: 54)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.lTitle3).foregroundStyle(dark ? Theme.onBrand : Theme.textPrimary).lineLimit(1)
                    Text(detail).font(.lCaption).foregroundStyle(dark ? Theme.onBrandMuted : Theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Circle()
                    .fill(dark ? AnyShapeStyle(Theme.buttonGradient) : AnyShapeStyle(Theme.card))
                    .frame(width: 36, height: 36)
                    .overlay { Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(dark ? Theme.onBrand : Theme.textPrimary) }
            }
            .padding(.leading, 12).padding(.trailing, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(dark ? Theme.ink : Theme.sunken, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct SafeByDesignCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Lustro").overline(Theme.onBrandMuted)
            Text("Safe by design").font(.lTitle2).foregroundStyle(Theme.onBrand)
            Text("Every item explains why it's safe. Put anything back from History.")
                .font(.lCaption).foregroundStyle(Theme.onBrandMuted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach(["Trash by default", "Why? on every item"], id: \.self) { label in
                    Text(label).font(.lCaption).foregroundStyle(Theme.onBrand)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.white.opacity(0.24), in: Capsule())
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .trailing) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 110, weight: .ultraLight))
                .foregroundStyle(.white)
                .opacity(0.16)
                .offset(x: 18)
        }
        .background(Theme.promoGradient)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
