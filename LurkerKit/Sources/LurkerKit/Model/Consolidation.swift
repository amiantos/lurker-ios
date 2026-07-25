// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Collapses a run of consecutive membership-churn events into a single net-effect
/// summary, IRCCloud-style — a port of the web client's `shared/consolidate.ts`, matching
/// its event set exactly.
///
/// Pure and side-effect-free: no UIKit, no state. Given the buffer's rendered messages, in
/// order, it returns a row stream where each maximal run of 2+ consolidatable events is one
/// `.summary`, and everything else passes through untouched.
///
/// Algorithm:
///   1. Walk the stream; group consecutive consolidatable events into a run. Any other row
///      (a real message, a kick, a mode, a topic, an error) terminates it.
///   2. Inside a run, accumulate a per-identity action sequence: `J` join, `L` leave
///      (part *or* quit), `R` rename, `H` rehost (chghost). A rename transfers the identity
///      to the new nick key so the chain is followed across renames.
///   3. Classify each identity by its first/last J|L action into joined / left /
///      reconnected / joinedAndLeft. An identity with no J|L falls back to rename over
///      rehost: any `R` is `renamed`, otherwise `H`-only is `rehosted`.
///   4. A run of exactly one event passes through unchanged, so a lone "alice joined" keeps
///      its familiar standalone styling.
public enum Consolidation {

    /// The event types that fold into a summary — the web's `CONSOLIDATABLE_TYPES`
    /// (`shared/consolidate.ts:121`).
    ///
    /// `mode` is deliberately *not* here, matching the web. It was included once, on the
    /// reasoning that a netsplit rejoin with auto-opping (`join join +o join +o …`) reads
    /// better as one line than as a string of tiny summaries broken up by mode lines. That
    /// bought a tidier netsplit at the cost of a second summary vocabulary — a whole parallel
    /// mode-folding pass and its own group type — and of hiding mode changes, which are
    /// consequential in a way join churn isn't: being opped or banned is worth its own line.
    /// `kick`, `topic`, and `invite` stay standalone for the same reason.
    static let consolidatableTypes: Set<EventType> = [.join, .part, .quit, .nick, .chghost]

    /// A row in the consolidated stream.
    public enum Row: Equatable, Sendable {
        /// An event that stands on its own — rendered exactly as it would be uncollapsed.
        case passthrough(Message)
        /// A run of 2+ consolidatable events, collapsed to one net-effect summary.
        case summary(ConsolidationSummary)
    }

    /// Consolidate a buffer's rendered messages.
    ///
    /// - Parameters:
    ///   - messages: the buffer's messages, already filtered to what it renders, in order.
    ///   - maxNames: how many names to show per category before "and N others" (floored 1).
    ///   - recentSpeakers: lowercased nicks to float to the front of a truncated list, so
    ///     the people you were just talking to stay visible. Empty keeps insertion order.
    public static func consolidate(
        _ messages: [Message],
        maxNames: Int = 5,
        recentSpeakers: Set<String> = []
    ) -> [Row] {
        var out: [Row] = []
        var run: [Message] = []

        func flush() {
            defer { run = [] }
            guard run.count > 1 else {
                if let only = run.first { out.append(.passthrough(only)) }
                return
            }
            let summary = summarize(run, maxNames: maxNames, recentSpeakers: recentSpeakers)
            // A run that produced nothing to show falls back to rendering each event on its
            // own, rather than emitting a blank summary row. Every consolidatable type
            // contributes an action today, so this is unreachable — it's the guard that keeps
            // it that way, since adding a type to the set above without teaching
            // `identityGroups` about it would otherwise silently swallow it into a blank row.
            if summary.groups.isEmpty {
                out.append(contentsOf: run.map(Row.passthrough))
            } else {
                out.append(.summary(summary))
            }
        }

        for message in messages {
            if consolidatableTypes.contains(message.type) {
                run.append(message)
            } else {
                flush()
                out.append(.passthrough(message))
            }
        }
        flush()
        return out
    }

    // MARK: - Building one summary

    private static func summarize(
        _ events: [Message],
        maxNames: Int,
        recentSpeakers: Set<String>
    ) -> ConsolidationSummary {
        ConsolidationSummary(
            groups: identityGroups(events, maxNames: max(1, maxNames), recentSpeakers: recentSpeakers),
            date: events.last?.date,
            firstId: events.first?.id ?? 0,
            lastId: events.last?.id ?? 0
        )
    }

    // MARK: - Identity net effect (join / part / quit / nick / chghost)

    /// Mutable per-identity bookkeeping while walking a run.
    private struct Identity {
        var displayNick: String
        var originalNick: String
        var actions: [Character] // 'J' | 'L' | 'R' | 'H'
        var seenIndex: Int
    }

    private static func identityGroups(
        _ events: [Message],
        maxNames: Int,
        recentSpeakers: Set<String>
    ) -> [ConsolidationSummary.IdentityGroup] {
        // identityKey (lowercased current nick) → bookkeeping. Renames re-key, so a separate
        // seenIndex preserves first-seen order across the migration.
        var ids: [String: Identity] = [:]
        var seenCounter = 0

        for event in events {
            switch event.type {
            case .nick:
                let oldKey = (event.nick ?? "").lowercased()
                let newKey = (event.newNick ?? "").lowercased()
                if var existing = ids[oldKey] {
                    existing.actions.append("R")
                    existing.displayNick = event.newNick ?? ""
                    ids[oldKey] = nil
                    ids[newKey] = existing
                } else {
                    ids[newKey] = Identity(
                        displayNick: event.newNick ?? "",
                        originalNick: event.nick ?? "",
                        actions: ["R"],
                        seenIndex: seenCounter
                    )
                    seenCounter += 1
                }
            case .join, .part, .quit, .chghost:
                let key = (event.nick ?? "").lowercased()
                var state: Identity
                if let existing = ids[key] {
                    state = existing
                } else {
                    state = Identity(
                        displayNick: event.nick ?? "",
                        originalNick: event.nick ?? "",
                        actions: [],
                        seenIndex: seenCounter
                    )
                    seenCounter += 1
                }
                let action: Character = switch event.type {
                case .join: "J"
                case .chghost: "H"
                default: "L" // part or quit
                }
                state.actions.append(action)
                ids[key] = state
            default:
                break // nothing else reaches a run
            }
        }

        // Bucket in a fixed display order so the readout reads the same way every time.
        var buckets: [ConsolidationSummary.IdentityGroup.Kind: [ConsolidationSummary.Entry]] = [:]
        for identity in ids.values.sorted(by: { $0.seenIndex < $1.seenIndex }) {
            let kind = classify(identity.actions)
            let entry: ConsolidationSummary.Entry = kind == .renamed
                ? .renamed(from: identity.originalNick, to: identity.displayNick)
                : .nick(identity.displayNick)
            buckets[kind, default: []].append(entry)
        }

        let speakersLc = Set(recentSpeakers.map { $0.lowercased() })
        let order: [ConsolidationSummary.IdentityGroup.Kind] = [
            .joined, .left, .reconnected, .joinedAndLeft, .renamed, .rehosted,
        ]
        return order.compactMap { kind in
            guard let entries = buckets[kind], !entries.isEmpty else { return nil }
            let capped = cap(entries, maxNames: maxNames, recentSpeakers: speakersLc)
            return ConsolidationSummary.IdentityGroup(kind: kind, visible: capped.visible, hidden: capped.hidden)
        }
    }

    /// Net effect of an identity's actions. Only the J|L actions decide presence.
    ///
    /// With no presence change, a rename outranks a rehost — "alice → bob" says more than
    /// "alice changed host" for an identity that did both.
    ///
    /// `H` being transparent to the J|L scan is deliberate (web #593): after a netsplit each
    /// rejoining user emits JOIN then CHGHOST as they identify to services, so their sequence
    /// is `[J, H]`. That has to read as a plain "joined" rather than splitting the summary
    /// into "N joined" plus the same N "changed host". A host change earns its own category
    /// only when nothing else happened.
    private static func classify(_ actions: [Character]) -> ConsolidationSummary.IdentityGroup.Kind {
        let jl = actions.filter { $0 == "J" || $0 == "L" }
        guard let first = jl.first, let last = jl.last else {
            return actions.contains("R") ? .renamed : .rehosted
        }
        let wasPresent = first == "L" // a leave first means they were here to begin with
        let isPresent = last == "J" // a join last means they're here now
        switch (wasPresent, isPresent) {
        case (false, true): return .joined
        case (true, false): return .left
        case (false, false): return .joinedAndLeft
        case (true, true): return .reconnected
        }
    }

    /// Cap a category's names, floating recent speakers to the front of a truncated list.
    /// Stable: within the same recency tier, insertion order holds.
    private static func cap(
        _ entries: [ConsolidationSummary.Entry],
        maxNames: Int,
        recentSpeakers: Set<String>
    ) -> (visible: [ConsolidationSummary.Entry], hidden: Int) {
        guard entries.count > maxNames else { return (entries, 0) }
        let ranked = entries.enumerated().sorted { lhs, rhs in
            let lRecent = recentSpeakers.contains(lhs.element.rankKey) ? 0 : 1
            let rRecent = recentSpeakers.contains(rhs.element.rankKey) ? 0 : 1
            if lRecent != rRecent { return lRecent < rRecent }
            return lhs.offset < rhs.offset
        }.map(\.element)
        return (Array(ranked.prefix(maxNames)), ranked.count - maxNames)
    }

}

/// The structured result of collapsing one run. The renderer turns this into text; keeping
/// it data (not a string) means the summary can be styled — nicks in their colors, the
/// connective words muted — the same way the web client colors its `NickRef`s.
public struct ConsolidationSummary: Equatable, Sendable {
    /// Net-effect membership categories, in fixed display order.
    public let groups: [IdentityGroup]
    /// The last event's timestamp — what the summary reveals on a drag, matching a line.
    public let date: Date?
    /// The persisted-id span of the events this summary replaces. Lets the view find the
    /// summary that now stands in for a given line after a history page reshapes the run —
    /// which is what keeps scroll position pinned across a "load older" (see
    /// `ChatViewController`). A run grows only at its top as older history prepends, so
    /// `lastId` is a stable anchor.
    public let firstId: Int
    public let lastId: Int

    public init(
        groups: [IdentityGroup],
        date: Date?,
        firstId: Int,
        lastId: Int
    ) {
        self.groups = groups
        self.date = date
        self.firstId = firstId
        self.lastId = lastId
    }

    /// One identity within the summary: a nick that joined/left/reconnected/joined-briefly/
    /// changed host, or a nick that renamed itself.
    public enum Entry: Equatable, Sendable {
        case nick(String)
        case renamed(from: String, to: String)

        /// The key a truncated list ranks by (the current display nick), lowercased.
        var rankKey: String {
            switch self {
            case .nick(let nick): nick.lowercased()
            case .renamed(_, let to): to.lowercased()
            }
        }
    }

    /// One net-effect category and its (possibly truncated) member list.
    public struct IdentityGroup: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case joined, left, reconnected, joinedAndLeft, renamed, rehosted
        }

        public let kind: Kind
        public let visible: [Entry]
        public let hidden: Int

        public init(kind: Kind, visible: [Entry], hidden: Int) {
            self.kind = kind
            self.visible = visible
            self.hidden = hidden
        }
    }
}
