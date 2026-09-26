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

    /// 画面の色。SwiftUI の Color を UIColor に橋渡しすると、
    /// アプリがダークのとき夜テーマの文字色が黒へ潰れて本文が見えなくなる。
    /// 成分を一度だけ持ち、Color と UIColor の両方をここから作る。
    private var backgroundRGB: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .paper: return (0.984, 0.973, 0.949)
        case .sepia: return (0.945, 0.894, 0.796)
        case .night: return (0.055, 0.055, 0.062)
        }
    }

    private var inkRGB: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .paper: return (0.125, 0.118, 0.102)
        case .sepia: return (0.212, 0.161, 0.098)
        // 夜は暖かい白。灰色寄りの 0.85 はダークモードでさらに沈み、読めなくなる。
        case .night: return (0.965, 0.945, 0.905)
        }
    }

    private var secondaryRGB: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .paper: return (0.329, 0.310, 0.278)
        case .sepia: return (0.380, 0.310, 0.204)
        case .night: return (0.80, 0.77, 0.72)
        }
    }

    private var hairlineRGB: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .paper: return (0.85, 0.82, 0.76)
        case .sepia: return (0.79, 0.71, 0.57)
        case .night: return (0.32, 0.30, 0.28)
        }
    }

    var background: Color { Self.color(backgroundRGB) }
    var ink: Color { Self.color(inkRGB) }
    var secondaryInk: Color { Self.color(secondaryRGB) }
    var hairline: Color { Self.color(hairlineRGB) }

    var uiBackground: UIColor { Self.ui(backgroundRGB) }
    var uiInk: UIColor { Self.ui(inkRGB) }
    var uiSecondaryInk: UIColor { Self.ui(secondaryRGB) }
    var uiHairline: UIColor { Self.ui(hairlineRGB) }

    /// 明るい地の本文か。見出しの濃さを決める。
    var inkIsLight: Bool { inkRGB.0 > 0.6 }

    private static func color(_ rgb: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }

    private static func ui(_ rgb: (CGFloat, CGFloat, CGFloat)) -> UIColor {
        UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
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
