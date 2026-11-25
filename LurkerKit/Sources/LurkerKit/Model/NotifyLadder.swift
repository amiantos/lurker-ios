// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// One rung of the notification ladder (lurker#359, Mobile lurker#1087), loudest first.
///
/// The cases are in ladder order, and each is strictly quieter than the one above it — which is
/// what lets a buffer's setting be one choice out of a list rather than a set of switches that
/// can contradict each other.
public enum NotifyRung: String, CaseIterable, Equatable, Sendable {
    /// Every message notifies. A channel's `notify_always` flag, and a DM's resting state.
    case all
    /// Only highlights notify. A channel's and a network's resting state.
    case highlights
    /// Nothing notifies, but the unread badge still counts. A `NONOTIFY` ignore rule.
    case nothing
    /// Nothing notifies and nothing counts as unread. A `NONOTIFY` + `NOUNREAD` ignore rule.
    case muted

    /// The label, word for word the web client's.
    public var label: String {
        switch self {
        case .all: "All messages"
        case .highlights: "Highlights only"
        case .nothing: "Nothing"
        case .muted: "Muted"
        }
    }
}

/// The notification "quietness" ladder: which rungs a buffer offers, which one it is on, and what
/// to send to move it. The port of the web's `useNotifyLadder`, kept pure so the buffer info
/// screen and the buffer list's menu ask the same code and a test can ask it without a socket.
///
///     Channel:  All messages · Highlights only (default) · Nothing · Muted
///     DM:       All messages (default) · Nothing · Muted
///     Network:  Highlights only (default) · Nothing · Muted
///
/// A DM has no "Highlights only" because every DM line is already the signal, and a network has
/// no "All messages" because a whole network's firehose is not something to be notified about.
///
/// Two stores sit under the one list. "All messages" on a channel is the server's per-channel
/// `notify_always` flag (`ChatState.notifiesAlways`); the two quiet rungs are ignore rules
/// (`IgnoreSet.bufferMuteRule` / `networkMuteRule`). Nothing here writes to either: a `plan` is
/// what to *ask* for, and the rung only moves when the server's echoes fold in.
public enum NotifyLadder {

    /// What a ladder is about: one channel, one DM, or a whole network.
    public enum Scope: Hashable, Sendable {
        case channel(networkId: Int, target: String)
        case dm(networkId: Int, target: String)
        case network(networkId: Int)

        /// The ladder a buffer gets, or nil for the app's own system buffer, which has none.
        ///
        /// Classified by `BufferKind.of` — all four channel sigils, never a `#` probe — so an
        /// `&local` channel gets the channel ladder and the flag the server will actually
        /// consult for it. A server log stands for its network. A `=nick` DCC chat gets the DM
        /// ladder under its own `=nick` target, which is what the web's buffer menu gives it.
        public static func of(_ key: BufferKey) -> Scope? {
            guard let networkId = key.networkId else { return nil }
            switch BufferKind.of(networkId: networkId, target: key.target) {
            case .channel: return .channel(networkId: networkId, target: key.target)
            case .dm, .dcc: return .dm(networkId: networkId, target: key.target)
            case .server: return .network(networkId: networkId)
            case .system: return nil
            }
        }

        public var networkId: Int {
            switch self {
            case .channel(let networkId, _), .dm(let networkId, _), .network(let networkId):
                networkId
            }
        }

        /// The rungs on offer, in ladder order.
        public var rungs: [NotifyRung] {
            switch self {
            case .channel: [.all, .highlights, .nothing, .muted]
            case .dm: [.all, .nothing, .muted]
            case .network: [.highlights, .nothing, .muted]
            }
        }

        /// The rung with nothing set — no flag, no rule.
        public var base: NotifyRung {
            switch self {
            case .channel, .network: .highlights
            case .dm: .all
            }
        }

        /// The `channels` a mute rule for this scope carries: exactly this one target, folded,
        /// or none at all for a network.
        var ruleChannels: [String]? {
            switch self {
            case .channel(_, let target), .dm(_, let target): [target.lowercased()]
            case .network: nil
            }
        }
    }

    /// One thing to send. The cases map one to one onto `LurkerClient`'s three verbs.
    public enum Step: Equatable, Sendable {
        /// `set-channel-notify-always`.
        case setNotifyAlways(networkId: Int, target: String, notifyAlways: Bool)
        /// `remove-ignore` by id, addressed to the bucket the rule lives in (nil = global).
        case removeRule(id: Int, scope: Int?)
        /// `add-ignore` at network scope.
        case addRule(networkId: Int, rule: IgnoreRule)
    }

    /// The levels a quiet rung's rule carries, in canonical order; nil for the two rungs that
    /// are the absence of a rule.
    static func levels(for rung: NotifyRung) -> [String]? {
        switch rung {
        case .nothing: IgnoreLevels.canonicalize(["NONOTIFY"])
        case .muted: IgnoreLevels.canonicalize(["NOUNREAD", "NONOTIFY"])
        case .all, .highlights: nil
        }
    }

    /// The rung a buffer is on, from the two things that decide it.
    ///
    /// The flag wins: a channel with `notify_always` reads "All messages" whatever rule sits
    /// beside it, as on the web. Otherwise it is keyed on `NONOTIFY`, the notify dimension —
    /// with `NOUNREAD` that's Muted, alone it's Nothing. A `NOUNREAD`-only rule (badge hidden,
    /// notifications still firing; only a hand-typed `/ignore` makes one) is neither, so it
    /// falls through to the base rung.
    ///
    /// `notifiesAlways` is read for a channel only — nothing else can carry the flag.
    public static func rung(
        for scope: Scope, notifiesAlways: Bool, muteLevels: [String]
    ) -> NotifyRung {
        if case .channel = scope, notifiesAlways { return .all }
        if muteLevels.contains("NONOTIFY") {
            return muteLevels.contains("NOUNREAD") ? .muted : .nothing
        }
        return scope.base
    }

    /// The ordered steps that put `scope` on `rung`. Empty when it is already there, and for a
    /// rung the scope doesn't offer.
    ///
    /// A reconcile rather than a toggle: the flag is set or cleared only if it differs, a stale
    /// mute rule is removed, and the wanted one is added. The stale rule is removed **from its
    /// own scope** — a hand-typed global mute comes out of the global bucket, where a removal
    /// addressed to the network would miss it and leave it standing under a menu that says
    /// otherwise — while the new one is always added at network scope.
    ///
    /// Remove comes before add so the two never coexist, and a caller that stops at the first
    /// step that fails to send leaves at most a missing rule, never a duplicate.
    ///
    /// A rule past its `expiresAt` is still a row the server holds, for up to a minute, but it
    /// mutes nothing. It is never "already there": a quiet rung replaces it with a live one.
    public static func plan(
        to rung: NotifyRung, for scope: Scope, notifiesAlways: Bool, muteRule: ScopedIgnoreRule?,
        now: Date = Date()
    ) -> [Step] {
        guard scope.rungs.contains(rung) else { return [] }
        var steps: [Step] = []
        if case .channel(let networkId, let target) = scope, (rung == .all) != notifiesAlways {
            steps.append(.setNotifyAlways(
                networkId: networkId, target: target, notifyAlways: rung == .all
            ))
        }
        let want = levels(for: rung)
        if let muteRule, let want, Set(muteRule.rule.levels) == Set(want),
           muteRule.rule.levels.count == want.count, !isLapsed(muteRule.rule, at: now) {
            return steps
        }
        if let muteRule { steps.append(.removeRule(id: muteRule.rule.id, scope: muteRule.scope)) }
        if let want {
            steps.append(.addRule(
                networkId: scope.networkId,
                rule: IgnoreRule(channels: scope.ruleChannels, levels: want)
            ))
        }
        return steps
    }
}

extension ChatState {

    /// The mute rule the ladder for `scope` reads and replaces, with the bucket it lives in.
    public func notifyMuteRule(for scope: NotifyLadder.Scope) -> ScopedIgnoreRule? {
        switch scope {
        case .channel(let networkId, let target), .dm(let networkId, let target):
            ignores.bufferMuteRule(networkId: networkId, target: target)
        case .network(let networkId):
            ignores.networkMuteRule(networkId: networkId)
        }
    }

    private func notifiesAlways(for scope: NotifyLadder.Scope) -> Bool {
        guard case .channel(let networkId, let target) = scope else { return false }
        return notifiesAlways(networkId: networkId, target: target)
    }

    /// The rung `scope` is on right now. A lapsed mute rule mutes nothing, so it reads as none.
    public func notifyRung(for scope: NotifyLadder.Scope, now: Date = Date()) -> NotifyRung {
        let rule = notifyMuteRule(for: scope)?.rule
        let live = rule.map { !NotifyLadder.isLapsed($0, at: now) } ?? false
        return NotifyLadder.rung(
            for: scope,
            notifiesAlways: notifiesAlways(for: scope),
            muteLevels: live ? rule?.levels ?? [] : []
        )
    }

    /// What to send to put `scope` on `rung`, from this state.
    public func notifyPlan(
        to rung: NotifyRung, for scope: NotifyLadder.Scope, now: Date = Date()
    ) -> [NotifyLadder.Step] {
        NotifyLadder.plan(
            to: rung, for: scope,
            notifiesAlways: notifiesAlways(for: scope),
            muteRule: notifyMuteRule(for: scope),
            now: now
        )
    }
}

extension NotifyLadder {
    static func isLapsed(_ rule: IgnoreRule, at now: Date) -> Bool {
        rule.expiresAt.map { $0 <= now } ?? false
    }
}
