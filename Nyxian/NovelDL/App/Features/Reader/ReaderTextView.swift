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

    @discardableResult
    func pageUp() -> Bool {
        guard let v = view else { return false }
        if v.contentOffset.y <= 4 { return false }
        let h = max(v.bounds.height, 200)
        let page = (v.contentOffset.y / h).rounded(.down) * h
        let target = max(0, page - h)
        animate(v, forward: false) {
            v.contentOffset = CGPoint(x: 0, y: target)
        }
        return true
    }

    @discardableResult
    func pageDown() -> Bool {
        guard let v = view else { return false }
        let h = max(v.bounds.height, 200)
        let maxY = max(0, v.contentSize.height - v.bounds.height + v.contentInset.bottom)
        if v.contentOffset.y >= maxY - 6 { return false }
        let page = (v.contentOffset.y / h).rounded(.down) * h
        let target = min(page + h, maxY)
        animate(v, forward: true) {
            v.contentOffset = CGPoint(x: 0, y: target)
        }
        return true
    }

    var atFirstPage: Bool {
        guard let v = view else { return true }
        return v.contentOffset.y <= 4
    }

    var atLastPage: Bool {
        guard let v = view else { return true }
        let maxY = max(0, v.contentSize.height - v.bounds.height + v.contentInset.bottom)
        return v.contentOffset.y >= maxY - 6
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
        tv.textContainerInset = UIEdgeInsets(top: 26, left: sideMargin, bottom: 40, right: sideMargin)
        tv.textContainer.lineFragmentPadding = 0
        tv.showsVerticalScrollIndicator = false
        tv.attributedText = attributed
        tv.contentOffset = .zero

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
        tv.textContainerInset = UIEdgeInsets(top: 26, left: sideMargin, bottom: 40, right: sideMargin)
        box.view = tv
        box.turn = turn
        context.coordinator.box = box
        // 入れ替わり検知(本文 or スタイル変更)のときだけ載せ替える。
        if !context.coordinator.applied.isEqual(to: attributed) {
            context.coordinator.applied = attributed
            tv.attributedText = attributed
            tv.contentOffset = .zero
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
            if p.x < w * 0.28 {
                onTurn()
                if !(box?.pageUp() ?? false) { onReachStart() }
            } else if p.x > w * 0.72 {
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
