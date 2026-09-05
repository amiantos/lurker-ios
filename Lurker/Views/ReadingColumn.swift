// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import UIKit

/// How wide a *full-screen* surface is allowed to get before it stops spending the extra room
/// on width (#iPad).
///
/// Only the two screens the navigation stack shows full-bleed need this — the buffer list and
/// the conversation. Everything else off them is a sheet, and a sheet is already width-limited
/// by UIKit at regular width, which is why none of them ask.
///
/// The conversation doesn't use this: it pins to UIKit's own `readableContentGuide`, because
/// its column is a measure of *text* and that guide grows with Dynamic Type the way a text
/// column should. This is the buffer list's answer to the same question, where the content is
/// rows and cards rather than prose and a compositional layout has no guide to read — near
/// enough the same width that the two screens read as one column, arrived at differently
/// because they are measuring different things.
enum ReadingColumn {

    /// The cap. In the same neighbourhood as the readable width at body size, which is what
    /// the conversation lands on.
    static let maxWidth: CGFloat = 720

    /// What to add to a section's own insets so its content sits centred within the cap.
    /// Zero on anything narrower than the cap — every iPhone, and an iPad window dragged
    /// narrow — where the layout is left exactly as it was.
    static func sideInset(forWidth width: CGFloat) -> CGFloat {
        max(0, (width - maxWidth) / 2)
    }
}
