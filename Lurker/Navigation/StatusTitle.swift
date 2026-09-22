// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// What a screen's title reads: its name, and a subtitle carrying the status light.
///
/// This replaces the floating title pill. The pill was a view added to `UINavigationBar` by
/// hand and positioned by our own constraints, so it only landed in the right place while the
/// bar was the strip across the top that those constraints assumed. The iPhone Duo turns the
/// bar into a sidebar and the pill stayed behind, floating over the conversation. A title and
/// subtitle are the bar's own, and go wherever the bar puts titles.
struct StatusTitle: Equatable {
    var title: String
    var status: StatusLight
    /// What the light is about when the title doesn't already say — a channel's network. Nil
    /// when the title *is* the thing (a server buffer, Lurker itself), and the subtitle then
    /// says how it's doing in words instead.
    var detail: String?

    /// "● Libera", "● Libera · Connecting…", "● Connected".
    ///
    /// Words appear whenever the light isn't green, so the state never rests on colour alone.
    /// Green says nothing extra next to a detail — "connected" on every channel you open is
    /// noise — but a subtitle needs *something* to say, so with no detail it names the state.
    var subtitle: AttributedString {
        let words: String? = switch status {
        case .good: detail == nil ? "Connected" : nil
        case .warn: "Connecting…"
        case .bad: "Not connected"
        }
        var light = AttributedString("● ")
        light.uiKit.foregroundColor = Palette.color(for: status)
        return light + AttributedString([detail, words].compactMap { $0 }.joined(separator: " · "))
    }
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
        if attributedSubtitle != subtitle { attributedSubtitle = subtitle }
        // Set rather than left to fall back: the fallback is documented from `largeSubtitle`
        // to the plain `subtitle`, which would drop the light's colour under a large title.
        if largeAttributedSubtitle != subtitle { largeAttributedSubtitle = subtitle }
    }
}
