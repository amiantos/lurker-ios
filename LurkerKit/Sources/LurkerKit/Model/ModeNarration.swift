// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Turning a MODE row into a sentence — a port of the web's `shared/modeNarration.ts`.
///
/// The line used to render as `ChanServ set +o alice`: the wire form with a verb bolted on,
/// which asks the reader to know IRC mode syntax in order to find out that somebody got
/// opped. gamja narrates these instead and it reads enormously better; this is that idea,
/// built on the server's `kind` stamp so it can tell `+o alice` (a nick) from `+b alice` (a
/// mask that happens to look like one).
///
/// Output is a SEGMENT LIST rather than a string so the renderer can draw the affected nick
/// as a real nick — coloured, with the nick menu on it — which the raw form never offered.
///
/// Only a SINGLE-change message is narrated, matching gamja's own gate. A services burst
/// reads better as `+o-b alice *!*@host` than as a run-on sentence.
public enum ModeNarration {

    /// A piece of a narrated mode line.
    public enum Segment: Equatable, Sendable {
        /// Narration prose. Rendered as-is.
        case text(String)
        /// A nick the mode acted on. Only ever emitted for a `prefix` change, so it is a real
        /// member and never a mask — render it as a nick.
        case nick(String)
        /// A literal argument: a ban mask, a limit, a raw mode string. Never a nick, so it
        /// must never be rendered as one.
        case arg(String)
    }

    /// What a member-prefix letter grants, for the "gave X to" phrasing. Only a phrasing
    /// table — whether a letter IS a prefix mode was settled server-side and is on `kind`.
    private static let prefixNames: [String: String] = [
        "q": "owner", "a": "admin", "o": "op", "h": "half-op", "v": "voice",
    ]

    /// Narrate a MODE row: the segments that follow the actor's nick. Every list starts with
    /// a leading space, so a caller renders the actor and then these with no separator.
    public static func describe(_ modes: [ModeChange], rawText: String? = nil) -> [Segment] {
        let list = modes.filter { !$0.mode.isEmpty }

        if list.isEmpty {
            // Backlog old enough to predate `modes` being persisted at all; its raw text is
            // the only description it has.
            let text = withoutKeyParam((rawText ?? "").trimmingCharacters(in: .whitespaces))
            if text.isEmpty { return [.text(" changed the channel modes")] }
            return [.text(" set "), .arg(text)]
        }

        if list.count > 1 { return rawSegments(list) }

        let only = list[0]
        // An unstamped row can't be narrated: without `kind` there is no way to know whether
        // `+q alice` grants ownership or quiets a mask, and guessing is exactly the bug the
        // stamp exists to prevent.
        switch only.kind {
        case .prefix:
            guard let param = only.param, !param.isEmpty else { return rawSegments(list) }
            return prefixSegments(only.isGrant, only.letter, param)
        case .list:
            guard let param = only.param, !param.isEmpty else { return rawSegments(list) }
            return listSegments(only.isGrant, only.letter, param)
        case .chan:
            return chanSegments(only.isGrant, only.letter, only.param)
        case nil:
            return rawSegments(list)
        }
    }

    private static func prefixSegments(_ grant: Bool, _ letter: String, _ param: String) -> [Segment] {
        let name = prefixNames[letter] ?? "+\(letter)"
        return [.text(grant ? " gave \(name) to " : " took \(name) from "), .nick(param)]
    }

    private static func listSegments(_ grant: Bool, _ letter: String, _ param: String) -> [Segment] {
        let known: [String: (String, String)] = [
            "b": (" banned ", " unbanned "),
            "q": (" quieted ", " unquieted "),
            "e": (" added a ban exemption for ", " removed the ban exemption for "),
            "I": (" added an invite exception for ", " removed the invite exception for "),
        ]
        if let phrase = known[letter] {
            return [.text(grant ? phrase.0 : phrase.1), .arg(param)]
        }
        // An unknown list mode still reads correctly said plainly, and says which list it
        // was — better than inventing a verb for a letter we don't know.
        return [
            .text(grant ? " added " : " removed "),
            .arg(param),
            .text(grant ? " to the +\(letter) list" : " from the +\(letter) list"),
        ]
    }

    private static func chanSegments(_ grant: Bool, _ letter: String, _ param: String?) -> [Segment] {
        // ⚠ The channel key is never printed. Every member of the channel saw the MODE that
        // set it, so it is no secret from them — but it lands in scrollback, and Lurker
        // already keeps it out of the channel-mode display for that reason (lurker#476).
        switch letter {
        case "k":
            return [.text(grant ? " set a channel key" : " removed the channel key")]
        case "l":
            guard grant else { return [.text(" removed the user limit")] }
            guard let param, !param.isEmpty else { return [.text(" set a user limit")] }
            return [.text(" set the user limit to "), .arg(param)]
        case "t":
            return [.text(grant ? " locked the topic" : " unlocked the topic")]
        case "n":
            // ⚠ +n BLOCKS messages from outside the channel; it does not allow them. gamja
            // has this pair inverted — narrate the mode, not the reference.
            return [.text(grant ? " blocked outside messages" : " allowed outside messages")]
        case "i":
            return [.text(grant ? " made the channel invite-only" : " removed invite-only")]
        case "m":
            return [.text(grant ? " made the channel moderated" : " removed moderation")]
        case "s":
            return [.text(grant ? " made the channel secret" : " removed secret")]
        case "p":
            return [.text(grant ? " made the channel private" : " removed private")]
        default:
            // Unknown letter. With a value it reads as an assignment; without one, as a flag.
            if grant, let param, !param.isEmpty {
                return [.text(" set +\(letter) to "), .arg(param)]
            }
            return [.text(grant ? " set +\(letter)" : " unset +\(letter)")]
        }
    }

    /// A compact mode string for a message carrying more than one change, and for anything
    /// else this can't narrate.
    ///
    /// Rebuilt from the parsed list rather than reusing the row's raw `text`, because `text`
    /// is the wire form INCLUDING a `+k` key. Reconstructing is what lets the key be dropped
    /// here the way it already is everywhere else.
    private static func rawSegments(_ modes: [ModeChange]) -> [Segment] {
        let parts = modes.map { change -> String in
            // The one param that is withheld; the letter still shows, so the reader knows a
            // key was set.
            if change.letter == "k" { return change.mode }
            guard let param = change.param, !param.isEmpty else { return change.mode }
            return "\(change.mode) \(param)"
        }
        return [.text(" set "), .arg(parts.joined(separator: " "))]
    }

    /// A mode message's wire text with its parameters dropped when a `k` is among the
    /// letters.
    ///
    /// `text` is `raw_modes` followed by every parameter, so it carries the channel key — and
    /// this is the one path that would show it. Which parameter is the key can't be worked
    /// out here: mapping parameters to letters needs CHANMODES, and a row with no parsed list
    /// has no classification either. So when a key may be present, keep the letters and drop
    /// every parameter.
    private static func withoutKeyParam(_ text: String) -> String {
        guard let modeToken = text.split(separator: " ", omittingEmptySubsequences: true).first
        else { return text }
        return modeToken.contains("k") ? String(modeToken) : text
    }
}
