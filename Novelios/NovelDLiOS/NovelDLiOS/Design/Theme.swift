import SwiftUI

/// 読書テーマ(紙/セピア/夜)— 本文の読み心地は Kindle 準拠のまま、コントラストを強化。
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

/// アプリ共通パレット — 上質な書籍アプリの落ち着き(紙・墨・煉瓦)。
/// 使い方:文字は ink / inkSoft / inkFaint、行動は ember(1画面に1〜2箇所だけ)。
enum AppPalette {
    /// 煉瓦色 — 唯一の行動色(主ボタン・進捗・リンク)。
    static let ember = Color(red: 0.655, green: 0.243, blue: 0.161)
    /// 煉瓦色(押下・濃色)。
    static let emberDeep = Color(red: 0.541, green: 0.192, blue: 0.122)
    /// 真鍮 — 補助の小ラベル(Badge 等、控えめに)。
    static let gold = Color(red: 0.545, green: 0.435, blue: 0.243)
    /// 紙地(画面背景)。
    static let canvas = Color(red: 0.968, green: 0.957, blue: 0.933)
    /// カード面。
    static let surface = Color.white
    /// 墨 — 主文字(コントラスト 15:1 級)。
    static let ink = Color(red: 0.114, green: 0.106, blue: 0.094)
    /// 副文字(7:1 級 — 従来の薄い secondary の代替)。
    static let inkSoft = Color(red: 0.333, green: 0.310, blue: 0.278)
    /// 補助文字(5:1 級 — キャプション用の下限)。
    static let inkFaint = Color(red: 0.427, green: 0.400, blue: 0.357)
    /// 罫線。
    static let hairline = Color(red: 0.882, green: 0.859, blue: 0.816)
    /// 進捗のレール。
    static let track = Color(red: 0.878, green: 0.851, blue: 0.796)
    /// 表紙・影。
    static let shelfShadow = Color.black.opacity(0.12)
}

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

enum Metrics {
    static let gutter: CGFloat = 20
    static let cardRadius: CGFloat = 6
    static let tileRadius: CGFloat = 3
    /// 主ボタンの高さ(指で押しやすい寸法)。
    static let controlHeight: CGFloat = 50
    /// 副ボタン・入力の高さ。
    static let controlHeightSmall: CGFloat = 44
}
