import SwiftUI

enum Theme {
    static let accent = Color(red: 142 / 255, green: 213 / 255, blue: 79 / 255)   // lime
    static let accentDim = Color(red: 88 / 255, green: 132 / 255, blue: 49 / 255)
    static let outline = Color(red: 0 / 255, green: 235 / 255, blue: 65 / 255)    // route outline
    static let warm = Color(red: 1.0, green: 148 / 255, blue: 69 / 255)           // orange
    static let bg = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)

    static let gradeColors: [String: Color] = [
        "6A": .blue, "6A+": .blue, "6B": .indigo, "6B+": .indigo,
        "6C": .purple, "6C+": .purple, "7A": .pink, "7A+": .pink,
        "7B": .red, "7B+": .red, "7C": .orange, "7C+": .orange,
        "8A": .mint, "8A+": .mint, "8B": .teal, "8B+": .teal,
    ]

    static func gradeColor(_ grade: String) -> Color {
        gradeColors[grade] ?? .secondary
    }
}

extension View {
    func cardStyle() -> some View {
        self
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
