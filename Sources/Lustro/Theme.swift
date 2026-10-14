import AppKit
import CoreText
import LustroCore
import SwiftUI

/// Design tokens from the Figma file ("Lustro v2" collection, page "v2 · Premium").
/// Every token has a light and a dark value (the collection's Light and Dark modes).
enum Theme {
    // Brand: "Industrial Rust Glow"
    static let rust900 = Color(hex: 0x7A2A08)
    static let rust700 = Color(light: 0xB7410E, dark: 0xFF8F57)
    static let orange500 = Color(hex: 0xFF7722)
    static let orange300 = Color(hex: 0xFFA266)
    static let peach100 = Color(light: 0xFFE8D6, dark: 0x3A2217)
    static let peach50 = Color(light: 0xFFF4EC, dark: 0x2A1912)

    // Surfaces
    static let canvas = Color(light: 0xFFF9F5, dark: 0x16100D)
    static let card = Color(light: 0xFFFFFF, dark: 0x211915)
    static let sunken = Color(light: 0xFBF1EA, dark: 0x2B211C)
    static let ink = Color(light: 0x22140D, dark: 0x3D2C24)
    static let border = Color(light: 0xF1E3D8, dark: 0x342720)
    static let sand = Color(light: 0xF3DCCB, dark: 0x3A2C25)
    static let chartInk = Color(light: 0x3A2418, dark: 0x5A4034)

    // Text
    static let textPrimary = Color(light: 0x22140D, dark: 0xF6EDE6)
    static let textSecondary = Color(light: 0x8C7467, dark: 0xB39B8D)
    static let textTertiary = Color(light: 0xBFA899, dark: 0x7D685B)
    static let onBrand = Color.white
    static let onBrandMuted = Color.white.opacity(0.72)

    // Status
    static let safe = Color(light: 0x2FA36B, dark: 0x45C486)
    static let review = Color(light: 0xE8890C, dark: 0xF5A23F)
    static let caution = Color(light: 0xE5484D, dark: 0xFF6B6E)

    /// Window frame: dark rust top-left → orange → peach bottom-right (deeper embers in dark mode).
    static let frameGradient = LinearGradient(
        stops: [.init(color: Color(light: 0xB7410E, dark: 0x5C1F06), location: 0),
                .init(color: Color(light: 0xFF7722, dark: 0xA63A0C), location: 0.55),
                .init(color: Color(light: 0xFFE8D6, dark: 0x2A1912), location: 1)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    /// Primary call-to-action fill.
    static let buttonGradient = LinearGradient(colors: [Color(hex: 0xFF8833), Color(hex: 0xD9520F)], startPoint: .top, endPoint: .bottom)
    /// Deeper variant for cards with white text.
    static let promoGradient = LinearGradient(colors: [Color(hex: 0x7A2A08), Color(hex: 0xB7410E), orange500], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Warm shadow in light mode, plain black (and stronger) in dark mode.
    static func shadow(_ opacity: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark ? NSColor.black.withAlphaComponent(min(opacity * 4, 0.6))
                : NSColor(red: 0x59 / 255, green: 0x26 / 255, blue: 0x08 / 255, alpha: opacity)
        })
    }

    /// Shades used for charts and treemaps, darkest first.
    static let chart: [Color] = [rust700, orange500, orange300, chartInk, rust900, sand, peach100, Color(hex: 0xE9B08A), Color(hex: 0xC8653A)]

    static func isDark(_ color: Color) -> Bool {
        [rust700, orange500, chartInk, rust900, Color(hex: 0xC8653A)].contains(color)
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }

    /// A colour that follows the window's light or dark appearance.
    init(light: UInt32, dark: UInt32) {
        func ns(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        let lightColor = ns(light), darkColor = ns(dark)
        self.init(nsColor: NSColor(name: nil) { $0.isDark ? darkColor : lightColor })
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
