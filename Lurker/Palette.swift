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

    /// Our own bubble. A neutral gray clearly separated from the incoming fill rather than the
    /// accent tint — a colored fill fought the in-body nick colors (a palette nick on the
    /// accent was low-contrast or invisible). `.systemGray4` sits a couple steps off the
    /// incoming `.secondarySystemFill`, so it reads as the more solid gray in both themes
    /// (lighter than the near-black incoming in dark, darker than the light incoming in light)
    /// and the trailing side confirms the line is ours. `.systemFill` was too close to tell.
    static let outgoingBubble = UIColor.systemGray4
}
