import LustroCore
import SwiftUI

/// Accent colours referenced by name from rules.json and the design (Figma "Lustro Colors").
enum Palette {
    static func color(_ name: String?) -> Color {
        switch name {
        case "orange": .orange
        case "purple": .purple
        case "pink": .pink
        case "indigo": .indigo
        case "teal": .teal
        case "red": .red
        case "green": .green
        case "gray": .gray
        case "mint": .mint
        case "cyan": .cyan
        case "yellow": .yellow
        default: .blue
        }
    }

    /// Fallback tint for groups whose rule doesn't name one.
    static func tint(forSection section: String) -> String {
        switch section {
        case "AI tools": "teal"
        case "Developer tools": "orange"
        case "Trash": "gray"
        default: "blue"
        }
    }

    /// Distinct colours for treemap blocks, in order.
    static let sequence: [Color] = [.blue, .teal, .indigo, .red, .purple, .green, .orange, .pink, .mint, .cyan, .brown]
}

/// Rounded coloured square holding a white SF Symbol, as used for modules and categories.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

struct Badge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(tint)
    }
}

extension Date {
    /// "3 days ago", "today".
    var relativeDescription: String {
        let days = Calendar.current.dateComponents([.day], from: self, to: Date()).day ?? 0
        if days < 1 { return "today" }
        // Match the app's UI language rather than the system's, so sentences don't mix languages.
        let locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        return formatted(Date.RelativeFormatStyle(presentation: .named, locale: locale))
    }
}
