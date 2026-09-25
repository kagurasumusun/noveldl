import SwiftUI
import UIKit

// MARK: - 読書テーマ(紙/セピア/夜)

enum BookTheme: String, CaseIterable, Identifiable {
    case paper, sepia, night

    var id: String { rawValue }

    var label: String {
        switch self {
        case .paper: return "紙"
        case .sepia: return "セピア"
        case .night: return "夜"
        }
    }

    var background: Color {
        switch self {
        case .paper: return Color(red: 0.984, green: 0.973, blue: 0.949)
        case .sepia: return Color(red: 0.945, green: 0.894, blue: 0.796)
        case .night: return Color(red: 0.078, green: 0.075, blue: 0.086)
        }
    }

    var ink: Color {
        switch self {
        case .paper: return Color(red: 0.125, green: 0.118, blue: 0.102)
        case .sepia: return Color(red: 0.212, green: 0.161, blue: 0.098)
        case .night: return Color(red: 0.851, green: 0.827, blue: 0.773)
        }
    }

    var secondaryInk: Color {
        switch self {
        case .paper: return Color(red: 0.329, green: 0.310, blue: 0.278)
        case .sepia: return Color(red: 0.380, green: 0.310, blue: 0.204)
        case .night: return Color(red: 0.631, green: 0.608, blue: 0.565)
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

// MARK: - パレット

/// 紙・墨・煉瓦の三段。行動色は煉瓦のみ。
/// アプリ全体の地色は温かいダーク(暗すぎず明るすぎず)。
/// 読書テーマ(紙/セピア/夜)は本文用に別途選べる。
enum AppPalette {
    static let ember = Color(red: 0.788, green: 0.380, blue: 0.290)
    static let emberDeep = Color(red: 0.639, green: 0.290, blue: 0.212)
    static let gold = Color(red: 0.702, green: 0.573, blue: 0.353)
    static let canvas = Color(red: 0.106, green: 0.102, blue: 0.094)     // #1B1A18
    static let surface = Color(red: 0.145, green: 0.137, blue: 0.125)    // #252320
    static let ink = Color(red: 0.925, green: 0.910, blue: 0.878)        // #ECE8E0
    static let inkSoft = Color(red: 0.690, green: 0.663, blue: 0.620)
    static let inkFaint = Color(red: 0.522, green: 0.494, blue: 0.451)
    static let hairline = Color(red: 0.220, green: 0.208, blue: 0.184)
    static let track = Color(red: 0.235, green: 0.220, blue: 0.200)
    /// 書影の「棚の影」(ダーク面では深めに)。カードには付けない。
    static let shelfShadow = Color.black.opacity(0.45)
    static let pressTint = Color.white.opacity(0.06)
}

// MARK: - 書体

enum AppFont {
    /// New York — 読書・書名のセリフ体。
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static func ui(
        _ size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        .system(size: size, weight: weight, design: design)
    }
}

// MARK: - 寸法(4pt グリッド)

enum Spacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum Metrics {
    static let gutter: CGFloat = 20
    static let cardRadius: CGFloat = 12
    static let tileRadius: CGFloat = 3
    static let fieldRadius: CGFloat = 10
    static let controlHeight: CGFloat = 52
    static let controlHeightSmall: CGFloat = 46
    static let rowHeight: CGFloat = 52
}

// MARK: - 触覚

enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
