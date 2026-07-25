// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import UIKit

/// The body of a message row: links stay tappable, but the long press belongs to the row.
///
/// **The row menu wins everywhere (#60).** A message body has to be a `UITextView` at all because
/// that is the only way a `.link` run is tappable — and `isSelectable` has to be on for the same
/// reason. Selectability brings the system text-selection loupe with it, whose long press is the
/// exact gesture the row's context menu (Reply, Copy Text) wants. Something had to give.
///
/// Three ways to split it were on the table: give the body to text selection and the margins to
/// the row menu, put both menus on the same gesture, or let the row menu take the whole row. The
/// first is the worst of the options despite sounding like the fair one — a wide bubble leaves
/// almost no margin, so Reply would be reachable on short lines and effectively missing on long
/// ones, and "which menu you get depends on whether your finger landed on a letter" is not a rule
/// anyone could learn. The row menu takes it, and carries a Copy that covers what the selection
/// menu was offering here anyway. That is also what Messages does with a bubble.
///
/// What that costs: no partial selection of a message body, and no long-press preview on a link.
/// Copy takes the whole line, which is what you almost always wanted.
///
/// So every long press over the body is refused here and falls through to the table's
/// context-menu interaction. Taps are untouched, which is what keeps links working.
final class MessageTextView: UITextView {

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Matches subclasses too, which is the point: the selection loupe and the drag-to-lift
        // interaction are both private `UILongPressGestureRecognizer` descendants.
        if gestureRecognizer is UILongPressGestureRecognizer { return false }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}
