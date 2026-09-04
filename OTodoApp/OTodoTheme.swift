import SwiftUI
import UIKit

enum OTodoTheme {
    static let accent = Color(red: 0.29, green: 0.24, blue: 0.75)
    static let violet = Color(red: 0.48, green: 0.31, blue: 0.88)
    static let coral = Color(red: 0.93, green: 0.36, blue: 0.29)
    static let gold = Color(red: 0.94, green: 0.63, blue: 0.18)
    static let mint = Color(red: 0.15, green: 0.61, blue: 0.48)

    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let raisedCard = Color(uiColor: .systemBackground)

    static var heroGradient: LinearGradient {
        LinearGradient(
            colors: [accent, violet],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct OTodoCanvas: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)

            LinearGradient(
                colors: [
                    OTodoTheme.violet.opacity(0.14),
                    OTodoTheme.coral.opacity(0.06),
                    .clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}
