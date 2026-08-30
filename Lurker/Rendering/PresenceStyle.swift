// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// How a peer's presence looks and reads, in one place.
///
/// Lifted out of `BufferChipCell`, where it was private, when the profile screen (#12) became
/// the second surface that draws a presence dot. Two copies of this would be two answers to
/// "what colour is online" — the exact drift `Palette` exists to prevent — and the dot in a
/// friend row and the dot on that friend's profile disagreeing is the kind of thing nobody
/// files a bug about and everybody notices.
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

    /// Capitalised, for standing alone as a line of its own on the profile.
    ///
    /// ⚠ "Unknown" rather than a guess. It is the honest answer on a network with no MONITOR
    /// and no whois reply yet, and it is also the one status a not-found lets us rule out —
    /// see `ProfileStatus`, which is what decides this is never shown for a nick we've asked
    /// about and heard back on.
    var title: String {
        switch self {
        case .online: return "Online"
        case .away: return "Away"
        case .offline: return "Offline"
        case .unknown: return "Unknown"
        }
    }
}
