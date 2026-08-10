// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// How much join/part/quit/nick/host-change/mode noise reaches the message list — a port of
/// the web's `shared/eventFilter.ts` (#666), reading the same server-side settings so the
/// phone and the browser can't disagree about the rules.
///
/// This replaced two independent switches that answered the same question between them
/// (`chat.consolidate_joins` and `chat.smart_filter`), and added the rung neither could
/// express: hide all of it. That rung is why the tier exists — a phone screen holds a
/// fraction of the lines a desktop one does, and presence churn costs proportionally more.
public enum EventMode: String, CaseIterable, Sendable {
    /// Every event renders, folded into summary lines when `chat.consolidate_joins` is on.
    case all
    /// Events render only for nicks who have recently spoken — see `SmartFilter`.
    case smart
    /// No event rows at all. Conversation only.
    case none
}

/// The tier, the row types it hides, and the page unit that matches.
public enum EventFilter {

    /// The settings key the phone reads.
    ///
    /// Unconditionally the mobile one: the tier is split by device class (the web switches on
    /// viewport width) and a phone is never the desktop case. Only the *tier* is split —
    /// the modifiers below it are shared, because at `.none` they're moot anyway and nobody
    /// wants a different consolidation cap on their phone than at their desk.
    public static let modeKey = "chat.events.mobile"

    /// The tier in force, defaulting to the registry's own default so behavior doesn't shift
    /// under the reader when settings bootstrap lands a moment after launch.
    public static func mode(_ settings: Settings) -> EventMode {
        EventMode(rawValue: settings.string(modeKey, default: EventMode.all.rawValue)) ?? .all
    }

    /// The row types `.none` hides: everything consolidation folds, plus `mode`.
    ///
    /// `mode` is excluded from `Consolidation.consolidatableTypes` on purpose — being opped
    /// or banned is worth its own line, and it has no per-nick net effect to summarize. But a
    /// reader who asked for *no* event noise means op/voice/ban churn too, so the strictest
    /// rung takes it as well.
    ///
    /// Deliberately absent, because they are things that happened rather than churn: `kick`
    /// (someone was removed, and by whom), `topic`, `invite`, `error`. Hiding those would make
    /// the buffer lie about what happened rather than merely be quieter.
    public static let noiseTypes: Set<EventType> = Consolidation.consolidatableTypes.union([.mode])

    /// Whether a message is event noise, i.e. hidden entirely at `.none`.
    public static func isNoise(_ type: EventType) -> Bool { noiseTypes.contains(type) }

    /// Which of `messages` the current tier lets through.
    ///
    /// The one place the tier is applied. Both readers go through it — the row builder, and the
    /// jump-to-latest pill's "N new below" count, which has to promise the number of lines the
    /// reader will actually see arrive. Splitting them is how the pill came to advertise "40
    /// new" for a netsplit rejoin that built to nothing.
    ///
    /// - Parameters:
    ///   - speakers: who has spoken in this buffer and when, for the `.smart` rung. An empty
    ///     map means nobody qualifies as recent, so `.smart` hides every filterable event — the
    ///     web behaves the same way with an unseeded buffer.
    ///   - ownNick: your nick on this buffer's network. Your own churn is never hidden, and
    ///     `isSelf` doesn't cover it: the server stamps that on messages you *sent*, not on the
    ///     JOIN it saw you make.
    public static func visible(
        _ messages: [Message],
        settings: Settings,
        speakers: SpeakerMap = SpeakerMap(),
        ownNick: String? = nil
    ) -> [Message] {
        switch mode(settings) {
        case .all:
            return messages
        case .none:
            // Unconditional on purpose — this hides your own joins and mode changes too.
            // Someone who asked for no event noise on their phone wants none of it, not
            // none-except-mine. Kicks, topics and invites are outside `noiseTypes` and survive.
            return messages.filter { !isNoise($0.type) }
        case .smart:
            let filter = SmartFilter(settings)
            return messages.filter { !filter.hides($0, speakers: speakers, ownNick: ownNick) }
        }
    }
}

/// The `.smart` rung: hide a join / part / quit / chghost / nick when its actor hasn't spoken
/// recently, so membership churn from silent lurkers stops threading through the conversation.
/// A port of the web's `MessageList.vue` filter (#63), reading the same five tuning keys.
///
/// Only churn is ever hidden. This never touches conversation, and never touches `mode`, `kick`,
/// `topic` or `invite` — a quiet user being opped or kicked is a thing that happened, and the
/// question this rung asks ("did anyone care about this person's presence?") doesn't apply to it.
public struct SmartFilter: Sendable {

    /// How long before an event a nick's last message still counts as "recently spoke".
    public let delay: TimeInterval
    /// How long *after* a join a nick's first message retroactively reveals it. 0 disables
    /// unmasking. This is the half that needs live speaker recording: the reveal is always about
    /// speech that happens after the buffer was fetched.
    public let unmask: TimeInterval
    public let filtersJoin: Bool
    /// Covers `part`, `quit` **and** `chghost`. The host change rides the quit toggle rather
    /// than getting a fourth setting: it's the same churn from the same silent lurkers
    /// (identifying to services after a netsplit fires one per shared channel), which is exactly
    /// what smart filtering exists to absorb. weechat ships a dedicated `smart_filter_chghost`
    /// for the same reason (lurker#591).
    public let filtersQuit: Bool
    public let filtersNick: Bool

    /// Read the five tuning keys. All server-side (#65) and shared across devices — only the
    /// tier above them is split by device class. The fallbacks match the registry's own defaults
    /// so behavior doesn't shift under the reader when bootstrap lands a moment after launch.
    ///
    /// Both windows are stored in minutes, which is what the registry's `int` controls edit.
    public init(_ settings: Settings) {
        delay = TimeInterval(settings.int("chat.smart_filter_delay", default: 5)) * 60
        unmask = TimeInterval(settings.int("chat.smart_filter_join_unmask", default: 30)) * 60
        filtersJoin = settings.bool("chat.smart_filter_join", default: true)
        filtersQuit = settings.bool("chat.smart_filter_quit", default: true)
        filtersNick = settings.bool("chat.smart_filter_nick", default: true)
    }

    /// Whether this row is churn from someone nobody was talking to.
    public func hides(_ message: Message, speakers: SpeakerMap, ownNick: String?) -> Bool {
        guard filters(message.type), !message.isSelf,
              let nick = message.nick, !nick.isEmpty,
              nick.lowercased() != ownNick?.lowercased()
        else { return false }
        // No clock, no window to judge: an undated event can't be shown to be stale, so it
        // renders. (The web reads an unparseable time as epoch, which makes every such event
        // infinitely old and therefore always hidden — the wrong way to fail for a row whose
        // only problem is a missing timestamp.)
        guard let at = message.date else { return false }
        guard let spoke = speakers[nick] else { return true }
        // Spoke shortly before: somebody was talking to them, so their leaving is news.
        if spoke <= at, at.timeIntervalSince(spoke) <= delay { return false }
        // Spoke shortly after joining: they arrived and got straight into it, so the join
        // shouldn't read as having been from a lurker. Joins only — there is nothing to reveal
        // about a part or a rename by what the nick says next.
        if message.type == .join, unmask > 0, spoke > at, spoke.timeIntervalSince(at) <= unmask {
            return false
        }
        return true
    }

    private func filters(_ type: EventType) -> Bool {
        switch type {
        case .join: filtersJoin
        case .part, .quit, .chghost: filtersQuit
        case .nick: filtersNick
        default: false
        }
    }
}
