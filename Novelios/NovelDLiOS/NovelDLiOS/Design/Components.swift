import SwiftUI
import UIKit

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - 形状・面

/// カード面 — 影は使わず「罫線と余白」で紙面を構成する(玩具っぽさの排除)。
struct PaperCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
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

/// 背景用の紙面(.background(PaperBackground()))。
struct PaperBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
            .fill(AppPalette.surface)
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .strokeBorder(AppPalette.hairline, lineWidth: 1)
            )
    }
}

/// 行区切り(インセット)。
struct RowDivider: View {
    var leading: CGFloat = 0
    var body: some View {
        Rectangle()
            .fill(AppPalette.hairline)
            .frame(height: 1)
            .padding(.leading, leading)
    }
}

// MARK: - 押した感触

/// 全ての押せる要素に共通:わずかな沈み + 色の沈み + 触覚。
struct PressableModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .buttonStyle(PressableButtonStyle())
    }
}

struct PressableButtonStyle: ButtonStyle {
    var haptic: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.2), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed, haptic { Haptics.tap() }
            }
    }
}

// MARK: - ボタン

/// 主ボタン — 煉瓦の面。高さ 52、沈む。
struct EmberButton: View {
    let title: String
    var systemImage: String?
    var prominent: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    init(
        title: String,
        systemImage: String? = nil,
        prominent: Bool = false,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.prominent = prominent
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(AppFont.ui(prominent ? 16 : 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: prominent ? Metrics.controlHeight : Metrics.controlHeightSmall)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .fill(disabled ? AppPalette.track : AppPalette.ember)
            )
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(disabled)
    }
}

/// 副ボタン — 紙面 + 罫線。
struct QuietButton: View {
    let title: String
    var systemImage: String?
    var tint: Color = AppPalette.ink
    var disabled: Bool = false
    let action: () -> Void

    init(
        title: String,
        systemImage: String? = nil,
        tint: Color = AppPalette.ink,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button {
            action()
        } label: {
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
                    .fill(disabled ? AppPalette.canvas : AppPalette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .strokeBorder(AppPalette.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(disabled)
    }
}

/// 丸いアイコンボタン(ツールバー用)。
struct CircleIconButton: View {
    let system: String
    let filled: Bool
    let action: () -> Void

    init(system: String, filled: Bool = false, action: @escaping () -> Void) {
        self.system = system
        self.filled = filled
        self.action = action
    }

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: system)
                .font(AppFont.ui(15, weight: .semibold))
                .foregroundStyle(filled ? Color.white : AppPalette.ink)
                .frame(width: 40, height: 40)
                .background(Circle().fill(filled ? AppPalette.ember : AppPalette.surface))
                .overlay(Circle().strokeBorder(AppPalette.hairline, lineWidth: filled ? 0 : 1))
        }
        .buttonStyle(PressableButtonStyle())
    }
}

// MARK: - 入力・数値

/// 紙面の入力欄(既定の角丸フィールドを廃止)。
struct PaperField: View {
    let placeholder: String
    @Binding var text: String
    var mono = false
    var keyboard: UIKeyboardType = .default

    var body: some View {
        TextField(placeholder, text: $text)
            .font(mono ? AppFont.ui(14, design: .monospaced) : AppFont.ui(15))
            .foregroundStyle(AppPalette.ink)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 14)
            .frame(height: Metrics.controlHeightSmall)
            .background(
                RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous)
                    .fill(AppPalette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.fieldRadius, style: .continuous)
                    .strokeBorder(AppPalette.hairline, lineWidth: 1)
            )
    }
}

/// 「− 値 +」の数値行(既定 Stepper を廃止)。
struct StepperRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var suffix: String = ""

    var body: some View {
        HStack(spacing: Spacing.m) {
            Text(label)
                .font(AppFont.ui(15))
                .foregroundStyle(AppPalette.ink)
            Spacer()
            HStack(spacing: Spacing.m) {
                stepButton("minus") {
                    value = max(range.lowerBound, value - step)
                    Haptics.tap()
                }
                Text("\(Int(value))\(suffix)")
                    .font(AppFont.ui(16, weight: .semibold).monospacedDigit())
                    .foregroundStyle(AppPalette.ink)
                    .frame(minWidth: 52)
                stepButton("plus") {
                    value = min(range.upperBound, value + step)
                    Haptics.tap()
                }
            }
        }
        .frame(height: Metrics.rowHeight)
    }

    private func stepButton(_ icon: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: icon)
                .font(AppFont.ui(12, weight: .bold))
                .foregroundStyle(AppPalette.ink)
                .frame(width: 34, height: 34)
                .background(Circle().fill(AppPalette.canvas))
                .overlay(Circle().strokeBorder(AppPalette.hairline, lineWidth: 1))
        }
        .buttonStyle(PressableButtonStyle())
    }
}

/// 設定行 — ラベル + 値 + 任意の操作。
struct SettingRow<Trailing: View>: View {
    let label: String
    let detail: String?
    let trailing: Trailing

    init(label: String, detail: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.label = label
        self.detail = detail
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(AppFont.ui(15))
                    .foregroundStyle(AppPalette.ink)
                if let detail {
                    Text(detail)
                        .font(AppFont.ui(12))
                        .foregroundStyle(AppPalette.inkFaint)
                }
            }
            Spacer()
            trailing
        }
        .frame(minHeight: Metrics.rowHeight)
    }
}

/// 小さな情報チップ。
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

// MARK: - 見出し

/// 章題 — 罫線を引いた編集的な見出し。
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
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let eyebrow {
                Text(eyebrow.uppercased())
                    .font(AppFont.ui(11, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(AppPalette.gold)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(AppFont.serif(18, weight: .medium))
                    .foregroundStyle(AppPalette.ink)
                    .tracking(2)
                if let subtitle {
                    Text(subtitle)
                        .font(AppFont.ui(10.5))
                        .foregroundStyle(AppPalette.inkFaint)
                }
                Spacer()
            }
            Rectangle()
                .fill(AppPalette.ink.opacity(0.85))
                .frame(width: 18, height: 1)
                .padding(.top, 2)
        }
    }
}

// MARK: - 書影

/// 上製本風の書影 — 布装丁 + 背 + 双罫 + 箔押し。
/// 作品の表紙 = 横広の 1 画像(実カバーがあればそれを使用)。
/// 2 画像の縦横合成のような見え方はしない。
struct WideCover: View {
    let title: String
    let author: String
    var image: UIImage?
    var aspect: CGFloat = 2.2

    private var cloth: Color { CoverTile.clothColor(title: title, author: author) }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [cloth.opacity(0.88), cloth],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .overlay(alignment: .center) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(Color(red: 0.925, green: 0.890, blue: 0.808).opacity(0.5))
                }
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .center, endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AppFont.serif(16, weight: .semibold))
                    .foregroundStyle(Color(red: 0.95, green: 0.93, blue: 0.90))
                    .lineLimit(2)
                Text(author)
                    .font(AppFont.ui(12))
                    .foregroundStyle(Color(red: 0.95, green: 0.93, blue: 0.90).opacity(0.8))
                    .lineLimit(1)
            }
            .padding(Spacing.m)
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .strokeBorder(AppPalette.hairline, lineWidth: 1)
        )
    }
}

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
        Color(red: 0.196, green: 0.243, blue: 0.310),
        Color(red: 0.216, green: 0.282, blue: 0.231),
        Color(red: 0.353, green: 0.176, blue: 0.157),
        Color(red: 0.196, green: 0.192, blue: 0.184),
        Color(red: 0.165, green: 0.286, blue: 0.286),
        Color(red: 0.294, green: 0.235, blue: 0.176),
        Color(red: 0.263, green: 0.188, blue: 0.247),
        Color(red: 0.153, green: 0.192, blue: 0.271),
    ]

    private var cloth: Color { Self.clothColor(title: title, author: author) }

    /// 書影の布色(詳細画面の帯にも同じ布を使う)。
    static func clothColor(title: String, author: String) -> Color {
        var h: UInt64 = 5381
        for b in (title + "|" + author).utf8 {
            h = (h &* 33) ^ UInt64(b)
        }
        return cloths[Int(h % UInt64(cloths.count))]
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
                HStack(spacing: 0) {
                    Rectangle().fill(cream.opacity(0.85)).frame(width: 3)
                    Rectangle().fill(Color.black.opacity(0.22)).frame(width: 1.5)
                    Spacer(minLength: 0)
                }
            }
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
                .drawingGroup()
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

/// 読書リボン(細い進捗)。
struct ReadingRibbon: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(AppPalette.track)
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

// MARK: - リーダー用

/// 細い独自スライダー(既定 Slider を廃止)。広い当たり判定で操作性を確保。
struct PageSlider: View {
    @Binding var value: Int
    let count: Int

    var body: some View {
        GeometryReader { geo in
            let total = max(count - 1, 1)
            let ratio = geo.size.width > 0 ? CGFloat(min(max(value, 0), total)) / CGFloat(total) : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppPalette.track)
                    .frame(height: 3)
                Capsule()
                    .fill(AppPalette.ember)
                    .frame(width: max(3, geo.size.width * ratio), height: 3)
                Circle()
                    .fill(AppPalette.ember)
                    .frame(width: 13, height: 13)
                    .offset(x: max(0, min(geo.size.width - 13, geo.size.width * ratio - 6)))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let r = min(max(g.location.x / max(geo.size.width, 1), 0), 1)
                        value = Int((r * CGFloat(total)).rounded())
                    }
                    .onEnded { _ in Haptics.tap() }
            )
        }
        .frame(height: 32)
    }
}

/// 独自セグメント(既定 Picker/SegmentedPicker を廃止)。
struct SegmentTabs: View {
    let titles: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(titles.indices, id: \.self) { i in
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { selection = i }
                    Haptics.tap()
                } label: {
                    Text(titles[i])
                        .font(AppFont.ui(13, weight: .semibold))
                        .foregroundStyle(selection == i ? .white : AppPalette.inkSoft)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selection == i ? AppPalette.ink : Color.clear)
                        )
                }
                .buttonStyle(PressableButtonStyle(haptic: false))
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppPalette.canvas)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(AppPalette.hairline, lineWidth: 1)
        )
    }
}
