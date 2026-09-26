import SwiftUI
import UIKit

/// ページめくりの演出。
enum PageTurn: String, CaseIterable {
    case curl, slide, fade, none

    var label: String {
        switch self {
        case .curl: return "なめらか"
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
    /// 本文色。ダークモードが attributedText の色を潰すときの基準にもする。
    var ink: UIColor = UIColor(red: 0.125, green: 0.118, blue: 0.102, alpha: 1)

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
        // 上下バー(タップで出没)と本文のバランス。バー自体をスリム化
        // (約38/40pt)したので、余白は「バー + 呼吸の8pt」程度に抑え、
        // 本文の帯を最大化する。バーが見えている間も同じ帯で組版する
        // (出没で再分割しない)。
        let top = max(54.0, safe.top + 42.0)
        let bottom = max(60.0, safe.bottom + 48.0)
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
        // 文字色だけの変更(紙→夜)は長さも書体も同じなので、下の幾何キーには出ない。
        // ここで検知しないと、背景だけ黒くなって本文が墨色のまま残り、読めなくなる。
        let textChanged = !fullText.isEqual(to: text)
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
                keyParts.append(f0.familyName)
            }
            if let fm = text.attribute(.font, at: mid, effectiveRange: nil) as? UIFont {
                keyParts.append(String(Int(fm.pointSize * 10)))
            }
            // 行間の変更はフォントに現れない
            if let p0 = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle {
                keyParts.append(String(Int(p0.lineSpacing * 10)))
            }
            // 文字色だけの変更も幾何キーに入れる。isEqual が見逃しても再表示する。
            if let c = text.attribute(.foregroundColor, at: min(text.length - 1, max(0, text.length / 2)), effectiveRange: nil) as? UIColor {
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                if c.getRed(&r, green: &g, blue: &b, alpha: &a) {
                    keyParts.append("\(Int(r * 255))-\(Int(g * 255))-\(Int(b * 255))")
                }
            }
        }
        let key = keyParts.joined(separator: "|")
        if key == geomKey, !pageRanges.isEmpty {
            if textChanged {
                lastShownRange = NSRange(location: NSNotFound, length: 0)
                if !keepIndex { pageIndex = 0 }
            }
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
        // textColor を先に固定してから本文を載せる。
        // 後から textColor を入れると、見出しの濃さまで一色に潰れる。
        v.textColor = ink
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

    /// 指定ページへ飛ぶ。スライダー操作なのでアニメーションは掛けない。
    func jump(to index: Int) {
        guard pageCount > 0, view != nil else { return }
        let clamped = min(max(index, 0), pageCount - 1)
        guard clamped != pageIndex else { return }
        pageIndex = clamped
        displayCurrent(force: true)
        notifyPage()
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
            // 旧 CATransition の pageCurl は鉤括弧的な安っぽさがあったため、
            // 「古い頁がわずかに流れ、新しい頁がふわりと沈む」上品な
            // スライド+フェードに置き換えた。
            snapshotTransition(v, forward: forward, distance: 42, duration: 0.30, change: change)
        case .slide:
            snapshotTransition(v, forward: forward, distance: v.bounds.width, duration: 0.28, fullPush: true, change: change)
        case .fade:
            UIView.transition(with: v, duration: 0.24, options: [.transitionCrossDissolve, .allowUserInteraction],
                              animations: change)
        case .none:
            change()
        }
    }

    /// 旧頁のスナップショットを残し、新頁を軽いオフセット+フェードで重ねる。
    /// 演出は短く(≤0.3s)・easeOut で静かに畳む。
    private func snapshotTransition(_ v: UIView, forward: Bool, distance: CGFloat,
                                    duration: CFTimeInterval, fullPush: Bool = false,
                                    change: @escaping () -> Void) {
        guard let superview = v.superview,
              let snap = v.snapshotView(afterScreenUpdates: false) else {
            change()
            return
        }
        snap.frame = v.frame
        snap.isUserInteractionEnabled = false
        superview.addSubview(snap)
        change()

        let dir: CGFloat = forward ? 1 : -1
        v.alpha = fullPush ? 1 : 0
        v.transform = CGAffineTransform(translationX: dir * distance * (fullPush ? 1 : 0.28), y: 0)
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            v.alpha = 1
            v.transform = .identity
            snap.alpha = fullPush ? 0.25 : 0
            snap.transform = CGAffineTransform(translationX: -dir * distance * (fullPush ? 0.35 : 0.16), y: 0)
        } completion: { _ in
            snap.removeFromSuperview()
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

    /// 紙面の色を UITextView に直接渡す。
    /// SwiftUI Color 経由だと、アプリ全体がダークのとき夜テーマの文字が黒になり読めない。
    private func applyPageColors(_ tv: UITextView) {
        tv.backgroundColor = theme.uiBackground
        tv.textColor = theme.uiInk
        tv.tintColor = theme.uiInk
        // 紙・セピアは明るい紙面なのでライト扱い。夜だけダーク。
        // アプリのダーク指定を紙面に引き継ぐと、システムが文字色を書き換える。
        tv.overrideUserInterfaceStyle = theme == .night ? .dark : .light
        box.ink = theme.uiInk
    }

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
        applyPageColors(tv)
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

        applyPageColors(tv)

        // サイズ/余白の確定。分割の作り直しは prepare が幾何キーで判断する。
        if let page = tv as? PageTextView, pageSize != page.fixedSize {
            page.fixedSize = pageSize
        }
        box.refreshPads()
        tv.textContainerInset = UIEdgeInsets(top: box.padTop, left: sideMargin, bottom: box.padBottom, right: sideMargin)
        tv.textContainer.size = CGSize(width: containerWidth(),
                                       height: CGFloat.greatestFiniteMagnitude)
        box.view = tv
        box.turn = turn

        // 文字色・書体だけの変更では読んでいるページを維持する。
        // 本文の文字列が変わったとき(別の版・取り直し)だけ先頭へ戻す。
        let previous = context.coordinator.applied
        let sameText = previous.isEqual(to: attributed)
        if !sameText {
            context.coordinator.applied = attributed
        }
        let bodyReplaced = !sameText && previous.string != attributed.string
        box.prepare(text: attributed, containerWidth: containerWidth(),
                    viewHeight: pageSize.height, keepIndex: !bodyReplaced)
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
