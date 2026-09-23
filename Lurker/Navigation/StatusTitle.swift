// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// What a screen's title reads: its name, and a subtitle saying how it's doing in words.
///
/// This replaces the floating title pill. The pill was a view added to `UINavigationBar` by
/// hand and positioned by our own constraints, so it only landed in the right place while the
/// bar was the strip across the top that those constraints assumed. The iPhone Duo turns the
/// bar into a sidebar and the pill stayed behind, floating over the conversation. A title and
/// subtitle are the bar's own, and go wherever the bar puts titles.
struct StatusTitle: Equatable {
    var title: String
    var status: StatusLight
    /// What the status is about when the title doesn't already say — a channel's network. Nil
    /// when the title *is* the thing (a server buffer, Lurker itself).
    var detail: String?
    /// A DM's other person, whose presence the subtitle reports in place of the network's.
    var peer: FriendPresence? = nil

    /// "Connected", "Libera · Online", "Libera · Away" — see `StatusLight.subtitle`.
    var subtitle: String { status.subtitle(detail: detail, peer: peer) }
}

extension UINavigationItem {

    /// Show `status` in this item's title and subtitle.
    ///
    /// Callers run this on every state change — once per arriving message on a busy channel —
    /// so it only touches the item when something it shows has moved: setting a title relayouts
    /// the bar, and a relayout that changes nothing is still a relayout.
    func apply(_ status: StatusTitle) {
        if title != status.title { title = status.title }
        let subtitle = status.subtitle
        if self.subtitle != subtitle { self.subtitle = subtitle }
    }
}
