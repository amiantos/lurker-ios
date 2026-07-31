// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The account's ignore rules, compiled and ready to ask (lurker #301, #350).
///
/// Two buckets, exactly as the server keeps them: `global` rules apply on every network — the
/// default scope a bare `/ignore` creates — and `byNetwork` rules are scoped to one. A
/// network's effective set is the union of the two, and every query below takes it.
///
/// Server-authoritative. Rules are created and removed on the web (`/ignore`, the settings
/// pane); the server fans the resulting list to every device, so a rule made in a browser
/// takes effect on the phone without either side coordinating. **This client only reads.**
///
/// Immutable, and replaced rather than mutated: a `snapshot` or `ignore-list-updated` frame
/// builds a whole new one. That's what makes compiling eager rather than cached — the globs
/// and patterns are compiled once per list change, and the render path, which runs per row,
/// only ever reads. A list that changes maybe twice a session against a set that's walked for
/// every visible line is the right way round for that trade.
public final class IgnoreSet: Sendable {
    public let global: [IgnoreRule]
    public let byNetwork: [Int: [IgnoreRule]]

    /// The effective compiled set per network — global ∪ that network's own — precomputed for
    /// every network the store knows about. A network with no rules of its own isn't in here
    /// and falls back to `compiledGlobal`, which is the same answer without the copy.
    private let mergedByNetwork: [Int: IgnoreMatch.CompiledSet]
    private let compiledGlobal: IgnoreMatch.CompiledSet

    public init(global: [IgnoreRule] = [], byNetwork: [Int: [IgnoreRule]] = [:]) {
        self.global = global
        self.byNetwork = byNetwork
        let compiledGlobal = IgnoreMatch.compile(global)
        self.compiledGlobal = compiledGlobal
        self.mergedByNetwork = byNetwork.reduce(into: [:]) { out, entry in
            guard !entry.value.isEmpty else { return }
            out[entry.key] = .merged(compiledGlobal, IgnoreMatch.compile(entry.value))
        }
    }

    /// No rules at all — what a fresh session and a signed-out one both hold.
    public static let empty = IgnoreSet()

    /// Replace one bucket, keeping the other. `networkId` nil targets the global bucket, a
    /// number targets that network's — the same routing the `ignore-list-updated` frame uses.
    ///
    /// Note the nil convention here is the *opposite* of the one buffers use, where a nil
    /// networkId means the app-scoped system buffer. An ignore scope of "no network" is
    /// "every network"; a buffer with no network is the one place ignores don't apply at all.
    public func replacing(networkId: Int?, with rules: [IgnoreRule]) -> IgnoreSet {
        guard let networkId else { return IgnoreSet(global: rules, byNetwork: byNetwork) }
        var next = byNetwork
        next[networkId] = rules
        return IgnoreSet(global: global, byNetwork: next)
    }

    /// The rules in force on `networkId`.
    private func compiled(for networkId: Int) -> IgnoreMatch.CompiledSet {
        mergedByNetwork[networkId] ?? compiledGlobal
    }

    /// Whether anything at all could apply on this network — the cheap gate every caller on a
    /// hot path takes first, and the reason an account with no rules pays nothing for this
    /// feature beyond a dictionary lookup.
    ///
    /// A nil `networkId` is the system buffer, whose lines have no IRC sender to ignore.
    public func isEmpty(for networkId: Int?) -> Bool {
        guard let networkId else { return true }
        return compiled(for: networkId).isEmpty
    }

    /// The full verdict for one event. The message-list render path's question.
    public func evaluate(networkId: Int?, _ input: IgnoreInput, now: Date = Date()) -> IgnoreVerdict {
        guard let networkId else { return .visible }
        return IgnoreMatch.evaluate(compiled(for: networkId), input, now: now)
    }

    /// Whether this event is hidden outright.
    public func isHidden(networkId: Int?, _ input: IgnoreInput, now: Date = Date()) -> Bool {
        evaluate(networkId: networkId, input, now: now).hide
    }

    /// Whether a message row is hidden, for the surfaces that hold the message object — the
    /// highlights, bookmarks and search feeds.
    ///
    /// Unlike `isIgnored` this honors level, channel and content-pattern rules, so an
    /// `/ignore x PUBLIC` or a `-pattern` rule keeps those lines out of search results too.
    /// A line with no sender (a system line, your own echo) is never hidden.
    public func isMessageHidden(
        networkId: Int?,
        message: Message,
        target: String,
        now: Date = Date()
    ) -> Bool {
        guard let nick = message.nick, !nick.isEmpty, !message.isSelf else { return false }
        return isHidden(
            networkId: networkId,
            IgnoreInput(
                nick: nick,
                userhost: message.userhost,
                target: target,
                text: message.text ?? "",
                type: message.type,
                isDm: BufferKind.of(networkId: networkId, target: target) == .dm
            ),
            now: now
        )
    }

    /// Whether this sender is *broadly* ignored — hidden regardless of what they say or where.
    ///
    /// For the callers that have a nick and nothing else: nick completion, the typing
    /// indicator. Deliberately narrow — a level-scoped, channel-scoped, content-pattern or
    /// NOHIGHLIGHT rule does not count here, because answering "should this person be offered
    /// for completion" from a rule that only hides their joins would be inventing an opinion
    /// the rule never expressed. Those need full event context; use `evaluate`.
    public func isIgnored(
        networkId: Int?,
        nick: String,
        userhost: String?,
        now: Date = Date()
    ) -> Bool {
        isMemberHidden(networkId: networkId, nick: nick, userhost: userhost, channel: "", now: now)
    }

    /// The nicklist filter: whether a whole-identity `ALL` rule erases this member from the
    /// open channel. See `IgnoreMatch.isMemberHidden` for why nothing weaker qualifies.
    public func isMemberHidden(
        networkId: Int?,
        nick: String,
        userhost: String?,
        channel: String,
        now: Date = Date()
    ) -> Bool {
        guard let networkId else { return false }
        let compiled = compiled(for: networkId)
        guard !compiled.isEmpty else { return false }
        return IgnoreMatch.isMemberHidden(
            compiled, nick: nick, userhost: userhost, channel: channel, now: now
        )
    }

    /// Whether this buffer's plain-unread signal is muted (lurker #359) — what the buffer list
    /// reads to downgrade a badge from "everything" to "highlights only".
    public func mutesUnread(networkId: Int?, target: String, now: Date = Date()) -> Bool {
        guard let networkId else { return false }
        let compiled = compiled(for: networkId)
        guard !compiled.isEmpty else { return false }
        return IgnoreMatch.channelMutesUnread(compiled, channel: target, now: now)
    }
}
