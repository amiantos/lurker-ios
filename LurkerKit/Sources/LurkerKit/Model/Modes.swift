// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The "is this mode row churn?" question the event filters ask, and the decision that
/// follows from it — a port of the web's `shared/modes.ts`, which the two clients must
/// answer identically or they fold and filter different rows out of the same page.
///
/// See `ModeChangeKind` for why the classification is the server's job rather than ours.
public enum Modes {

    /// Whether a MODE row is presence churn.
    ///
    /// True only when the message carries at least one change and EVERY change in it grants
    /// or revokes member status. One ban, key or channel flag anywhere in the message and
    /// the whole row is not churn.
    ///
    /// That whole-message gate matches weechat (`irc-mode.c`, where its smart filter is
    /// cleared the moment an ineligible letter appears). A row renders as one line and can't
    /// be half-hidden, so `+o-b alice *!*@host` has to be all-or-nothing — and showing it is
    /// the direction that can't silently swallow a ban.
    public static func isChurn(_ modes: [ModeChange]) -> Bool {
        guard !modes.isEmpty else { return false }
        // `kind == .prefix` already implies a param on anything the server stamped; the
        // explicit test also covers a hand-built row.
        return modes.allSatisfy { $0.kind == .prefix && !($0.param ?? "").isEmpty }
    }

    /// The nicks a MODE message acted ON — the params of its member-status changes.
    ///
    /// These, not the message's author, are what the smart filter judges. The author of a
    /// mode line is nearly always ChanServ or an op bot that never speaks in the channel, so
    /// keying on it would hide essentially every mode change. weechat judges the target too;
    /// halloy judges the author, and that looks like a bug rather than a choice.
    public static func targets(_ modes: [ModeChange]) -> [String] {
        modes.compactMap { change in
            guard change.kind == .prefix, let param = change.param, !param.isEmpty else { return nil }
            return param
        }
    }

    /// Whether the smart rung hides this MODE row.
    ///
    /// Shown — never hidden — when the message isn't pure churn, when we sent it, when it
    /// acted on us, or when any nick it acted on has spoken recently.
    ///
    /// `spokeRecently` is a callback because "recently" is a window ending at the event's own
    /// timestamp, which the caller already owns; the rest of the decision is identical
    /// everywhere and lives here.
    ///
    /// ⚠ Known trade-off, inherited from weechat's default: in a moderated (+m) channel
    /// `+v alice` is the permission for alice to START speaking, so the target can never
    /// have "spoken recently" and the grant is always hidden — in exactly the channels where
    /// voice grants carry the most meaning. Left as-is deliberately rather than diverging
    /// from the reference on a guess; the candidate remedy is to extend the join-unmask idea
    /// to mode grants.
    public static func smartHides(
        _ modes: [ModeChange],
        actorNick: String?,
        ownNick: String?,
        spokeRecently: (String) -> Bool
    ) -> Bool {
        guard isChurn(modes) else { return false }
        let ownLc = ownNick?.lowercased()
        if let ownLc, let actor = actorNick?.lowercased(), actor == ownLc { return false }
        let targets = self.targets(modes)
        if let ownLc, targets.contains(where: { $0.lowercased() == ownLc }) { return false }
        // Any one recent speaker shows the whole row, matching the whole-message gate rather
        // than hiding a `+ooo a b c` because two of the three were strangers.
        return !targets.contains(where: spokeRecently)
    }
}
