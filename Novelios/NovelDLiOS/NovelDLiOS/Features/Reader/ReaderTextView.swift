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

/// UITextView 本体。行境界に吸着させた 1 スクリーン = 1 ページの横送り。
/// 余白は左右のマージンのみで、額縁のような箱にはしない。
final class ScrollBox {
    weak var view: UITextView?
    var turn: PageTurn = .curl

    /// 1ページ = 上余白(padTop)+ 本文帯 + 下余白(padBottom)。
    /// 余白は contentInset 側で確保する。値はセーフエリア(ノッチ/ホームバー)から
    /// 送りのたびに取り直す。ビューがウィンドウに載る前は safeAreaInsets が 0 なので、
    /// 「レイアウト時に一度だけ確定」だと本文がノッチやホームバーに食い込み、
    /// 「リーダーが画面に収まらない」原因になっていた。
    var padTop: CGFloat = 66
    var padBottom: CGFloat = 52

    /// 全行の上端/下端(本文コンテンツ座標)。ページ送りは必ず行の区切りへ吸着させ、
    /// どのページでも最終行が下余白へ半分だけ食い込むことがないようにする。
    private var lineTop: [CGFloat] = []
    private var lineBottom: [CGFloat] = []
    private var lineCacheLength = -1
    private var lineCacheWidth: CGFloat = -1
    private var lineCacheInsetTop: CGFloat = -1

    private var band: CGFloat {
        guard let v = view else { return 200 }
        return max(v.bounds.height - padTop - padBottom, 120)
    }
    private var minOffset: CGFloat { -padTop }

    /// セーフエリアを取り直し、変わっていれば contentInset と行情報を更新する。
    func refreshPads() {
        guard let v = view else { return }
        let safe = v.safeAreaInsets
        let top = max(30.0, safe.top + 18.0)
        let bottom = max(40.0, safe.bottom + 20.0)
        guard top != padTop || bottom != padBottom else { return }
        padTop = top
        padBottom = bottom
        v.contentInset = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        invalidateLines()
    }

    func invalidateLines() {
        lineCacheLength = -1
        lineCacheWidth = -1
        lineCacheInsetTop = -1
        lineTop = []
        lineBottom = []
    }

    /// 全行の上下端を TextKit から収集(テキスト/幅/上インセットが変わらなければ再利用)。
    private func rebuildLinesIfNeeded() {
        guard let v = view, let storage = v.textStorage, let lm = v.layoutManager else { return }
        if storage.length == lineCacheLength,
           v.bounds.width == lineCacheWidth,
           v.textContainerInset.top == lineCacheInsetTop,
           !lineTop.isEmpty {
            return
        }
        lm.ensureLayout(for: v.textContainer)
        lineTop = []
        lineBottom = []
        lineCacheLength = storage.length
        lineCacheWidth = v.bounds.width
        lineCacheInsetTop = v.textContainerInset.top
        if storage.length > 0 {
            let insetTop = v.textContainerInset.top
            let full = NSRange(location: 0, length: storage.length)
            lm.enumerateLineFragments(forGlyphRange: full) { [weak self] rect, _, _, _, _ in
                guard let self else { return }
                self.lineTop.append(rect.minY + insetTop)
                self.lineBottom.append(rect.maxY + insetTop)
            }
        }
        if lineTop.isEmpty {
            lineTop = [0]
            lineBottom = [v.contentSize.height]
        }
    }

    /// 現在の表示上端(contentOffset + padTop)に対応する先頭行の添字。
    private func firstLineIndex(visibleTop: CGFloat) -> Int {
        var i = 0
        while i + 1 < lineTop.count && lineTop[i + 1] <= visibleTop + 0.5 { i += 1 }
        return i
    }

    /// 最終ページの開始オフセット(本文の末尾を帯に収める行合わせの位置)。
    private var lastPageStartOffset: CGFloat {
        lineTop.isEmpty ? minOffset : max(minOffset, lineTop[lastStartLineIndex] - padTop)
    }

    /// 最終ページの開始行(末尾だけを収めるよう後ろから詰めた位置)。
    private var lastStartLineIndex: Int {
        guard !lineTop.isEmpty else { return 0 }
        let bottom = lineBottom[lineBottom.count - 1]
        var s = lineTop.count - 1
        while s > 0 && bottom - lineTop[s - 1] <= band { s -= 1 }
        return s
    }

    /// ページ送りの連鎖(pageDown の詰め方 + 最終ページのクランプ)と同じ並びで、
    /// 行 i を先頭とするページの「前のページの先頭行」を求める。
    /// これで前へ戻るときも、順方向と同じページ区切りを正確に逆順に辿れる。
    private func previousStartLineIndex(before i: Int) -> Int {
        guard i > 0 else { return 0 }
        let lastStart = lastStartLineIndex
        var prevStart = 0
        var p = 0
        while p < i {
            var j = p
            while j + 1 < lineBottom.count && lineBottom[j + 1] - lineTop[p] <= band { j += 1 }
            var nxt = j + 1
            if nxt > lastStart { nxt = lastStart }
            if nxt == i { return p }
            if nxt > i { return prevStart }  // 通常起こらない(防御)
            prevStart = p
            p = nxt
        }
        return prevStart
    }

    @discardableResult
    func pageDown() -> Bool {
        guard let v = view else { return false }
        refreshPads()
        rebuildLinesIfNeeded()
        guard !lineTop.isEmpty else { return false }
        let i = firstLineIndex(visibleTop: v.contentOffset.y + padTop)
        // 現ページの先頭行から、本文帯に完全に収まる最後の行を求める
        var j = i
        while j + 1 < lineBottom.count && lineBottom[j + 1] - lineTop[i] <= band { j += 1 }
        guard j + 1 < lineTop.count else { return false }  // すでに最終ページ
        var target = lineTop[j + 1] - padTop
        let lastStart = lastPageStartOffset
        if target > lastStart { target = lastStart }
        if target <= v.contentOffset.y + 0.5 { return false }
        animate(v, forward: true) {
            v.contentOffset = CGPoint(x: 0, y: target)
        }
        return true
    }

    @discardableResult
    func pageUp() -> Bool {
        guard let v = view else { return false }
        refreshPads()
        rebuildLinesIfNeeded()
        guard !lineTop.isEmpty else { return false }
        let i = firstLineIndex(visibleTop: v.contentOffset.y + padTop)
        guard i > 0 else { return false }
        let s = previousStartLineIndex(before: i)
        let target = max(minOffset, lineTop[s] - padTop)
        if target >= v.contentOffset.y - 0.5 { return false }
        animate(v, forward: false) {
            v.contentOffset = CGPoint(x: 0, y: target)
        }
        return true
    }

    var atFirstPage: Bool {
        guard let v = view else { return true }
        return v.contentOffset.y <= minOffset + 1
    }

    var atLastPage: Bool {
        guard let v = view else { return true }
        refreshPads()
        rebuildLinesIfNeeded()
        return v.contentOffset.y >= lastPageStartOffset - 1
    }

    /// 挿絵を実画像へ差し替える(レンジは現在の textStorage 上)。
    func applyImage(at range: NSRange, image: UIImage, displayWidth: CGFloat) {
        guard let v = view else { return }
        let storage = v.textStorage
        guard NSMaxRange(range) <= storage.length else { return }
        let scale = displayWidth / max(image.size.width, 1)
        let size = CGSize(
            width: min(displayWidth, image.size.width * scale),
            height: image.size.height * scale
        )
        let att = NSTextAttachment()
        att.image = image
        att.bounds = CGRect(x: 0, y: -4, width: size.width, height: size.height)
        // テキスト編集で contentOffset が先頭へ戻されることがあるため退避しておく。
        let keepOffset = v.contentOffset
        storage.beginEditing()
        storage.addAttribute(.attachment, value: att, range: range)
        storage.endEditing()
        if v.contentOffset != keepOffset {
            v.contentOffset = keepOffset
        }
        // 添付差し替えで本文の高さが変わるため行情報を作り直す。
        invalidateLines()
    }

    private func animate(_ v: UIView, forward: Bool, _ change: @escaping () -> Void) {
        Haptics.tap()
        switch turn {
        case .curl:
            // CATransition の pageCurl(UIView.transition の配列リテラル回避)
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

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.backgroundColor = UIColor(theme.background)
        tv.isEditable = false
        tv.isSelectable = false
        // 送りは「横スワイプ / 左右タップ」の一本化。縦スクロールは無効
        //(縦と横の同時有効をやめ、端では次/前の話へ自動遷移させる)。
        tv.isScrollEnabled = false
        tv.isPagingEnabled = false
        tv.alwaysBounceVertical = false
        tv.contentInsetAdjustmentBehavior = .never
        // 本文全体をレイアウトさせる(しないと1画面で切れて「本文が出ない」)。
        tv.layoutManager.allowsNonContiguousLayout = false
        // 幅はビューに追従させる(width: 0 指定だと折り返しが壊れて横にはみ出す)。
        tv.textContainer.widthTracksTextView = true
        tv.textContainer.heightTracksTextView = false
        // 左右のみ本文インセット。上下の余白は contentInset で全ページ均等に確保。
        tv.textContainerInset = UIEdgeInsets(top: 0, left: sideMargin, bottom: 0, right: sideMargin)
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.size = CGSize(width: max(tv.bounds.width, 1),
                                       height: CGFloat.greatestFiniteMagnitude)
        tv.contentInset = UIEdgeInsets(top: box.padTop, left: 0, bottom: box.padBottom, right: 0)
        tv.showsVerticalScrollIndicator = false
        tv.attributedText = attributed
        tv.contentOffset = CGPoint(x: 0, y: -box.padTop)

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
        // タップとスワイプが同時に成立可能(shouldRecognizeSimultaneouslyWith = true)
        // なので、指定なしだと端でのスワイプが「スワイプ送り」と「端タップ送り」の
        // 二重発火になり、1回のフリックでページが2回分進む(反応が極端すぎる原因)。
        // スワイプが成立するかどうか判定が終わるまでタップの確定を待たせる。
        taps.require(toFail: leftSwipe)
        taps.require(toFail: rightSwipe)
        context.coordinator.swipeEnabled = swipePaging
        box.view = tv
        box.turn = turn
        context.coordinator.box = box
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
        // セーフエリア(ノッチ/ホームバー)分を余白に含め、本文を画面内へ収める。
        // updateUIView の時点では safeAreaInsets が未確定(0)のことがあるため、
        // 余白は ScrollBox 側で都度取り直す。ここでは「余白が変わる前後で
        // 同じ本文位置を表示し続ける」よう、先頭位置を基準にオフセットを張り直す。
        let anchorTop = tv.contentOffset.y + box.padTop
        box.refreshPads()
        tv.contentInset = UIEdgeInsets(top: box.padTop, left: 0, bottom: box.padBottom, right: 0)
        tv.contentOffset = CGPoint(x: 0, y: anchorTop - box.padTop)
        tv.textContainerInset = UIEdgeInsets(top: 0, left: sideMargin, bottom: 0, right: sideMargin)
        tv.textContainer.widthTracksTextView = true
        tv.textContainer.heightTracksTextView = false
        tv.textContainer.size = CGSize(width: max(tv.bounds.width, 1),
                                       height: CGFloat.greatestFiniteMagnitude)
        box.view = tv
        box.turn = turn
        context.coordinator.box = box
        // 入れ替わり検知(本文 or スタイル変更)のときだけ載せ替える。
        if !context.coordinator.applied.isEqual(to: attributed) {
            context.coordinator.applied = attributed
            box.invalidateLines()
            tv.attributedText = attributed
            tv.contentOffset = CGPoint(x: 0, y: -box.padTop)
        }
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
            // 端(外側2割)だけが送り。中央はメニュー出没に充てる(反応しすぎの是正)。
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
