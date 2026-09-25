import SwiftUI

/// Generated cover art — deterministic warm/cool spines from the title,
/// like a shelf of paperbacks (Kobo tiles / Kindle home covers).
struct CoverTile: View {
    let title: String
    let author: String
    var width: CGFloat = 108

    private var height: CGFloat { width * 1.5 }

    private var seed: Int {
        title.unicodeScalars.reduce(0) { $0 + Int($1.value) }
    }

    private var topColor: Color {
        let hues: [Double] = [0.07, 0.09, 0.58, 0.6, 0.35, 0.02]
        return Color(hue: hues[seed % hues.count], saturation: 0.32, brightness: 0.72)
    }

    private var bottomColor: Color {
        Color(hue: 0.08, saturation: 0.28, brightness: 0.34 + Double(seed % 3) * 0.05)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [topColor, bottomColor],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // spine shading
            HStack(spacing: 0) {
                Rectangle()
                    .fill(.black.opacity(0.22))
                    .frame(width: 4)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(AppFont.serif(13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                if !author.isEmpty {
                    Text(author)
                        .font(AppFont.ui(9))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.tileRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.tileRadius)
                .strokeBorder(.black.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: AppPalette.shelfShadow, radius: 4, x: 0, y: 3)
    }
}

/// Thin book-edge progress bar (Kindle "progress spine").
struct ReadingRibbon: View {
    let value: Double // 0...1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.black.opacity(0.1))
                Capsule()
                    .fill(AppPalette.ember)
                    .frame(width: max(4, geo.size.width * value))
            }
        }
        .frame(height: 3)
    }
}

struct SectionBanner: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(AppFont.serif(24, weight: .semibold))
                .foregroundStyle(Color(red: 0.13, green: 0.12, blue: 0.1))
            if let subtitle {
                Text(subtitle)
                    .font(AppFont.ui(12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EmberButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(AppFont.ui(15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(AppPalette.ember, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
        }
    }
}

struct QuietButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(AppFont.ui(14, weight: .medium))
            .foregroundStyle(AppPalette.ember)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cardRadius)
                    .strokeBorder(AppPalette.ember.opacity(0.4), lineWidth: 1)
            )
        }
    }
}
