import SwiftUI
import UIKit

/// タップゾーン:左 = 1 画面戻る / 中央 = 読書メニュー / 右 = 1 画面送る(末尾なら次話)。
enum ReaderZone {
    case previous, menu, next
}

/// ページめくりの演出。度合いは控えめ(読みを邪魔しない)。
enum PageTurn: String {
    case curl, slide, fade, none

    var label: String {
        switch self {
        case .curl: return "紙捲り"
        case .slide: return "スライド"
        case .fade: return "フェード"
        case .none: return "なし"
        }
    }

    static let all: [PageTurn] = [.curl, .slide, .fade, .none]
}

/// UITextView への参照受け渡し(スクロール操作用)。循環参照を避けるため weak。
final class ScrollBox {
    weak var view: UITextView?
    var turn: PageTurn = .curl

    /// 1 画面分戻る。先頭なら false。
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

    /// 1 画面分送る。末尾なら false(呼び出し側で次話へ)。
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

    /// 演出は「控えめな速さ」で統一(はきはきしすぎない)。
    private func animate(_ v: UIView, forward: Bool, _ change: @escaping () -> Void) {
        Haptics.tap()
        switch turn {
        case .curl:
            UIView.transition(
                with: v,
                duration: 0.36,
                options: [forward ? .transitionCurlFromRight : .transitionCurlFromLeft, .allowAnimatedContent],
                animations: change
            )
        case .slide:
            let t = CATransition()
            t.type = .push
            t.subtype = forward ? .fromRight : .fromLeft
            t.duration = 0.30
            t.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            v.layer.add(t, forKey: nil)
            change()
        case .fade:
            let t = CATransition()
            t.type = .fade
            t.duration = 0.26
            t.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            v.layer.add(t, forKey: nil)
            change()
        case .none:
            change()
        }
    }
}

/// 本文ビュー — UITextView のネイティブスクロール(CoreText 直描画の事故を排除)。
struct ReaderTextView: UIViewRepresentable {
    let attributed: NSAttributedString
    let background: UIColor
    var sideMargin: CGFloat = 34
    var swipePaging: Bool = true
    let scroller: ScrollBox
    let onZone: (ReaderZone) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onZone: onZone)
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = false
        tv.isScrollEnabled = true
        // 連続スクロールではなく 1 スクリーン = 1 ページのめくりに。
        tv.isPagingEnabled = true
        tv.alwaysBounceVertical = true
        tv.backgroundColor = background
        tv.textContainerInset = UIEdgeInsets(top: 28, left: sideMargin, bottom: 96, right: sideMargin)
        tv.textContainer.lineFragmentPadding = 0
        tv.adjustsFontForContentSizeCategory = false
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.cancelsTouchesInView = false
        tv.addGestureRecognizer(tap)
        let nextSwipe = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swipedNext))
        nextSwipe.direction = .left
        tv.addGestureRecognizer(nextSwipe)
        let prevSwipe = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swipedPrev))
        prevSwipe.direction = .right
        tv.addGestureRecognizer(prevSwipe)
        scroller.view = tv
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.swipeEnabled = swipePaging
        tv.backgroundColor = background
        tv.textContainerInset = UIEdgeInsets(top: 28, left: sideMargin, bottom: 96, right: sideMargin)
        let current: NSAttributedString = tv.attributedText ?? NSAttributedString()
        if !current.isEqual(attributed) {
            let offset = tv.contentOffset
            tv.attributedText = attributed
            // 同一話内の書体変更では読み位置を保つ
            tv.setContentOffset(offset, animated: false)
        }
    }

    final class Coordinator: NSObject {
        let onZone: (ReaderZone) -> Void
        var swipeEnabled = true
        init(onZone: @escaping (ReaderZone) -> Void) { self.onZone = onZone }

        @objc func swipedNext() {
            guard swipeEnabled else { return }
            onZone(.next)
        }

        @objc func swipedPrev() {
            guard swipeEnabled else { return }
            onZone(.previous)
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view else { return }
            let x = gesture.location(in: view).x
            let w = view.bounds.width
            if x < w / 3 {
                onZone(.previous)
            } else if x > w * 2 / 3 {
                onZone(.next)
            } else {
                onZone(.menu)
            }
        }
    }
}
