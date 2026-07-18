// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Collapses a run of consecutive membership-churn events into a single net-effect
/// summary, IRCCloud-style — a port of the web client's `shared/consolidate.ts`, with one
/// deliberate divergence: **`mode` participates**. On the web a mode change terminates a
/// run, so a netsplit rejoin where ops get auto-opped (`join join +o join +o …`) shatters
/// into a string of tiny summaries. Here a mode rides inside the run and is surfaced as its
/// own group, so that whole burst reads as one line.
///
/// Pure and side-effect-free: no UIKit, no state. Given the buffer's rendered messages, in
/// order, it returns a row stream where each maximal run of 2+ consolidatable events is one
/// `.summary`, and everything else passes through untouched.
///
/// Algorithm (identity half, unchanged from the web):
///   1. Walk the stream; group consecutive consolidatable events into a run. Any other row
///      (a real message, a kick, a topic, an error) terminates it.
///   2. Inside a run, accumulate a per-identity action sequence: `J` join, `L` leave
///      (part *or* quit), `R` rename. A rename transfers the identity to the new nick key
///      so the chain is followed across renames.
///   3. Classify each identity by its first/last J|L action into joined / left /
///      reconnected / joinedAndLeft; identities with only `R` actions are renamed.
///   4. A run of exactly one event passes through unchanged, so a lone "alice joined" keeps
///      its familiar standalone styling.
public enum Consolidation {

    /// The event types that fold into a summary. `mode` is included here but *not* in the
    /// join/leave/rename net-effect machine — it's collected separately (see `summarize`).
    /// `kick`, `topic`, and `invite` are activity lines too, but they stay standalone and
    /// break a run: each is a discrete, notable event a reader shouldn't have to expand a
    /// summary to see.
    static let consolidatableTypes: Set<EventType> = [.join, .part, .quit, .nick, .mode]

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
            // A run that produced nothing to show (e.g. mode events the server sent without
            // a structured change list) falls back to rendering each event on its own,
            // rather than emitting a blank summary row.
            if summary.groups.isEmpty && summary.modeGroups.isEmpty {
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
            modeGroups: modeGroups(events),
            date: events.last?.date,
            firstId: events.first?.id ?? 0,
            lastId: events.last?.id ?? 0
        )
    }

    // MARK: - Identity net effect (join / part / quit / nick)

    /// Mutable per-identity bookkeeping while walking a run.
    private struct Identity {
        var displayNick: String
        var originalNick: String
        var actions: [Character] // 'J' | 'L' | 'R'
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
            case .join, .part, .quit:
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
                state.actions.append(event.type == .join ? "J" : "L")
                ids[key] = state
            default:
                break // mode is folded separately; nothing else reaches a run
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
            .joined, .left, .reconnected, .joinedAndLeft, .renamed,
        ]
        return order.compactMap { kind in
            guard let entries = buckets[kind], !entries.isEmpty else { return nil }
            let capped = cap(entries, maxNames: maxNames, recentSpeakers: speakersLc)
            return ConsolidationSummary.IdentityGroup(kind: kind, visible: capped.visible, hidden: capped.hidden)
        }
    }

    /// Net effect of an identity's actions. Only the J|L actions decide presence; a lone
    /// run of renames (no J|L) is a `renamed`.
    private static func classify(_ actions: [Character]) -> ConsolidationSummary.IdentityGroup.Kind {
        let jl = actions.filter { $0 == "J" || $0 == "L" }
        guard let first = jl.first, let last = jl.last else { return .renamed }
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

    // MARK: - Mode folding

    /// Collect the run's mode changes, grouped by setter and then by signed mode token, so
    /// `+o alice`, `+o bob`, `+v carol` from the same op read as "Chan set +o alice, bob;
    /// +v carol" rather than three separate lines. Setter and token order follow first
    /// appearance; params are de-duplicated within a token.
    private static func modeGroups(_ events: [Message]) -> [ConsolidationSummary.ModeSummary] {
        var setterOrder: [String] = [] // lowercased keys, first-seen order
        var setterDisplay: [String: String] = [:]
        var tokenOrder: [String: [String]] = [:] // setterKey → signed tokens, first-seen
        var params: [String: [String]] = [:] // "setterKey\u{1}token" → params

        for event in events where event.type == .mode {
            let setter = event.nick ?? ""
            let setterKey = setter.lowercased()
            if tokenOrder[setterKey] == nil {
                setterOrder.append(setterKey)
                setterDisplay[setterKey] = setter
                tokenOrder[setterKey] = []
            }
            for change in event.modes {
                let token = change.mode
                let paramKey = setterKey + "\u{1}" + token
                if params[paramKey] == nil {
                    tokenOrder[setterKey]?.append(token)
                    params[paramKey] = []
                }
                if let param = change.param, !param.isEmpty, !(params[paramKey]?.contains(param) ?? false) {
                    params[paramKey]?.append(param)
                }
            }
        }

        return setterOrder.compactMap { setterKey in
            let changes = (tokenOrder[setterKey] ?? []).map { token in
                ConsolidationSummary.ModeSummary.Change(mode: token, params: params[setterKey + "\u{1}" + token] ?? [])
            }
            guard !changes.isEmpty else { return nil }
            return ConsolidationSummary.ModeSummary(setter: setterDisplay[setterKey] ?? "", changes: changes)
        }
    }
}

/// The structured result of collapsing one run. The renderer turns this into text; keeping
/// it data (not a string) means the summary can be styled — nicks in their colors, the
/// connective words muted — the same way the web client colors its `NickRef`s.
public struct ConsolidationSummary: Equatable, Sendable {
    /// Net-effect membership categories, in fixed display order.
    public let groups: [IdentityGroup]
    /// Folded mode changes, grouped by setter.
    public let modeGroups: [ModeSummary]
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
        modeGroups: [ModeSummary],
        date: Date?,
        firstId: Int,
        lastId: Int
    ) {
        self.groups = groups
        self.modeGroups = modeGroups
        self.date = date
        self.firstId = firstId
        self.lastId = lastId
    }

    /// One identity within the summary: a nick that joined/left/reconnected/joined-briefly,
    /// or a nick that renamed itself.
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
            case joined, left, reconnected, joinedAndLeft, renamed
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

    /// The mode changes a single setter made within the run.
    public struct ModeSummary: Equatable, Sendable {
        /// One signed mode token and the targets it was applied to.
        public struct Change: Equatable, Sendable {
            public let mode: String // e.g. "+o"
            public let params: [String] // e.g. ["alice", "bob"]; empty for a bare flag

            public init(mode: String, params: [String]) {
                self.mode = mode
                self.params = params
            }
        }

        public let setter: String
        public let changes: [Change]

        public init(setter: String, changes: [Change]) {
            self.setter = setter
            self.changes = changes
        }
    }
}
