// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import UIKit

/// A pan that is a swipe toward the trailing edge, or nothing (lurker#1248).
///
/// It decides ONCE, at the touch slop: the first move that is a slop away from the touch-down is
/// either a drag toward the trailing edge, steeper than two-to-three against its vertical drift,
/// and the pan begins — or it isn't, and the pan fails there and then. There is no third state
/// where a diagonal drag is neither a scroll nor a swipe while the finger keeps moving: the
/// message list's own pan waits for this one to fail before it scrolls, so the wait has to be
/// over at the first move that could settle it.
///
/// Why a subclass rather than the delegate's `gestureRecognizerShouldBegin`: that question is
/// asked when the pan would begin, by which time a vertical drag has already made the list wait
/// one move longer than it should. Failing in `touchesMoved` frees the scroll on the same event.
/// `startPoint` is kept for the delegate, which resolves the row from where the finger LANDED,
/// not where it is by the time the pan begins.
final class SwipeToReplyRecognizer: UIPanGestureRecognizer {
    /// Which way the content moves for a reply: −1 (left) in a left-to-right layout, +1 in a
    /// right-to-left one. The owner sets it from the list's layout direction.
    var sign: CGFloat = -1

    /// Where the touch landed, in the recognizer's view — nil between gestures.
    private(set) var startPoint: CGPoint?

    /// How far the finger moves, in a straight line, before the direction is read. Under the
    /// ten points `UIPanGestureRecognizer` itself needs before it begins — strictly under, so the
    /// direction is always read before `super` can begin on a move this gate hasn't seen. (A
    /// first move of three points across and nine down is past UIKit's threshold and would have
    /// begun a pan an axis-wise check at ten never looked at.)
    static let slop: CGFloat = 8

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        maximumNumberOfTouches = 1
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if startPoint == nil, let touch = touches.first { startPoint = touch.location(in: view) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible, let start = startPoint, let touch = touches.first {
            let point = touch.location(in: view)
            let dx = point.x - start.x
            let dy = point.y - start.y
            if hypot(dx, dy) >= Self.slop, !Self.isSwipe(dx: dx, dy: dy, sign: sign) {
                state = .failed
                return
            }
        }
        super.touchesMoved(touches, with: event)
    }

    /// Whether a move of (`dx`, `dy`) is a swipe toward the trailing edge: toward it at all, and
    /// steeper than two-to-three against its vertical drift. The delegate asks the same of the
    /// translation when the pan begins, so the direction is checked twice and the angle once.
    static func isSwipe(dx: CGFloat, dy: CGFloat, sign: CGFloat) -> Bool {
        let toward = dx * sign
        return toward > 0 && toward >= abs(dy) * 1.5
    }

    override func reset() {
        super.reset()
        startPoint = nil
    }
}
