// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// Colors that are Lurker's rather than the system's. Everything else uses UIKit semantic
/// colors — this exists only where a system color would be a lie about which signal is
/// being shown.
enum Palette {
    /// The status-light colors, matching the web client's `--good` / `--warn` / `--bad`
    /// CSS variables exactly. The same signal in both clients should be the same color;
    /// `.systemGreen` / `.systemRed` are close but not these, and the drift would show the
    /// moment you had both open.
    static let good = UIColor(hex: "#b3db82")!
    static let warn = UIColor(hex: "#f9d978")!
    static let bad = UIColor(hex: "#ed6c89")!

    static func color(for light: StatusLight) -> UIColor {
        switch light {
        case .good: good
        case .warn: warn
        case .bad: bad
        }
    }

    /// The bubble a message from someone else lands in. A fill (not a background) so it
    /// stays legible against both the system background and, later, anything behind glass.
    static let incomingBubble = UIColor.secondarySystemFill

    /// The fill behind a line a highlight rule matched (#13). A warm wash of `warn` — the
    /// same `--warn` gold the web client tints `.line.highlight` with — rather than a solid
    /// fill, so the sender's mIRC colors and in-body nick colors still read over it. The web
    /// uses 12% (18% on its alt-striped rows); this list has no striping, so it sits between
    /// at a single value that reads in both themes without fighting the text.
    static let highlightBubble = warn.withAlphaComponent(0.16)

    /// Our own bubble. A neutral gray clearly separated from the incoming fill rather than the
    /// accent tint — a colored fill fought the in-body nick colors (a palette nick on the
    /// accent was low-contrast or invisible). `.systemGray4` sits a couple steps off the
    /// incoming `.secondarySystemFill`, so it reads as the more solid gray in both themes
    /// (lighter than the near-black incoming in dark, darker than the light incoming in light)
    /// and the trailing side confirms the line is ours. `.systemFill` was too close to tell.
    static let outgoingBubble = UIColor.systemGray4

    /// Body text on the *unbanded* rows — the foreground half of the zebra.
    ///
    /// The two halves are paired rather than opposed: the banded row is the lighter one, so it
    /// keeps full-strength text, and the row without a band takes the dimmed text. Dimming the
    /// banded row instead cancels the effect out — a lighter background under darker text lands
    /// back at roughly the contrast of its neighbour, and the stripe stops reading as one.
    ///
    /// The dim itself comes from the web, where the zebra is a foreground effect by default
    /// (`alt_bg` is `var(--bg)`): `alt_fg` is `#c4c4c4` against a `#fcfcfa` foreground, "a slightly
    /// dimmed foreground. Nick colors and inline-highlighted segments still override this." 78%
    /// matches that ratio. `.secondaryLabel` was the obvious reach and is wrong — at 60% it lands
    /// nearer the web's *muted* token (`#939293`), which reads as "this line matters less".
    static let plainRowText = UIColor.label.withAlphaComponent(0.78)

    /// The matched-line wash in the compact style, which stripes with the rows.
    ///
    /// The web's exact pair: 12% on a normal row, 18% on an alt one, so the zebra survives inside
    /// a highlight instead of the wash flattening two adjacent matched lines into one block.
    /// `highlightBubble` keeps its own single value — the bubble style doesn't stripe, which is
    /// why it sits between these two.
    static let highlightRow = warn.withAlphaComponent(0.12)
    static let highlightRowAlt = warn.withAlphaComponent(0.18)
}
