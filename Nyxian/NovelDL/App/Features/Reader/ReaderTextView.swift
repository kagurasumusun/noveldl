import SwiftUI
import UIKit

enum ReaderZone {
    case previous, menu, next
}

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
