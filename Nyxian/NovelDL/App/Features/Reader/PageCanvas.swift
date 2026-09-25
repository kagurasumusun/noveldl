import SwiftUI
import CoreText

/// CoreText page canvas — slices an NSAttributedString into pages and
/// draws them like a printed sheet (no WKWebView).
struct PageCanvas: UIViewRepresentable {
    let pages: [NSAttributedString]
    @Binding var pageIndex: Int
    let background: UIColor
    var onSwipeNext: () -> Void
    var onSwipePrevious: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> PageCanvasView {
        let view = PageCanvasView()
        view.backgroundColor = background
        view.coordinator = context.coordinator
        let next = UISwipeGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.swipeNext))
        next.direction = .left
        let prev = UISwipeGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.swipePrev))
        prev.direction = .right
        view.addGestureRecognizer(next)
        view.addGestureRecognizer(prev)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: PageCanvasView, context: Context) {
        view.backgroundColor = background
        view.pages = pages
        view.pageIndex = pageIndex
        view.setNeedsDisplay()
    }

    final class Coordinator: NSObject {
        let parent: PageCanvas
        init(_ parent: PageCanvas) { self.parent = parent }

        @objc func swipeNext() { parent.onSwipeNext() }
        @objc func swipePrev() { parent.onSwipePrevious() }
        @objc func tapped() { parent.onSwipeNext() }
    }
}

final class PageCanvasView: UIView {
    var pages: [NSAttributedString] = []
    var pageIndex = 0
    weak var coordinator: PageCanvas.Coordinator?

    private let inset = UIEdgeInsets(top: 54, left: 34, bottom: 64, right: 34)

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(),
            pages.indices.contains(pageIndex)
        else { return }
        ctx.setFillColor(backgroundColor?.cgColor ?? UIColor.white.cgColor)
        ctx.fill(rect)

        let contentRect = rect.inset(by: inset)
        guard contentRect.width > 8, contentRect.height > 8 else { return }

        let page = pages[pageIndex]
        let path = CGPath(rect: contentRect, transform: nil)
        let framesetter = CTFramesetterCreateWithAttributedString(page as CFAttributedString)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: page.length), path, nil)

        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: rect.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: contentRect.minX, y: rect.height - contentRect.maxY)
        CTFrameDraw(frame, ctx)
    }
}

/// Pagination engine — CTFramesetter slices by fitted line ranges.
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
                framesetter, CFRange(location: offset, length: remaining), path, nil)
            let range = CTFrameGetStringRange(frame)
            var fitted = range.length
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
