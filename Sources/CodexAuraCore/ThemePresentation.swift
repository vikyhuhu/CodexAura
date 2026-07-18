import Foundation

/// Resolves theme intent into renderer-ready values. Callers do not need to
/// understand luminance math or how automatic appearance is classified.
public enum ThemePresentation {
    public struct Values: Equatable {
        public let colorScheme: String
        public let scrimRGB: String
        public let onAccent: String
    }

    public static func resolve(_ theme: Theme) -> Values {
        let scheme: String
        switch theme.appearance {
        case .light:
            scheme = "light"
        case .dark:
            scheme = "dark"
        case .auto:
            scheme = relativeLuminance(theme.colors.background) > 0.45 ? "light" : "dark"
        }

        return Values(
            colorScheme: scheme,
            scrimRGB: scheme == "light" ? "255 255 255" : "0 0 0",
            onAccent: theme.colors.onAccent ?? contrastingForeground(for: theme.colors.accent)
        )
    }

    private static func contrastingForeground(for color: String) -> String {
        let luminance = relativeLuminance(color)
        let blackContrast = (luminance + 0.05) / 0.05
        let whiteContrast = 1.05 / (luminance + 0.05)
        return blackContrast >= whiteContrast ? "#000000" : "#ffffff"
    }

    private static func relativeLuminance(_ hex: String) -> Double {
        let value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil,
              let number = Int(value.dropFirst(), radix: 16)
        else { return 0 }

        let red = Double((number >> 16) & 0xff) / 255.0
        let green = Double((number >> 8) & 0xff) / 255.0
        let blue = Double(number & 0xff) / 255.0
        let linearRed = linearized(red)
        let linearGreen = linearized(green)
        let linearBlue = linearized(blue)
        return 0.2126 * linearRed + 0.7152 * linearGreen + 0.0722 * linearBlue
    }

    private static func linearized(_ channel: Double) -> Double {
        if channel <= 0.04045 {
            return channel / 12.92
        }
        return pow((channel + 0.055) / 1.055, 2.4)
    }
}
