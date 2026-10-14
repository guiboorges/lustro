import AppKit
import CoreText
import LustroCore
import SwiftUI

/// Design tokens from the Figma file ("Lustro v2" collection, page "v2 · Premium").
enum Theme {
    // Brand: "Industrial Rust Glow"
    static let rust900 = Color(hex: 0x7A2A08)
    static let rust700 = Color(hex: 0xB7410E)
    static let orange500 = Color(hex: 0xFF7722)
    static let orange300 = Color(hex: 0xFFA266)
    static let peach100 = Color(hex: 0xFFE8D6)
    static let peach50 = Color(hex: 0xFFF4EC)

    // Surfaces
    static let canvas = Color(hex: 0xFFF9F5)
    static let card = Color.white
    static let sunken = Color(hex: 0xFBF1EA)
    static let ink = Color(hex: 0x22140D)
    static let border = Color(hex: 0xF1E3D8)
    static let sand = Color(hex: 0xF3DCCB)
    static let chartInk = Color(hex: 0x3A2418)

    // Text
    static let textPrimary = Color(hex: 0x22140D)
    static let textSecondary = Color(hex: 0x8C7467)
    static let textTertiary = Color(hex: 0xBFA899)
    static let onBrand = Color.white
    static let onBrandMuted = Color.white.opacity(0.72)

    // Status
    static let safe = Color(hex: 0x2FA36B)
    static let review = Color(hex: 0xE8890C)
    static let caution = Color(hex: 0xE5484D)

    /// Window frame: dark rust top-left → orange → peach bottom-right.
    static let frameGradient = LinearGradient(
        stops: [.init(color: rust700, location: 0), .init(color: orange500, location: 0.55), .init(color: peach100, location: 1)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    /// Primary call-to-action fill.
    static let buttonGradient = LinearGradient(colors: [Color(hex: 0xFF8833), Color(hex: 0xD9520F)], startPoint: .top, endPoint: .bottom)
    /// Deeper variant for cards with white text.
    static let promoGradient = LinearGradient(colors: [Color(hex: 0x7A2A08), rust700, orange500], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Shades used for charts and treemaps, darkest first.
    static let chart: [Color] = [rust700, orange500, orange300, chartInk, rust900, sand, peach100, Color(hex: 0xE9B08A), Color(hex: 0xC8653A)]

    static func isDark(_ color: Color) -> Bool {
        [rust700, orange500, chartInk, rust900, Color(hex: 0xC8653A)].contains(color)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

// MARK: - Typography (Plus Jakarta Sans, bundled under the SIL Open Font License)

enum Typeface {
    case regular, medium, semibold, bold, extrabold

    var postScriptName: String {
        switch self {
        case .regular: "PlusJakartaSans-Regular"
        case .medium: "PlusJakartaSans-Medium"
        case .semibold: "PlusJakartaSans-SemiBold"
        case .bold: "PlusJakartaSans-Bold"
        case .extrabold: "PlusJakartaSans-ExtraBold"
        }
    }

    /// Registers the bundled fonts. `ATSApplicationFontsPath` already does this for the .app;
    /// this covers other launch paths. Falls back to the system font if the files are missing.
    static func registerBundledFonts() {
        guard NSFont(name: Typeface.regular.postScriptName, size: 12) == nil,
              let fonts = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: fonts, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
    }
}

extension Font {
    static func jakarta(_ size: CGFloat, _ face: Typeface = .regular) -> Font {
        .custom(face.postScriptName, size: size)
    }

    // Type ramp, matching the Figma text styles "v2/…".
    static let lDisplay = jakarta(40, .bold)
    static let lTitle1 = jakarta(28, .bold)
    static let lTitle2 = jakarta(20, .bold)
    static let lTitle3 = jakarta(16, .semibold)
    static let lBody = jakarta(14)
    static let lBodyStrong = jakarta(14, .semibold)
    static let lCallout = jakarta(13)
    static let lCalloutStrong = jakarta(13, .semibold)
    static let lCaption = jakarta(12, .medium)
    static let lOverline = jakarta(11, .semibold)
    static let lMetric = jakarta(32, .bold)
    static let lMetricSmall = jakarta(22, .bold)
}

extension Text {
    /// Uppercase, tracked label ("CAN BE FREED").
    func overline(_ color: Color = Theme.textSecondary) -> some View {
        textCase(.uppercase).font(.lOverline).tracking(0.8).foregroundStyle(color)
    }
}

// MARK: - Category tints (rules.json "tint" names mapped onto the warm palette)

enum Palette {
    /// Tile background + glyph colour for a rule tint. Keeps the warm v2 look while
    /// still distinguishing review/caution items.
    static func tile(_ name: String?) -> (background: Color, foreground: Color) {
        switch name {
        case "red", "pink": (Theme.caution.opacity(0.12), Theme.caution)
        case "gray": (Theme.sunken, Theme.textSecondary)
        case "green", "mint": (Theme.safe.opacity(0.12), Theme.safe)
        default: (Theme.peach100, Theme.rust700)
        }
    }

    static func tint(forSection section: String) -> String {
        switch section {
        case "Trash": "gray"
        default: "orange"
        }
    }

    /// Distinct colours for chart segments, in order.
    static let sequence: [Color] = Theme.chart

    static func sectionColor(_ index: Int) -> Color {
        [Theme.rust700, Theme.orange500, Theme.orange300, Theme.sand, Theme.chartInk][index % 5]
    }
}

extension Date {
    /// "2 minutes ago", in the app's UI language.
    var relativeTime: String {
        if Date().timeIntervalSince(self) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: self, relativeTo: Date())
    }

    /// "3 days ago", "today".
    var relativeDescription: String {
        let days = Calendar.current.dateComponents([.day], from: self, to: Date()).day ?? 0
        if days < 1 { return "today" }
        // Match the app's UI language rather than the system's, so sentences don't mix languages.
        let locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        return formatted(Date.RelativeFormatStyle(presentation: .named, locale: locale))
    }
}

extension String {
    var abbreviatingHome: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return hasPrefix(home) ? "~" + dropFirst(home.count) : self
    }
}
