import SwiftUI

/// Claude 앱과 비슷한 느낌의 팔레트. 따뜻한 회백색 바탕, 테라코타 강조색, 진한 갈색 글자.
enum Theme {
    static let accent = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let background = Color(light: Color(red: 0.957, green: 0.953, blue: 0.933), dark: Color(red: 0.17, green: 0.165, blue: 0.153))
    static let card = Color(light: .white, dark: Color(red: 0.22, green: 0.215, blue: 0.20))
    static let text = Color(light: Color(red: 0.12, green: 0.118, blue: 0.114), dark: Color(red: 0.957, green: 0.953, blue: 0.933))
    static let secondaryText = Color(light: Color(red: 0.42, green: 0.41, blue: 0.38), dark: Color(red: 0.70, green: 0.69, blue: 0.66))
    static let divider = Color(light: Color(red: 0.88, green: 0.87, blue: 0.84), dark: Color(red: 0.30, green: 0.295, blue: 0.28))
    static let titleFont = Font.system(size: 20, weight: .semibold, design: .serif)
}

extension Color {
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
    }
}
