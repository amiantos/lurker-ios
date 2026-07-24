// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import UIKit

/// The way back UP: a floating glass chevron that jumps to the first unread message, shown when
/// a buffer opened with unreads sitting above the reader (#45). The twin of `JumpToLatestButton`
/// in the same bottom-trailing slot — the two never show at once: the up-chevron means "you're
/// at the latest, go back to your first unread", the down-chevron means "you're up in history,
/// return to live". One position, the arrow says which way. No badge — like the web client's own
/// jump-to-unread affordance, it just says there's unread above.
final class JumpToUnreadButton: GlassPillButton {
    init() {
        super.init(systemName: "chevron.up", accessibilityLabel: "Jump to first unread")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }
}
