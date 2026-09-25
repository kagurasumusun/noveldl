import SwiftUI
import UIKit
import CoreText

/// CoreText page canvas — slices an NSAttributedString into pages and
/// draws them like a printed sheet (no WKWebView).
/// ジェスチャは ReaderView 側に一本化(ここは純粋な描画のみ)。
struct PageCanvas: UIViewRepresentable {
    let pages: [NSAttributedString]
    @Binding var pageIndex: Int
    let background: UIColor
    var insets: UIEdgeInsets = UIEdgeInsets(top: 54, left: 34, bottom: 64, right: 34)

    func makeUIView(context: Context) -> PageCanvasView {
        let view = PageCanvasView()
        view.backgroundColor = background
        view.insets = insets
        return view
    }

    func updateUIView(_ view: PageCanvasView, context: Context) {
        view.backgroundColor = background
        view.insets = insets
        view.pages = pages
        view.pageIndex = pageIndex
        view.setNeedsDisplay()
    }
}

final class PageCanvasView: UIView {
    var pages: [NSAttributedString] = []
    var pageIndex = 0
    var insets = UIEdgeInsets(top: 54, left: 34, bottom: 64, right: 34)

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(),
            pages.indices.contains(pageIndex)
        else { return }
        ctx.setFillColor(backgroundColor?.cgColor ?? UIColor.white.cgColor)
        ctx.fill(rect)

        let contentRect = rect.inset(by: insets)
        guard contentRect.width > 8, contentRect.height > 8 else { return }

        let page = pages[pageIndex]
        let path = CGPath(rect: contentRect, transform: nil)
        let framesetter = CTFramesetterCreateWithAttributedString(page as CFAttributedString)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: page.length), path,
            NSDictionary() as CFDictionary)

        ctx.textMatrix = .identity
        // CoreText は下原点。コンテンツ矩形内で上下だけ反転し、パス座標
        // (UIKit 上原点)の位置にそのまま収まるようにする。
        ctx.translateBy(x: 0, y: contentRect.minY + contentRect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        CTFrameDraw(frame, ctx)
    }
}

/// Pagination engine — CTFramesetter slices by FITTED (visible) line ranges.
enum PagePaginator {
    static func paginate(
        _ text: NSAttributedString,
        pageSize: CGSize,
        insets: UIEdgeInsets
    ) -> [NSAttributedString] {
        let content = CGSize(
            width: max(40, pageSize.width - insets.left - insets.right),
            height: max(40, pageSize.height - insets.top - insets.bottom))
        guard text.length > 0 else { return [] }

        var pages: [NSAttributedString] = []
        let full = text
        var offset = 0
        let framesetter = CTFramesetterCreateWithAttributedString(full as CFAttributedString)

        while offset < full.length {
            let remaining = full.length - offset
            let path = CGPath(
                rect: CGRect(origin: .zero, size: content), transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter, CFRange(location: offset, length: remaining), path,
                NSDictionary() as CFDictionary)
            // 重要:実際に版面に収まった文字数は VISIBLE 範囲。GetStringRange は
            // 依頼範囲(=残り全部)を返してしまうため、1 話が必ず 1 ページになり、
            // 「本文が読めない」「タップで即次話」の原因になっていた。
            let visible = CTFrameGetVisibleStringRange(frame)
            var fitted = visible.length
            if fitted <= 0 {
                fitted = min(remaining, 200) // safety: force progress
            }
            let slice = full.attributedSubstring(
                from: NSRange(location: offset, length: fitted))
            pages.append(slice)
            offset += fitted
            if pages.count > 2000 { break } // runaway guard
        }
        return pages
    }
}
