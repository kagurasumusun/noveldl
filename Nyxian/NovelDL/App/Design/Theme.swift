import SwiftUI

/// Reader design language — warm paper, ink type, ember accents.
/// Visual reference: Kindle (serif page, sepia paper) + Kobo (shelf grid, amber accent).
enum BookTheme: String, CaseIterable, Identifiable {
    case paper, sepia, night

    var id: String { rawValue }

    var label: String {
        switch self {
        case .paper: return "Paper"
        case .sepia: return "Sepia"
        case .night: return "Night"
        }
    }

    var background: Color {
        switch self {
        case .paper: return Color(red: 0.976, green: 0.965, blue: 0.937)
        case .sepia: return Color(red: 0.945, green: 0.894, blue: 0.796)
        case .night: return Color(red: 0.078, green: 0.075, blue: 0.086)
        }
    }

    var ink: Color {
        switch self {
        case .paper: return Color(red: 0.125, green: 0.118, blue: 0.102)
        case .sepia: return Color(red: 0.212, green: 0.161, blue: 0.098)
        case .night: return Color(red: 0.776, green: 0.749, blue: 0.694)
        }
    }

    var secondaryInk: Color {
        switch self {
        case .paper: return Color(red: 0.42, green: 0.39, blue: 0.35)
        case .sepia: return Color(red: 0.44, green: 0.36, blue: 0.24)
        case .night: return Color(red: 0.52, green: 0.50, blue: 0.46)
        }
    }

    var hairline: Color {
        switch self {
        case .paper: return Color(red: 0.85, green: 0.82, blue: 0.76)
        case .sepia: return Color(red: 0.79, green: 0.71, blue: 0.57)
        case .night: return Color(red: 0.21, green: 0.20, blue: 0.22)
        }
    }
}

enum AppPalette {
    /// Ember — the single accent (Kindle amber / Kobo brick).
    static let ember = Color(red: 0.741, green: 0.345, blue: 0.208)
    static let gold = Color(red: 0.647, green: 0.522, blue: 0.278)
    static let canvas = Color(red: 0.964, green: 0.952, blue: 0.925)
    static let shelfShadow = Color.black.opacity(0.18)
}

enum AppFont {
    /// New York — the "Bookerly" stand-in for reading and book titles.
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}

enum Metrics {
    static let gutter: CGFloat = 20
    static let cardRadius: CGFloat = 6
    static let tileRadius: CGFloat = 3
}
