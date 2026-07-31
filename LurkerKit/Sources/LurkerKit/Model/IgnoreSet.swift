// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// One rule as a listing sees it: the rule, plus which bucket it came from.
///
/// The scope isn't on the rule — the row the server ships is identical in both buckets — so it
/// is carried alongside, and it's what makes a listed rule removable: a by-id delete has to be
/// addressed to the bucket the rule lives in. Nil is the global bucket, i.e. every network.
public struct ScopedIgnoreRule: Equatable, Sendable {
    public let rule: IgnoreRule
    public let scope: Int?

    public init(rule: IgnoreRule, scope: Int?) {
        self.rule = rule
        self.scope = scope
    }
}

/// The account's ignore rules, compiled and ready to ask (lurker #301, #350).
///
/// Two buckets, exactly as the server keeps them: `global` rules apply on every network — the
/// default scope a bare `/ignore` creates — and `byNetwork` rules are scoped to one. A
/// network's effective set is the union of the two, and every query below takes it.
///
/// Server-authoritative. `/ignore` and `/unignore` here (#86), like `/ignore` and the settings
/// pane on the web, *ask* — the server validates, stores, and fans the resulting list back to
/// every device, which is what makes a rule made in a browser take effect on the phone without
/// either side coordinating. **Nothing writes to this type but a frame:** it is replaced whole
/// by `snapshot`/`ignore-list-updated`, never mutated in place by the command that caused the
/// change, so a rule the server refuses simply never appears.
///
/// Immutable, and replaced rather than mutated: a `snapshot` or `ignore-list-updated` frame
/// builds a whole new one. That's what makes compiling eager rather than cached — the globs
/// and patterns are compiled once per list change, and the render path, which runs per row,
/// only ever reads. A list that changes maybe twice a session against a set that's walked for
/// every visible line is the right way round for that trade.
///
/// **Because it is only ever replaced, `===` is a valid test for "the rules changed."** That's
/// what lets the screens' `removeDuplicates` predicates compare it with a pointer test instead
/// of walking every rule on every frame the socket delivers. The contract lives here rather
/// than being restated at each of those predicates, because it's a property of this type.
public final class IgnoreSet: Sendable {
    private let global: [IgnoreRule]
    private let byNetwork: [Int: [IgnoreRule]]

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

    /// The rules visible from `networkId`, in listing order: the globals first, then that
    /// network's own. The one read accessor on the stored buckets — everything else here
    /// answers a *question* about the rules, and this hands them over.
    ///
    /// Order is the contract, not a detail: the number a user reads off `/ignore` is a
    /// position in this array, so `/unignore <n>` resolves both the rule's id and the bucket
    /// to send the removal to from it. Matches the web's `combinedIgnores`, so the same
    /// account numbers its rules identically on both clients.
    ///
    /// A nil `networkId` is the system buffer, where only global rules are in scope — there's
    /// no connection for a network-scoped rule to be about.
    public func listing(for networkId: Int?) -> [ScopedIgnoreRule] {
        let globals = global.map { ScopedIgnoreRule(rule: $0, scope: nil) }
        guard let networkId else { return globals }
        return globals + (byNetwork[networkId] ?? []).map {
            ScopedIgnoreRule(rule: $0, scope: networkId)
        }
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
    func isHidden(networkId: Int?, _ input: IgnoreInput, now: Date = Date()) -> Bool {
        evaluate(networkId: networkId, input, now: now).hide
    }

    /// The verdict for a stored message in `target`. **The one adapter from `Message` to
    /// `IgnoreInput`** — every surface that holds a message object comes through here, so
    /// there is a single answer to what a line's sender, body and DM-ness are, and a new field
    /// on `IgnoreInput` is added in one place.
    ///
    /// A line with no sender is never hidden, and neither is your own: a mask can legitimately
    /// cover your nick (`*!*@somehost` on a shared host), and hiding your own messages from
    /// your own screen is never what such a rule meant. That exemption is stated here, once,
    /// for all of them.
    public func verdict(
        networkId: Int?,
        message: Message,
        target: String,
        now: Date = Date()
    ) -> IgnoreVerdict {
        guard let nick = message.nick, !nick.isEmpty, !message.isSelf else { return .visible }
        return evaluate(
            networkId: networkId,
            IgnoreInput(
                nick: nick,
                userhost: message.userhost,
                target: target,
                text: message.text ?? "",
                type: message.type,
                // Derived from the target rather than taken from a caller's buffer record, so
                // two callers looking at the same line can't classify it differently.
                //
                // Deliberately NOT `BufferKind.of`, which is the client's *rendering*
                // classification and counts a `&`-prefixed target as a channel. The server's
                // `isDmTarget` (`wsHub.ts`, `ircConnection.ts:isDmTargetName`) is
                // "not `#`, not `:server:`" — so `&local` is a DM to the matcher, and using
                // the rendering answer here inverted PUBLIC and MSGS for those channels: the
                // server stamped a line not-ignored while this client hid it.
                isDm: Self.isDmTarget(target)
            ),
            now: now
        )
    }

    /// Whether a target is a DM **as the matcher means it** — the client-side twin of the
    /// server's `isDmTarget`.
    ///
    /// This is the one matcher input derived here rather than received on the wire, so it is
    /// the one place a client can disagree with the server about what a rule covers. Kept as
    /// its own named answer, next to the only thing that asks the question, rather than
    /// reusing `BufferKind.of` — the two look interchangeable and are not, and the last time
    /// they were conflated it cost the `&` channels their PUBLIC/MSGS split.
    static func isDmTarget(_ target: String) -> Bool {
        !target.isEmpty && !target.hasPrefix("#") && !target.hasPrefix(":server:")
    }

    /// Whether a message row is hidden, for the surfaces that hold the message object — the
    /// highlights, bookmarks and search feeds.
    ///
    /// Unlike `isIgnored` this honors level, channel and content-pattern rules, so an
    /// `/ignore x PUBLIC` or a `-pattern` rule keeps those lines out of search results too.
    public func isMessageHidden(
        networkId: Int?,
        message: Message,
        target: String,
        now: Date = Date()
    ) -> Bool {
        verdict(networkId: networkId, message: message, target: target, now: now).hide
    }

    /// A buffer's lines with the ignored ones dropped and the `NOHIGHLIGHT`-covered ones
    /// demoted — the message list's whole use of this type, in one call.
    ///
    /// Here rather than in the view controller so it's reachable by tests (the app target has
    /// no test bundle) and so the highest-traffic surface reads through the same adapter the
    /// low-traffic feeds do. Returns the input untouched when nothing could apply, which is
    /// the common case and costs one dictionary lookup.
    /// `keeping` is a message id that must survive the filter whatever the rules say — the
    /// message a jump was aimed at. Navigating to a specific line and being shown the space
    /// where it isn't is worse than showing a line a rule would otherwise hide, and on this
    /// client it also strands the landing (see `ChatViewController.jumpExemptId`). Its
    /// highlight is still demoted: the exemption is about the row existing, not about
    /// overriding what the rule says the row should look like.
    public func visible(
        _ messages: [Message],
        networkId: Int?,
        target: String,
        keeping: Int? = nil,
        now: Date = Date()
    ) -> [Message] {
        guard !isEmpty(for: networkId) else { return messages }
        return messages.compactMap { message in
            let verdict = verdict(
                networkId: networkId, message: message, target: target, now: now
            )
            // Ephemerals (id 0) can never be the exempt row: 0 is the *absence* of a
            // persisted id, not an address, so nothing can have jumped to one — and treating
            // it as a match would exempt every ephemeral at once.
            let isJumpTarget = message.id != 0 && message.id == keeping
            if verdict.hide, !isJumpTarget { return nil }
            return verdict.nohilight ? message.unhighlighted() : message
        }
    }

    /// Whether this sender is *broadly* ignored — hidden regardless of what they say.
    ///
    /// For the callers that have a nick and a buffer but no message: nick completion, the
    /// typing indicator. Deliberately narrow — a level-scoped, content-pattern or NOHIGHLIGHT
    /// rule does not count here, because answering "should this person be offered for
    /// completion" from a rule that only hides their joins would be inventing an opinion the
    /// rule never expressed. Those need full event context; use `evaluate`.
    ///
    /// `channel` is where the question is being asked, and passing it is what makes a
    /// channel-scoped rule work on these two surfaces. Omitting it (the web's behavior, which
    /// hardcodes `''`) means only unscoped rules ever match — so `/ignore bob -channels #foo`
    /// erased bob from #foo's message list and nicklist while "bob is typing…" kept appearing
    /// at the foot of that same buffer, and `@bo` still completed to him.
    public func isIgnored(
        networkId: Int?,
        nick: String,
        userhost: String?,
        channel: String = "",
        now: Date = Date()
    ) -> Bool {
        isMemberHidden(
            networkId: networkId, nick: nick, userhost: userhost, channel: channel, now: now
        )
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
        return IgnoreMatch.isMemberHidden(
            compiled(for: networkId), nick: nick, userhost: userhost, channel: channel, now: now
        )
    }

    /// Whether this buffer's plain-unread signal is muted (lurker #359) — what the buffer list
    /// reads to downgrade a badge from "everything" to "highlights only".
    public func mutesUnread(networkId: Int?, target: String, now: Date = Date()) -> Bool {
        guard let networkId else { return false }
        return IgnoreMatch.channelMutesUnread(compiled(for: networkId), channel: target, now: now)
    }
}
