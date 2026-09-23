// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// How a peer's presence looks and reads, in one place.
///
/// Lifted out of `BufferChipCell`, where it was private, when the profile screen (#12) became
/// a second reader of the same fact. Keeping the list's styling and the profile's words here
/// is what stops "online" from being one thing in a DM row and another on that person's profile.
extension FriendPresence {

    /// Whether a DM's name steps down to the secondary colour: away or offline, the two the web
    /// mutes (`BufferList.vue`'s `peer-away` and `peer-offline`). Online and unknown stay as they
    /// are — unknown is the lack of a signal, not a signal.
    var dimsName: Bool { self == .away || self == .offline }

    /// Whether a DM's name is italic: offline only, the web's "offline tell".
    var italicizesName: Bool { self == .offline }

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
