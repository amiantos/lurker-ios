// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// How a peer's presence looks and reads, in one place.
///
/// Lifted out of `BufferChipCell`, where it was private, when the profile screen (#12) became
/// a second reader of the same fact. The two take different halves — the chip wants a colour,
/// the profile says it in words — and keeping both here is what stops "online" from being one
/// thing in a friend row and another on that friend's profile.
extension FriendPresence {

    /// The dot's fill.
    ///
    /// Present/away take the theme's own signal colours, the same two the connection banner and
    /// the title-bar status light use, so "online" is one colour across the whole app and both
    /// clients. Absent/unknown stay on the system greys: they aren't signals, they're the lack
    /// of one, and the palette has no token for that.
    var dotColor: UIColor {
        switch self {
        case .online: return Palette.good
        case .away: return Palette.warn
        case .offline: return .tertiaryLabel
        case .unknown: return .quaternaryLabel
        }
    }

    /// Lowercase, for appending to a longer accessibility summary ("alice, libera, online").
    var accessibilityLabel: String {
        switch self {
        case .online: return "online"
        case .away: return "away"
        case .offline: return "offline"
        case .unknown: return "status unknown"
        }
    }

    /// Capitalised, for a labelled row's value on the profile.
    ///
    /// ⚠ "Unknown" is here for completeness and the profile deliberately never renders it: a
    /// row saying we don't know, directly under a line saying we're finding out, is the same
    /// fact told twice. `UserProfileViewController` drops the row instead.
    var title: String {
        switch self {
        case .online: return "Online"
        case .away: return "Away"
        case .offline: return "Offline"
        case .unknown: return "Unknown"
        }
    }
}
