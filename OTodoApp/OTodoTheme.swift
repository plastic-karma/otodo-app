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
    static let coral = Color(red: 0.93, green: 0.36, blue: 0.29)
    static let gold = Color(red: 0.94, green: 0.63, blue: 0.18)
    static let mint = Color(red: 0.15, green: 0.61, blue: 0.48)

    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let raisedCard = Color(uiColor: .secondarySystemGroupedBackground)

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
