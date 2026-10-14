import LustroCore
import SwiftUI

// MARK: - Surfaces

extension View {
    /// White rounded card with the soft warm shadow ("v2/Card").
    func lustroCard(radius: CGFloat = 20) -> some View {
        background(Theme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: Theme.shadow(0.06), radius: 1, y: 1)
            .shadow(color: Theme.shadow(0.05), radius: 12, y: 8)
    }

    /// Strong lift for floating bars, sheets and popovers ("v2/Floating").
    func lustroFloating(radius: CGFloat = 20) -> some View {
        clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: Theme.shadow(0.10), radius: 6, y: 4)
            .shadow(color: Theme.shadow(0.14), radius: 24, y: 20)
    }
}

// MARK: - Buttons

struct InkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.lCalloutStrong)
            .foregroundStyle(Theme.onBrand)
            .padding(.horizontal, 18).frame(height: 40)
            .background(Theme.ink.opacity(configuration.isPressed ? 0.85 : 1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct BrandButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.lCalloutStrong)
            .foregroundStyle(Theme.onBrand)
            .padding(.horizontal, 20).frame(height: 40)
            .background(Theme.buttonGradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: Theme.orange500.opacity(isEnabled ? 0.35 : 0), radius: 8, y: 6)
            .opacity(isEnabled ? (configuration.isPressed ? 0.88 : 1) : 0.45)
    }
}

struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.lCalloutStrong)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 16).frame(height: 40)
            .background(configuration.isPressed ? Theme.sunken : Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
    }
}

/// Small rounded pill, e.g. "Why?" or "Put Back".
struct PillButtonStyle: ButtonStyle {
    var tint: Color = Theme.rust700

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.lCaption)
            .foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(configuration.isPressed ? Theme.sunken : Theme.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.border))
    }
}

// MARK: - Small pieces

struct Chip: View {
    enum Tone { case safe, review, caution, neutral }
    let text: LocalizedStringKey
    let tone: Tone

    private var colors: (Color, Color) {
        switch tone {
        case .safe: (Theme.safe.opacity(0.12), Theme.safe)
        case .review: (Theme.orange500.opacity(0.14), Theme.review)
        case .caution: (Theme.caution.opacity(0.12), Theme.caution)
        case .neutral: (Theme.sunken, Theme.textSecondary)
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(colors.1).frame(width: 6, height: 6)
            Text(text).font(.lCaption).foregroundStyle(colors.1)
        }
        .padding(.leading, 8).padding(.trailing, 9).padding(.vertical, 3)
        .background(colors.0, in: Capsule())
    }
}

struct RiskChip: View {
    let risk: RiskLevel

    var body: some View {
        switch risk {
        case .safe: EmptyView()
        case .review: Chip(text: "Review", tone: .review)
        case .caution: Chip(text: "Caution", tone: .caution)
        }
    }
}

/// Rounded square holding an SF Symbol.
struct Tile: View {
    let symbol: String
    var background: Color = Theme.peach100
    var foreground: Color = Theme.rust700
    var size: CGFloat = 38

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
            .fill(background)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(foreground)
            }
    }
}

struct Checkbox: View {
    let state: ReviewModel.CheckState
    var onDark = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if state == .off {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(onDark ? Color.white.opacity(0.08) : Theme.card)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(onDark ? Color.white.opacity(0.35) : Theme.border, lineWidth: 1.5))
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.buttonGradient)
                    Image(systemName: state == .on ? "checkmark" : "minus")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state == .on ? "Selected" : state == .mixed ? "Partly selected" : "Not selected")
    }
}

/// Stat card: overline label, big metric + unit, context line, optional mini bar chart.
struct KPICard: View {
    let label: LocalizedStringKey
    /// Shown as is: numbers and units are formatted (and localised) by the caller.
    let value: String
    let unit: String
    let detail: LocalizedStringKey
    var bars: [Double]? = nil
    /// Shown as is instead of `detail`, for text that comes from data (a file name) rather than from code.
    var verbatimDetail: String? = nil

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(label).overline()
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value).font(.lMetric).foregroundStyle(Theme.textPrimary).monospacedDigit()
                    Text(unit).font(.lTitle3).foregroundStyle(Theme.textSecondary)
                }
                Group { if let verbatimDetail { Text(verbatim: verbatimDetail) } else { Text(detail) } }
                    .font(.lCaption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let bars, let maxValue = bars.max(), maxValue > 0 {
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(Array(bars.enumerated()), id: \.offset) { index, value in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(index == bars.count - 1 ? Theme.orange500 : Theme.peach100)
                            .frame(width: 8, height: max(6, 42 * value / maxValue))
                    }
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lustroCard()
    }
}

/// Donut progress with a centred value.
struct Ring: View {
    let progress: Double
    let label: String
    var tint: Color = Theme.orange500
    var onDark = false
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            Circle().stroke(onDark ? Color.white.opacity(0.16) : Theme.sand, lineWidth: size * 0.1)
            Circle().trim(from: 0, to: max(0.02, min(progress, 1)))
                .stroke(tint, style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(label).font(.lCalloutStrong).foregroundStyle(onDark ? Theme.onBrand : Theme.textPrimary)
                .minimumScaleFactor(0.6).lineLimit(1).padding(6)
        }
        .frame(width: size, height: size)
    }
}

/// Pill-shaped segmented control. `ink` selection = dark capsule (Settings); otherwise white (filters).
struct Segmented<Value: Hashable>: View {
    let options: [(Value, LocalizedStringKey)]
    @Binding var selection: Value
    var ink = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let (value, label) = option
                let selected = value == selection
                Button { selection = value } label: {
                    Text(label)
                        .font(selected && !ink ? .lCalloutStrong : (ink ? .lCaption : .lCallout))
                        .foregroundStyle(selected ? (ink ? Theme.onBrand : Theme.textPrimary) : Theme.textSecondary)
                        .padding(.horizontal, ink ? 12 : 14).padding(.vertical, 6)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(ink ? Theme.ink : Theme.card)
                                    .shadow(color: ink ? .clear : Theme.shadow(0.08), radius: 3, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Orange switch used in Settings.
struct LustroToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 16)
            Capsule()
                .fill(configuration.isOn ? AnyShapeStyle(Theme.buttonGradient) : AnyShapeStyle(Theme.sand))
                .frame(width: 44, height: 26)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 20, height: 20)
                        .shadow(color: Color(hex: 0x4D1A00, opacity: 0.25), radius: 1.5, y: 1)
                        .padding(3)
                }
                .animation(.snappy(duration: 0.18), value: configuration.isOn)
                .onTapGesture { configuration.isOn.toggle() }
                .accessibilityAddTraits(.isButton)
        }
    }
}

/// Title + subtitle + trailing actions at the top of every panel.
struct PanelHeader<Actions: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.lTitle1).foregroundStyle(Theme.textPrimary)
                Text(subtitle).font(.lCallout).foregroundStyle(Theme.textSecondary).lineLimit(2)
            }
            Spacer()
            actions
        }
    }
}

/// "AI TOOLS  0.9 GB" list section header. Titles can be app names from a third-party Info.plist, so they
/// are shown as typed: never as Markdown, which would turn `[text](url)` into a link.
struct SectionHeader: View {
    let title: String
    let detail: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: title).overline()
            if let detail { Text(verbatim: detail).font(.lCaption).foregroundStyle(Theme.textTertiary) }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 6)
    }
}

/// Dark floating bar that holds the primary action.
struct FloatingBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 14) { content }
            .padding(.leading, 18).padding(.trailing, 10).padding(.vertical, 10)
            .background(Theme.ink)
            .lustroFloating()
    }
}

/// Empty / idle state inside a panel.
struct PanelPlaceholder<Actions: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            Tile(symbol: symbol, size: 72)
            Text(title).font(.lTitle2).foregroundStyle(Theme.textPrimary)
            Text(message).font(.lCallout).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .lustroCard(radius: 22)
    }
}
