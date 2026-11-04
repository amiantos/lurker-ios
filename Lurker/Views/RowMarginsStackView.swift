// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import UIKit

/// A stack view that lays its content out inside its own margins, for anything that lives in a
/// row of the message list.
///
/// ⚠⚠ The margins are the row's rhythm and nothing else's. By default a view pads its layout
/// margins out to the safe area it overlaps, and the list's table is flipped
/// (`ChatViewController`), which leaves UIKit judging that overlap against the wrong edge: rows
/// near the screen's bottom were handed a status bar's worth of top margin that came and went
/// as they scrolled, so the spacing breathed and bodies were pushed out of the height they were
/// measured at. The opt-out used to be set by hand next to each opt-in, and the third such
/// stack — a link card's text column, built per preview — was left in; a tester's video showed
/// the words sliding inside some cards and no others. It travels with the opt-in now, so a
/// stack that wants margins in a row can't be without it.
class RowMarginsStackView: UIStackView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isLayoutMarginsRelativeArrangement = true
        insetsLayoutMarginsFromSafeArea = false
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not using storyboards") }
}
