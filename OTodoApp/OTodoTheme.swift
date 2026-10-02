import SwiftUI
import UIKit

enum OTodoTheme {
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
    static let coral = adaptive(
        light: UIColor(red: 0.70, green: 0.20, blue: 0.15, alpha: 1),
        dark: UIColor(red: 1.00, green: 0.60, blue: 0.50, alpha: 1)
    )
    static let gold = Color(red: 0.94, green: 0.63, blue: 0.18)
    static let mint = adaptive(
        light: UIColor(red: 0.08, green: 0.42, blue: 0.32, alpha: 1),
        dark: UIColor(red: 0.38, green: 0.83, blue: 0.66, alpha: 1)
    )
    static let filledMint = Color(red: 0.08, green: 0.42, blue: 0.32)

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

struct OTodoCanvas: View {
    var body: some View {
        Color(uiColor: .systemBackground)
            .ignoresSafeArea()
    }
}
