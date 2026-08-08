// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// One nick marked as a relay/bridge bot on a network (#277).
public struct RelayBot: Equatable, Sendable {
    /// The nick in its stored casing. Lookups fold case, so this is only what to *show* — in
    /// `/relay list`, and in the "via" line on a re-attributed message's action sheet.
    public let nick: String
    /// The custom envelope template, or `""` for "use the built-in formats"
    /// (`RelayEnvelope.defaultPatterns`), which is what the server stores for a bare mark.
    public let pattern: String

    public init(nick: String, pattern: String = "") {
        self.nick = nick
        self.pattern = pattern
    }
}

/// The account's relay-bot marks, per network (#277).
///
/// Marking a nick says "this is a bridge: the lines it posts are other people speaking". The
/// client then parses each of its messages and shows the embedded speaker as the author — see
/// `reattributing(_:networkId:)`, which is the whole of what a mark *does*.
///
/// Network-scoped, because the same nick on two networks may be unrelated bots — the same keying
/// the server uses, and the same one nick notes and ignores use.
///
/// Server-authoritative, exactly like `IgnoreSet`: `/relay` here (and the web's `/relay`, and its
/// user-profile toggle) *ask*, and the mark exists once the server fans a `relay-bot-updated`
/// back to every device. **Nothing writes to this type but a frame** — it is replaced whole by
/// `snapshot`/`relay-bot-updated`, never mutated in place by the command that caused the change,
/// so a mark the server refuses simply never appears.
///
/// **Because it is only ever replaced, `===` is a valid test for "the marks changed."** That's
/// what lets `ChatViewController`'s `removeDuplicates` predicate compare it with a pointer test
/// rather than walking every mark on every frame the socket delivers.
public final class RelayBotSet: Sendable {
    /// networkId → folded nick → mark. Presence of a key IS the mark; the value carries only what
    /// the mark is *for* (display casing and the template).
    private let byNetwork: [Int: [String: RelayBot]]

    public init(byNetwork: [Int: [RelayBot]] = [:]) {
        self.byNetwork = byNetwork.reduce(into: [:]) { out, entry in
            let bots = entry.value.filter { !$0.nick.isEmpty }
            guard !bots.isEmpty else { return }
            out[entry.key] = bots.reduce(into: [:]) { map, bot in map[bot.nick.lowercased()] = bot }
        }
    }

    /// No marks at all — a fresh session, a signed-out one, and every buffer on a client whose
    /// user has never marked anything, which is nearly all of them.
    public static let empty = RelayBotSet()

    /// Whether `nick` is marked on `networkId`. A nil network is the app-scoped system buffer,
    /// where there are no relays to speak of.
    public func isRelay(networkId: Int?, nick: String?) -> Bool {
        bot(networkId: networkId, nick: nick) != nil
    }

    /// The mark for `nick` on `networkId`, or nil when there isn't one.
    public func bot(networkId: Int?, nick: String?) -> RelayBot? {
        guard let networkId, let nick, !nick.isEmpty else { return nil }
        return byNetwork[networkId]?[nick.lowercased()]
    }

    /// The marks on `networkId`, for `/relay list`. Sorted by folded nick so the numbering a user
    /// reads off one listing is the numbering they get from the next — a dictionary's order is
    /// not, and the list is an inventory people re-read.
    public func listing(for networkId: Int?) -> [RelayBot] {
        guard let networkId, let bots = byNetwork[networkId] else { return [] }
        return bots.values.sorted { $0.nick.lowercased() < $1.nick.lowercased() }
    }

    /// This set with one mark set or cleared — how a `relay-bot-updated` frame folds in.
    ///
    /// The frame carries one nick, not a network's whole list, so this patches rather than
    /// replaces a bucket (which is where it differs from `IgnoreSet.replacing`, whose frame ships
    /// a scope at a time). `nick` is the server's canonical casing on a mark; on a clear it's
    /// whatever was asked for, and casing is moot once the key is gone.
    public func applying(networkId: Int, nick: String, marked: Bool, pattern: String) -> RelayBotSet {
        guard !nick.isEmpty else { return self }
        var bots = byNetwork[networkId].map { Array($0.values) } ?? []
        bots.removeAll { $0.nick.lowercased() == nick.lowercased() }
        if marked { bots.append(RelayBot(nick: nick, pattern: pattern)) }
        var next = byNetwork.mapValues { Array($0.values) }
        next[networkId] = bots
        return RelayBotSet(byNetwork: next)
    }

    /// `messages` with every line from a marked bot re-attributed to the speaker its envelope
    /// names. Lines from unmarked nicks, and lines from a marked bot whose envelope doesn't parse,
    /// come back untouched.
    ///
    /// **Display-only, and applied at render time rather than on the way into the store.** The
    /// stored row keeps the bot's nick and its full text, so unmarking restores the raw view with
    /// no refetch — the same property that makes ignore rules retroactive in both directions, and
    /// the reason this is a transform over the list the screen is about to draw rather than a
    /// rewrite of what arrived.
    ///
    /// Restricted to plain messages: relays bridge speech as PRIVMSG, and re-attributing an action
    /// or a notice would tangle with the special body rendering those get. Self lines are excluded
    /// because you are not a bridge — and if you were, the envelope would be one you typed.
    ///
    /// Highlights and ignores have already run against the raw line by the time this does, which
    /// is correct in both directions: the bot's full text is a superset of the embedded text, so a
    /// ping inside a relayed message still fires, and an ignore on the bot still hides all of it.
    public func reattributing(_ messages: [Message], networkId: Int?) -> [Message] {
        guard let networkId, let bots = byNetwork[networkId], !bots.isEmpty else { return messages }
        // Compiled once per call and shared by every row, which is the point of doing this over a
        // list instead of per message: a busy relay channel is dozens of rows off one template.
        var compiled: [String: [RelayTemplate]] = [:]
        return messages.map { message in
            guard message.type == .message, !message.isSelf,
                  let nick = message.nick,
                  let bot = bots[nick.lowercased()]
            else { return message }
            let templates: [RelayTemplate]
            if let cached = compiled[bot.pattern] {
                templates = cached
            } else {
                templates = RelayEnvelope.templates(for: bot.pattern)
                compiled[bot.pattern] = templates
            }
            guard let parsed = RelayEnvelope.parse(message.text, templates: templates) else { return message }
            return message.relayed(
                to: parsed.nick, text: parsed.text, via: bot.nick, source: parsed.source
            )
        }
    }
}
