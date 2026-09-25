import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// 上製本風の書影 — 布装丁のクラシック文庫(箔押しタイトル + 背 + 双罫)。
/// 「おもちゃのグラデ」ではなく、落ち着いた書籍アプリの佇まい。
struct CoverTile: View {
    let title: String
    let author: String
    var progress: Double = 0
    var width: CGFloat? = nil

    init(title: String, author: String, progress: Double = 0, width: CGFloat? = nil) {
        self.title = title
        self.author = author
        self.progress = progress
        self.width = width
    }

    private static let cloths: [Color] = [
        Color(red: 0.196, green: 0.243, blue: 0.310),   // 藍鼠
        Color(red: 0.216, green: 0.282, blue: 0.231),   // 常磐
        Color(red: 0.353, green: 0.176, blue: 0.157),   // 酢漿
        Color(red: 0.196, green: 0.192, blue: 0.184),   // 墨
        Color(red: 0.165, green: 0.286, blue: 0.286),   // 深縹
        Color(red: 0.294, green: 0.235, blue: 0.176),   // 枯茶
        Color(red: 0.263, green: 0.188, blue: 0.247),   // 桑染
        Color(red: 0.153, green: 0.192, blue: 0.271),   // 褐返
    ]

    private var cloth: Color {
        var h: UInt64 = 5381
        for b in (title + "|" + author).utf8 {
            h = (h &* 33) &^ UInt64(b)
        }
        return Self.cloths[Int(h % UInt64(Self.cloths.count))]
    }

    private var cream: Color { Color(red: 0.925, green: 0.890, blue: 0.808) }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [cloth.opacity(0.90), cloth],
                startPoint: .top,
                endPoint: .bottom
            )
            .overlay(alignment: .leading) {
                // 背(spine)の象徴:クリームの帯 + 装丁の影。
                HStack(spacing: 0) {
                    Rectangle().fill(cream.opacity(0.85)).frame(width: 3)
                    Rectangle().fill(Color.black.opacity(0.22)).frame(width: 1.5)
                    Spacer(minLength: 0)
                }
            }
            // 上下の双罫(箔押しの意匠)。
            VStack {
                doubleRule
                Spacer(minLength: 0)
                doubleRule
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            VStack(spacing: 8) {
                Text(title)
                    .font(AppFont.serif(15, weight: .semibold))
                    .foregroundStyle(cream)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
                Rectangle()
                    .fill(cream.opacity(0.6))
                    .frame(width: 20, height: 1)
                Text(author)
                    .font(AppFont.ui(10, weight: .medium))
                    .foregroundStyle(cream.opacity(0.72))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)

            if progress > 0 {
                VStack {
                    Spacer()
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.black.opacity(0.25))
                            Rectangle()
                                .fill(cream.opacity(0.9))
                                .frame(width: RibbonGeometry.fillWidth(progress, in: geo.size.width))
                        }
                    }
                    .frame(height: 2.5)
                }
            }
        }
        .frame(width: width)
        .frame(maxWidth: .infinity)
        .aspectRatio(2 / 3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.tileRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.tileRadius)
                .strokeBorder(Color.black.opacity(0.22), lineWidth: 0.5)
        )
    }

    private var doubleRule: some View {
        VStack(spacing: 2) {
            Rectangle().fill(cream.opacity(0.55)).frame(height: 1)
            Rectangle().fill(cream.opacity(0.3)).frame(height: 1)
        }
    }
}

struct RibbonGeometry {
    static func fillWidth(_ progress: Double, in total: CGFloat) -> CGFloat {
        let clamped = min(max(progress, 0), 1)
        return total * CGFloat(clamped)
    }
}

/// 読書リボン(書影脇の細い進捗 — Kindle の "progress spine")。
struct ReadingRibbon: View {
    let value: Double // 0...1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppPalette.track)
                Capsule()
                    .fill(AppPalette.ember)
                    .frame(width: max(3, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 3)
        .accessibilityLabel("読書進捗")
        .accessibilityValue("\(Int(min(max(value, 0), 1) * 100)) パーセント")
    }
}

/// セクション見出し — 書名頁のような静かな階調。
struct SectionBanner: View {
    let title: String
    var subtitle: String?
    var eyebrow: String?

    init(title: String, subtitle: String? = nil, eyebrow: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.eyebrow = eyebrow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let eyebrow {
                Text(eyebrow.uppercased())
                    .font(AppFont.ui(12, weight: .semibold))
                    .tracking(1.6)
                    .foregroundStyle(AppPalette.gold)
            }
            Text(title)
                .font(AppFont.serif(26, weight: .semibold))
                .foregroundStyle(AppPalette.ink)
                .minimumScaleFactor(0.85)
            if let subtitle {
                Text(subtitle)
                    .font(AppFont.ui(13))
                    .foregroundStyle(AppPalette.inkSoft)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 主ボタン(煉瓦) — 画面で一番押しやすい要素。
struct EmberButton: View {
    let title: String
    var systemImage: String?
    var prominent: Bool = false
    let action: () -> Void

    init(title: String, systemImage: String? = nil, prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.prominent = prominent
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(AppFont.ui(prominent ? 16 : 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: prominent ? Metrics.controlHeight : 46)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .fill(AppPalette.ember)
            )
        }
    }
}

/// 副ボタン — 罫線囲みの静かな操作。
struct QuietButton: View {
    let title: String
    var systemImage: String?
    var tint: Color = AppPalette.ink
    let action: () -> Void

    init(title: String, systemImage: String? = nil, tint: Color = AppPalette.ink, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(AppFont.ui(14, weight: .medium))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.controlHeightSmall)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .fill(AppPalette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .strokeBorder(AppPalette.hairline, lineWidth: 1)
            )
        }
    }
}

/// カード地 — 白面 + 罫線。影は最小限。
struct CardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
            .fill(AppPalette.surface)
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .strokeBorder(AppPalette.hairline, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
    }
}

/// 小さな情報チップ(ドメイン名・状態など)。
struct InfoChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(AppFont.ui(11, weight: .medium))
            .foregroundStyle(AppPalette.inkSoft)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(AppPalette.canvas))
            .overlay(Capsule().strokeBorder(AppPalette.hairline, lineWidth: 1))
    }
}
