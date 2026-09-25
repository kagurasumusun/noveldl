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

/// UITextView 本体。1 スクリーン = 1 ページの縦ページング。
/// 余白は左右のマージンのみで、額縁のような箱にはしない。
final class ScrollBox {
    weak var view: UITextView?
    var turn: PageTurn = .curl

    /// 1ページ = 上余白 + 本文帯(pageBand)+ 下余白。
    /// 余白は contentInset 側で確保し、どのページでも本文が画面端・
    /// ノッチ・ホームバーに食い込まないようにする。
    var padTop: CGFloat = 66
    var padBottom: CGFloat = 52

    private var minOffset: CGFloat { -padTop }
    private var pageBand: CGFloat {
        guard let v = view else { return 200 }
        return max(v.bounds.height - padTop - padBottom, 120)
    }
    private var maxOffset: CGFloat {
        guard let v = view else { return minOffset }
        // 本文の末尾を本文帯の下端に合わせるのが最大送り位置。
        return max(minOffset, v.contentSize.height - pageBand - padTop)
    }
    private func pageIndex(_ y: CGFloat) -> CGFloat {
        ((y + padTop + 2) / pageBand).rounded(.down)
    }

    @discardableResult
    func pageUp() -> Bool {
        guard let v = view else { return false }
        let cur = pageIndex(v.contentOffset.y)
        guard cur > 0 else { return false }
        let target = max(minOffset, (cur - 1) * pageBand - padTop)
        animate(v, forward: false) {
            v.contentOffset = CGPoint(x: 0, y: target)
        }
        return true
    }

    @discardableResult
    func pageDown() -> Bool {
        guard let v = view else { return false }
        let cur = pageIndex(v.contentOffset.y)
        let target = min(maxOffset, (cur + 1) * pageBand - padTop)
        if target <= v.contentOffset.y + 4 { return false }
        animate(v, forward: true) {
            v.contentOffset = CGPoint(x: 0, y: target)
        }
        return true
    }

    var atFirstPage: Bool {
        guard let v = view else { return true }
        return v.contentOffset.y <= minOffset + 4
    }

    var atLastPage: Bool {
        guard let v = view else { return true }
        return v.contentOffset.y >= maxOffset - 4
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
        storage.beginEditing()
        storage.addAttribute(.attachment, value: att, range: range)
        storage.endEditing()
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
        let safe = tv.safeAreaInsets
        box.padTop = max(28, safe.top + 16)
        box.padBottom = max(36, safe.bottom + 18)
        tv.contentInset = UIEdgeInsets(top: box.padTop, left: 0, bottom: box.padBottom, right: 0)
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
