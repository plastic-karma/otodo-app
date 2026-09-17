import SwiftUI
import UIKit

enum OTodoTheme {
    enum Spacing {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let inset: CGFloat = 16
        static let section: CGFloat = 24
    }

    enum Radius {
        static let control: CGFloat = 10
        static let card: CGFloat = 20
    }

    // Informative secondary text stays legible on both plain and grouped surfaces.
    static let secondaryText = adaptive(
        light: UIColor(red: 0.36, green: 0.36, blue: 0.40, alpha: 1),
        dark: UIColor(red: 0.73, green: 0.73, blue: 0.77, alpha: 1)
    )
    static let warmForeground = adaptive(
        light: UIColor(red: 0.52, green: 0.30, blue: 0.06, alpha: 1),
        dark: UIColor(red: 1.00, green: 0.77, blue: 0.40, alpha: 1)
    )
    static let accent = adaptive(
        light: UIColor(red: 0.29, green: 0.24, blue: 0.75, alpha: 1),
        dark: UIColor(red: 0.70, green: 0.65, blue: 1.00, alpha: 1)
    )
    static let violet = adaptive(
        light: UIColor(red: 0.48, green: 0.31, blue: 0.88, alpha: 1),
        dark: UIColor(red: 0.76, green: 0.65, blue: 1.00, alpha: 1)
    )
    // Filled controls keep white labels, unlike foreground accents on dark surfaces.
    static let filledAccent = Color(red: 0.29, green: 0.24, blue: 0.75)
    static let filledViolet = Color(red: 0.48, green: 0.31, blue: 0.88)
    static let coral = Color(red: 0.93, green: 0.36, blue: 0.29)
    static let gold = Color(red: 0.94, green: 0.63, blue: 0.18)
    static let mint = Color(red: 0.15, green: 0.61, blue: 0.48)

    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let raisedCard = Color(uiColor: .secondarySystemGroupedBackground)
    static let formCanvas = Color(uiColor: .systemGroupedBackground)

    static let heroGradient = LinearGradient(
        colors: [
            adaptive(
                light: UIColor(red: 0.29, green: 0.24, blue: 0.75, alpha: 1),
                dark: UIColor(red: 0.17, green: 0.16, blue: 0.28, alpha: 1)
            ),
            adaptive(
                light: UIColor(red: 0.48, green: 0.31, blue: 0.88, alpha: 1),
                dark: UIColor(red: 0.24, green: 0.19, blue: 0.39, alpha: 1)
            ),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}

struct OTodoPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, OTodoTheme.Spacing.inset)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(
                OTodoTheme.filledAccent.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45),
                in: RoundedRectangle(cornerRadius: OTodoTheme.Radius.control)
            )
    }
}

/// Compact visual treatment with a full-size touch target outside the fill.
struct OTodoChipStyle: ButtonStyle {
    var isSelected = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? OTodoTheme.accent : Color.primary)
            .padding(.horizontal, OTodoTheme.Spacing.medium)
            .padding(.vertical, 6)
            .background(
                isSelected ? OTodoTheme.accent.opacity(0.12) : Color(uiColor: .tertiarySystemFill),
                in: RoundedRectangle(cornerRadius: OTodoTheme.Radius.control)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .opacity(isEnabled ? 1 : 0.55)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}

struct OTodoCanvas: View {
    var body: some View {
        Color(uiColor: .systemBackground)
            .ignoresSafeArea()
    }
}
