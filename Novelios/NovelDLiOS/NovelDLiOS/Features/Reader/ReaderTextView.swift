import SwiftUI
import UIKit

/// ページめくりの演出。
enum PageTurn: String, CaseIterable {
    case curl, slide, fade, none

    var label: String {
        switch self {
        case .curl: return "紙捲り"
        case .slide: return "スライド"
        case .fade: return "フェード"
        case .none: return "なし"
        }
    }

    static var all: [PageTurn] { [.curl, .fade, .slide, .none] }
}

/// サイズを完全に固定した UITextView。
/// isScrollEnabled = false の UITextView は sizeThatFits が「コンテンツが
/// 収まるサイズ」を返すため、SwiftUI がそのサイズを尊重して画面より巨大な
/// ビューを中央に置いてしまう(左右が切れる原因)。サイズ要求にはすべて
/// 確定済みの fixedSize で答えて防ぐ。
final class PageTextView: UITextView {
    var fixedSize: CGSize = .zero {
        didSet {
            if fixedSize != bounds.size {
                frame = CGRect(origin: .zero, size: fixedSize)
                invalidateIntrinsicContentSize()
                setNeedsLayout()
            }
        }
    }

    override var intrinsicContentSize: CGSize { fixedSize }

    override func sizeThatFits(_ size: CGSize) -> CGSize { fixedSize }
}

/// ページ分割と表示を管理する(オフセット操作は一切しない)。
///
/// 旧実装は UITextView の contentOffset を動かしてページングしていたため、
/// セーフエリア確定タイミングやスクロール無効時の内部リセットと噛み合わず、
/// 「本文が表示されない」「ページ位置が吹む」ことがあった。
/// 現実装は TextKit で全行を測り、本文帯に収まる行ごとに本文を「分割」して
/// 1ページずつ丸ごと表示する。表示内容が必ず画面内に収まるため、
/// オフセット調整は構造的に不要。
final class ScrollBox {
    weak var view: UITextView?
    var turn: PageTurn = .curl

    /// 1ページ = 上余白(padTop)+ 本文帯 + 下余白(padBottom)。
    /// 余白は textContainerInset 側で確保する。値はセーフエリアから取り直す。
    var padTop: CGFloat = 66
    var padBottom: CGFloat = 52

    private(set) var pageCount = 1
    private(set) var pageIndex = 0
    /// (pageIndex, pageCount) — 表示が変わったら呼ばれる。
    var onPage: ((Int, Int) -> Void)?

    private var fullText = NSAttributedString()
    private var pageRanges: [NSRange] = []
    private var geomKey = ""
    private var lastWidth: CGFloat = 0
    private var lastHeight: CGFloat = 0
    /// 本文がまだ prepare されていない時期に届いた挿絵の保留列。
    /// (rebuild が loadImages を先にspawnし、SwiftUI の更新が後から来る競合対策)
    private var pendingImages: [(range: NSRange, image: UIImage, width: CGFloat)] = []
    /// 直前に表示したページ範囲(同じなら attributedText の再設定をしない)。
    private var lastShownRange = NSRange(location: NSNotFound, length: 0)
    /// 直前に通知したページ位置。同じ値の通知を繰り返すと
    /// prepare → onPage → @State → updateUIView → prepare → … の
    /// 無限ループになるため、変化したときだけ通知する。
    private var lastNotifiedPage = -1
    private var lastNotifiedCount = -1

    /// セーフエリアを取り直す。変化があったかを返す。
    @discardableResult
    func refreshPads() -> Bool {
        guard let v = view else { return false }
        let safe = v.safeAreaInsets
        let top = max(30.0, safe.top + 18.0)
        let bottom = max(40.0, safe.bottom + 20.0)
        guard top != padTop || bottom != padBottom else { return false }
        padTop = top
        padBottom = bottom
        return true
    }

    /// 幾何キャッシュを捨てる(挿絵差し替えなどで再分割させたいとき)。
    func invalidateGeometry() {
        geomKey = ""
    }

    /// 本文と幾何を取り込み、必要なら分割を作り直して現在ページを表示する。
    /// 同一テキスト・同一幾何の再呼び出しは安価(表示の張り直しのみ)。
    func prepare(text: NSAttributedString, containerWidth: CGFloat, viewHeight: CGFloat, keepIndex: Bool) {
        lastWidth = containerWidth
        lastHeight = viewHeight
        fullText = text

        let band = max(viewHeight - padTop - padBottom, 120)
        var keyParts: [String] = [
            String(text.length),
            String(Int(containerWidth)),
            String(Int(band)),
            String(Int(padTop)),
            String(Int(padBottom)),
        ]
        // スタイル(文字サイズ/行間/書体)変化も検知する(長さが同じでも高さが変わる)。
        if text.length > 0 {
            let mid = min(text.length - 1, max(0, text.length / 2))
            if let f0 = text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont {
                keyParts.append(String(Int(f0.pointSize * 10)))
                // 書体(明朝/ゴシック)の変更はサイズだけでは検知できない
                keyParts.append(f0.familyName ?? f0.fontName)
            }
            if let fm = text.attribute(.font, at: mid, effectiveRange: nil) as? UIFont {
                keyParts.append(String(Int(fm.pointSize * 10)))
            }
            // 行間の変更はフォントに現れない
            if let p0 = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle {
                keyParts.append(String(Int(p0.lineSpacing * 10)))
            }
        }
        let key = keyParts.joined(separator: "|")
        if key == geomKey, !pageRanges.isEmpty {
            displayCurrent()
            return
        }
        geomKey = key
        var working = text
        // 保留されていた挿絵があれば本文に反映してから分割する。
        if !pendingImages.isEmpty {
            let m = NSMutableAttributedString(attributedString: working)
            for p in pendingImages where NSMaxRange(p.range) <= m.length {
                m.addAttribute(.attachment, value: attachment(for: p.image, width: p.width), range: p.range)
            }
            pendingImages = []
            working = m
            fullText = working
        }
        pageRanges = Self.paginate(working, width: containerWidth, band: band)
        pageCount = max(pageRanges.count, 1)
        if !keepIndex {
            pageIndex = 0
        }
        pageIndex = min(pageIndex, pageCount - 1)
        lastShownRange = NSRange(location: NSNotFound, length: 0)
        displayCurrent()
        notifyPage()
    }

    /// 全行を測り、本文帯(band)に収まる行ごとにページ区切りを作る。
    private static func paginate(_ text: NSAttributedString, width: CGFloat, band: CGFloat) -> [NSRange] {
        guard text.length > 0 else { return [] }
        let storage = NSTextStorage(attributedString: text)
        let lm = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(width, 1),
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        lm.addTextContainer(container)
        storage.addLayoutManager(lm)
        lm.ensureLayout(for: container)

        var lineRanges: [NSRange] = []
        var lineTop: [CGFloat] = []
        var lineBottom: [CGFloat] = []
        var gi = 0
        let total = lm.numberOfGlyphs
        while gi < total {
            var glyphRange = NSRange(location: gi, length: 0)
            let frag = lm.lineFragmentRect(forGlyphAt: gi, effectiveRange: &glyphRange)
            if glyphRange.length <= 0 { break }
            let charRange = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            lineRanges.append(charRange)
            lineTop.append(frag.minY)
            lineBottom.append(frag.maxY)
            gi = NSMaxRange(glyphRange)
        }
        guard !lineRanges.isEmpty else { return [NSRange(location: 0, length: text.length)] }

        var pages: [NSRange] = []
        var i = 0
        while i < lineRanges.count {
            var j = i
            while j + 1 < lineRanges.count && lineBottom[j + 1] - lineTop[i] <= band { j += 1 }
            let loc = lineRanges[i].location
            let end = NSMaxRange(lineRanges[j])
            if end > loc {
                pages.append(NSRange(location: loc, length: end - loc))
            }
            i = j + 1
        }
        return pages
    }

    private func displayCurrent(force: Bool = false) {
        guard let v = view else { return }
        let range = pageRanges.isEmpty
            ? NSRange(location: 0, length: fullText.length)
            : pageRanges[min(pageIndex, pageRanges.count - 1)]
        // 同じ範囲を表示中なら再設定しない(SwiftUI 更新のたびに
        // attributedText を張り直すとちらつきと無駄な再レイアウトの元)。
        if !force,
           lastShownRange.location == range.location,
           lastShownRange.length == range.length {
            return
        }
        lastShownRange = range
        v.attributedText = fullText.attributedSubstring(from: range)
    }

    private func show(_ index: Int, forward: Bool) {
        let clamped = min(max(index, 0), pageCount - 1)
        guard clamped != pageIndex, let v = view else { return }
        animate(v, forward: forward) { [weak self] in
            guard let self else { return }
            self.pageIndex = clamped
            self.displayCurrent(force: true)
        }
        notifyPage()
    }

    private func notifyPage() {
        // 値が変わっていないのに通知すると、onPage → @State 更新 →
        // updateUIView → prepare → notifyPage の静止しないループになる。
        if pageIndex == lastNotifiedPage && pageCount == lastNotifiedCount {
            return
        }
        lastNotifiedPage = pageIndex
        lastNotifiedCount = pageCount
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onPage?(self.pageIndex, self.pageCount)
        }
    }

    @discardableResult
    func pageDown() -> Bool {
        guard pageIndex + 1 < pageCount else { return false }  // 最終ページ = 次の話へ
        show(pageIndex + 1, forward: true)
        return true
    }

    @discardableResult
    func pageUp() -> Bool {
        guard pageIndex > 0 else { return false }  // 先頭ページ = 前の話へ
        show(pageIndex - 1, forward: false)
        return true
    }

    var atFirstPage: Bool { pageIndex == 0 }
    var atLastPage: Bool { pageIndex >= pageCount - 1 }

    private func attachment(for image: UIImage, width: CGFloat) -> NSTextAttachment {
        let scale = width / max(image.size.width, 1)
        let size = CGSize(
            width: min(width, image.size.width * scale),
            height: image.size.height * scale
        )
        let att = NSTextAttachment()
        att.image = image
        att.bounds = CGRect(x: 0, y: -4, width: size.width, height: size.height)
        return att
    }

    /// 挿絵を実画像へ差し替える(レンジは結合後の全文テキスト上)。
    func applyImage(at range: NSRange, image: UIImage, displayWidth: CGFloat) {
        // まだ本文が載っていない(初回レイアウト前)なら次の prepare で反映する。
        guard fullText.length > 0, lastWidth > 0 else {
            pendingImages.append((range, image, displayWidth))
            return
        }
        guard NSMaxRange(range) <= fullText.length else { return }
        let updated = NSMutableAttributedString(attributedString: fullText)
        updated.addAttribute(.attachment, value: attachment(for: image, width: displayWidth), range: range)
        // 画像は行高を変えるが geomKey(長さ/書体/行間)には現れないので、
        // 強制的に再分割する(表示ページは維持)。
        geomKey = ""
        prepare(text: updated, containerWidth: lastWidth, viewHeight: lastHeight, keepIndex: true)
    }

    private func animate(_ v: UIView, forward: Bool, _ change: @escaping () -> Void) {
        Haptics.tap()
        switch turn {
        case .curl:
            let t = CATransition()
            t.type = CATransitionType(rawValue: forward ? "pageCurl" : "pageUnCurl")
            t.subtype = forward ? .fromRight : .fromLeft
            t.duration = 0.36
            t.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            v.layer.add(t, forKey: "reader.pageCurl")
            change()
        case .slide:
            let t = CATransition()
            t.duration = 0.30
            t.type = .push
            t.subtype = forward ? .fromRight : .fromLeft
            t.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            v.layer.add(t, forKey: "turn")
            change()
        case .fade:
            UIView.transition(with: v, duration: 0.26, options: [.transitionCrossDissolve, .allowUserInteraction],
                              animations: change)
        case .none:
            change()
        }
    }
}

struct ReaderTextView: UIViewRepresentable {
    var attributed: NSAttributedString
    var theme: BookTheme
    var box: ScrollBox
    /// 確定済みの表示サイズ(GeometryReader 由来)。
    var pageSize: CGSize
    var turn: PageTurn = .curl
    var sideMargin: CGFloat = 28
    var swipePaging: Bool = true
    var onCenterTap: () -> Void = {}
    var onTurn: () -> Void = {}
    var onPrevPage: () -> Void = {}
    var onNextPage: () -> Void = {}
    var onReachStart: () -> Void = {}
    var onReachEnd: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private func containerWidth() -> CGFloat {
        max(pageSize.width - sideMargin * 2, 1)
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = PageTextView()
        tv.fixedSize = pageSize
        tv.frame = CGRect(origin: .zero, size: pageSize)
        tv.backgroundColor = UIColor(theme.background)
        tv.isEditable = false
        tv.isSelectable = false
        tv.isScrollEnabled = false
        tv.isPagingEnabled = false
        tv.alwaysBounceVertical = false
        tv.contentInsetAdjustmentBehavior = .never
        tv.layoutManager.allowsNonContiguousLayout = false
        tv.textContainer.widthTracksTextView = false
        tv.textContainer.heightTracksTextView = false
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainerInset = UIEdgeInsets(top: box.padTop, left: sideMargin, bottom: box.padBottom, right: sideMargin)
        tv.textContainer.size = CGSize(width: containerWidth(),
                                       height: CGFloat.greatestFiniteMagnitude)
        tv.showsVerticalScrollIndicator = false

        let taps = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tv.addGestureRecognizer(taps)

        let leftSwipe = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swipedPrev))
        leftSwipe.direction = .right  // 左から右 = 前のページへ戻る
        let rightSwipe = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swipedNext))
        rightSwipe.direction = .left  // 右から左 = 次のページへ
        [leftSwipe, rightSwipe].forEach {
            $0.delegate = context.coordinator
            tv.addGestureRecognizer($0)
        }
        // スワイプ判定が確定するまでタップを待たせる(二重発火の防止)。
        taps.require(toFail: leftSwipe)
        taps.require(toFail: rightSwipe)
        context.coordinator.swipeEnabled = swipePaging
        box.view = tv
        box.turn = turn
        context.coordinator.box = box
        box.prepare(text: attributed, containerWidth: containerWidth(),
                    viewHeight: pageSize.height, keepIndex: false)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.onCenterTap = onCenterTap
        context.coordinator.onTurn = onTurn
        context.coordinator.onPrevPage = onPrevPage
        context.coordinator.onNextPage = onNextPage
        context.coordinator.onReachStart = onReachStart
        context.coordinator.onReachEnd = onReachEnd
        context.coordinator.swipeEnabled = swipePaging

        tv.backgroundColor = UIColor(theme.background)

        // サイズ/余白の確定。変化があれば分割を作り直す(表示ページは維持)。
        var geometryChanged = false
        if let page = tv as? PageTextView, pageSize != page.fixedSize {
            page.fixedSize = pageSize
            geometryChanged = true
        }
        if box.refreshPads() {
            geometryChanged = true
        }
        tv.textContainerInset = UIEdgeInsets(top: box.padTop, left: sideMargin, bottom: box.padBottom, right: sideMargin)
        tv.textContainer.size = CGSize(width: containerWidth(),
                                       height: CGFloat.greatestFiniteMagnitude)
        box.view = tv
        box.turn = turn

        // 入れ替わり検知(本文 or スタイル変更)。
        let sameText = context.coordinator.applied.isEqual(to: attributed)
        if !sameText {
            context.coordinator.applied = attributed
            geometryChanged = true
        }
        box.prepare(text: attributed, containerWidth: containerWidth(),
                    viewHeight: pageSize.height, keepIndex: !geometryChanged)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: ReaderTextView
        var box: ScrollBox?
        var swipeEnabled = true
        var applied = NSAttributedString()
        var onCenterTap: () -> Void = {}
        var onTurn: () -> Void = {}
        var onPrevPage: () -> Void = {}
        var onNextPage: () -> Void = {}
        var onReachStart: () -> Void = {}
        var onReachEnd: () -> Void = {}

        init(parent: ReaderTextView) {
            self.parent = parent
            self.onCenterTap = parent.onCenterTap
            self.onTurn = parent.onTurn
            self.onPrevPage = parent.onPrevPage
            self.onNextPage = parent.onNextPage
            self.onReachStart = parent.onReachStart
            self.onReachEnd = parent.onReachEnd
        }

        @objc func swipedNext() {
            guard swipeEnabled else { return }
            onTurn()
            if !(box?.pageDown() ?? false) {
                onReachEnd()  // 最後のページから次へ = 次の話へ
            }
        }

        @objc func swipedPrev() {
            guard swipeEnabled else { return }
            onTurn()
            if !(box?.pageUp() ?? false) {
                onReachStart()  // 最初のページから前へ = 前の話へ
            }
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let tv = gesture.view as? UITextView else { return }
            let p = gesture.location(in: tv)
            let w = tv.bounds.width
            // 端(外側2割)だけが送り。中央はメニュー出没に充てる。
            if p.x < w * 0.20 {
                onTurn()
                if !(box?.pageUp() ?? false) { onReachStart() }
            } else if p.x > w * 0.80 {
                onTurn()
                if !(box?.pageDown() ?? false) { onReachEnd() }
            } else {
                onCenterTap()
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
