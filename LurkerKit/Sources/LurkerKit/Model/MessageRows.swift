// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// One rendered row of a message list.
///
/// A message is either dialogue (a bubble, carrying where it sits in its run) or narration
/// (a full-width line) — see `EventType.isBubble`. A run of consecutive membership churn
/// collapses into a single `consolidated` summary. The rest are markers: breaks in the flow
/// that name themselves.
public enum MessageRow: Equatable, Sendable {
    case bubble(Message, RunPosition)
    case line(Message)
    case consolidated(ConsolidationSummary)
    /// The read boundary — "New messages".
    case unreadDivider
    /// A day change, carrying that day's local midnight.
    ///
    /// An absolute instant, not a formatted string: the label is produced at render time, so a
    /// redraw is enough to correct it when the day rolls over or the locale changes, with no
    /// rebuild of the row stream. Invalidating that redraw is the renderer's job, not this
    /// type's — see `ChatViewController.observeDateLabelInvalidation`.
    case dateDivider(Date)
    /// "You've reached the beginning", once the buffer has no older history left. The honest
    /// counterpart to a loading placeholder: "nothing more" vs "still fetching".
    case startOfHistory
    /// The live composing line at the foot of the buffer (#61) — a keyboard glyph and the
    /// nicks, rendered by `MessageRenderer.renderTyping`. Not a message: it has no id,
    /// never anchors a scroll, and disappears without leaving a gap in the record.
    case typing([String])

    /// A stable message id to anchor the viewport by, or nil for a row that has none.
    ///
    /// A summary anchors on its *last* event, because a run only ever grows upward as older
    /// history loads — so its bottom id doesn't move. Ephemeral lines (id 0) can't be
    /// re-found after a reload, so they don't anchor, and neither do the markers: there's
    /// nothing to re-find, and anchoring to a row that can vanish on a timer would drop the
    /// reader when it does. The start-of-history marker in particular sits exactly where a
    /// prepend lands, so anchoring to it would pin the viewport to the row a prepend displaces.
    public var anchorId: Int? {
        let id: Int
        switch self {
        case .bubble(let message, _): id = message.id
        case .line(let message): id = message.id
        case .consolidated(let summary): id = summary.lastId
        case .unreadDivider, .dateDivider, .startOfHistory, .typing: return nil
        }
        return id > 0 ? id : nil
    }

    /// The single message this row renders, or nil for a row that renders something else.
    ///
    /// A consolidated summary is deliberately nil: it stands for a *run* of events, so there is no
    /// one message to act on — and the actions a message offers (#60) are all singular.
    public var message: Message? {
        switch self {
        case .bubble(let message, _), .line(let message): message
        case .consolidated, .unreadDivider, .dateDivider, .startOfHistory, .typing: nil
        }
    }

    /// Whether this row is status narration — a consolidated summary or a standalone activity
    /// line (a join, mode, topic, …), but *not* a `/me` action, which is conversation and so
    /// breaks a status block rather than joining it.
    ///
    /// Drives the block spacing that sets a cluster of status lines apart from the chat around
    /// it. A marker is a hard break, so a status block never runs through one.
    public var isStatus: Bool {
        switch self {
        case .consolidated: true
        case .line(let message): message.type.isActivity
        case .bubble, .unreadDivider, .dateDivider, .startOfHistory, .typing: false
        }
    }

    /// Whether this row stands in for message `id` — its own row, or the summary whose span
    /// covers it after a history page merged it into a consolidated run.
    public func represents(_ id: Int) -> Bool {
        switch self {
        case .bubble(let message, _): message.id == id
        case .line(let message): message.id == id
        case .consolidated(let summary): summary.firstId <= id && id <= summary.lastId
        case .unreadDivider, .dateDivider, .startOfHistory, .typing: false
        }
    }
}

/// Turns a buffer's filtered messages into the row stream a message list renders.
///
/// Lives here rather than in the view controller because it is the layout-independent half of
/// the list: the same rows feed whatever cell styles render them, so a second style inherits
/// the dividers, the consolidation and the run positions rather than rebuilding them.
public enum MessageRows {

    /// Build the row stream.
    ///
    /// **Every divider is a hard break for both passes.** Consolidation must not span one (a
    /// run half-read and half-new would hide the new arrivals inside a summary; one spanning
    /// midnight would sit under a date that's wrong for half of it), and neither may a bubble
    /// run — tightened corners across a divider would knit together the very messages it
    /// separates. So rather than special-casing each divider, the list is walked once and cut
    /// into segments at every break; consolidation runs per segment, and the run pass breaks
    /// on any non-bubble neighbour, which a divider row is. Adding a divider later (the
    /// `/clear` marker, the away/back markers) is another cut, not another special case.
    ///
    /// - Parameters:
    ///   - messages: this buffer's messages, already filtered to what it renders, in order.
    ///   - dividerAfterId: the latched read boundary, or nil if the server hasn't said yet.
    ///     The unread divider only shows when there was a real read point (`> 0`) *and*
    ///     something sits past it — a brand-new buffer with nothing previously read shows none.
    ///   - hasMoreOlder: whether the server has older history left. Pass `true` when unknown:
    ///     "no more history" has to be something the server told us, not the absence of an
    ///     answer, or an unhydrated buffer claims to have reached its beginning.
    ///   - typists: who is composing right now, for the foot of the list.
    ///   - settings: the user's settings, for the two consolidation keys.
    ///   - calendar: which calendar decides a day boundary. Injected so tests can pin a
    ///     timezone; callers should take the default.
    public static func build(
        messages: [Message],
        dividerAfterId: Int?,
        hasMoreOlder: Bool,
        typists: [String] = [],
        settings: Settings = Settings(),
        calendar: Calendar = .current
    ) -> [MessageRow] {
        let boundary = dividerAfterId ?? 0

        // All server-side (#65), so the phone agrees with whatever the user set on the web.
        // The fallbacks match the registry's own defaults, so behavior doesn't shift under the
        // user when bootstrap lands a moment after launch.
        // `.rendered` collapses the rung this client can't do (`.smart`) onto the one it
        // behaves as (`.all`), so that degrade is a stated decision rather than the accident
        // of there being no branch for it below.
        let eventMode = EventFilter.rendered(EventFilter.mode(settings))
        // At `.none` there are no event rows left to fold, so the consolidation pass is
        // skipped outright rather than run over a stream it can't match.
        let consolidateEnabled = eventMode != .none
            && settings.bool("chat.consolidate_joins", default: true)
        let maxNames = settings.int("chat.consolidate_max_names", default: 5)

        // The `.none` tier (#666): drop every event row before anything else looks at the
        // stream, so dividers anchor to the first row the reader can actually see and a
        // segment can't be built out of rows that will never render.
        //
        // Unconditional on purpose — this hides your own joins and mode changes too. Someone
        // who asked for no event noise on their phone wants none of it, not
        // none-except-mine. Kicks, topics and invites are outside `noiseTypes` and survive.
        let messages = eventMode == .none
            ? messages.filter { !EventFilter.isNoise($0.type) }
            : messages

        var rows: [MessageRow] = []
        func appendSegment(_ slice: [Message]) {
            guard consolidateEnabled else {
                // Off: every event stands on its own line, exactly as it arrived.
                rows.append(contentsOf: slice.map { $0.type.isBubble ? .bubble($0, .solo) : .line($0) })
                return
            }
            for row in Consolidation.consolidate(slice, maxNames: maxNames) {
                switch row {
                case .summary(let summary):
                    rows.append(.consolidated(summary))
                case .passthrough(let message):
                    rows.append(message.type.isBubble ? .bubble(message, .solo) : .line(message))
                }
            }
        }

        // Above everything, including the first date: the buffer's history is exhausted.
        // Suppressed on an empty buffer, where the empty-state placeholder says it better.
        if !hasMoreOlder && !messages.isEmpty { rows.append(.startOfHistory) }

        var segment: [Message] = []
        var currentDay: Date?
        var unreadDividerPlaced = false

        // A buffer can *open* with undated lines — `LurkerStore.appendLocal` synthesizes a
        // dateless system line for things like an unrecognized command, and in an otherwise
        // empty buffer that line is the first row. Left alone, the loop below emits nothing
        // above it and then drops a date divider *underneath* it once real traffic arrives,
        // stranding it above the day it belongs to. So a leading undated run adopts the day of
        // the first dated message, and the divider goes up before any of them.
        //
        // Nothing is invented when there's no dated message at all: a buffer of purely local
        // lines has no day to name, and guessing one would be a claim we can't support.
        if messages.first?.date == nil, let firstDated = messages.first(where: { $0.date != nil })?.date {
            let day = calendar.startOfDay(for: firstDated)
            rows.append(.dateDivider(day))
            currentDay = day
        }
        for message in messages {
            // Local midnight, so the divider follows the reader's calendar rather than UTC's.
            // An undated message can't change the day and doesn't reset it — it just rides
            // whichever segment it arrived in.
            let day = message.date.map { calendar.startOfDay(for: $0) }
            let dayChanged = day != nil && day != currentDay
            let crossesReadBoundary = !unreadDividerPlaced && boundary > 0 && message.id > boundary

            if dayChanged || crossesReadBoundary {
                appendSegment(segment)
                segment = []
            }
            // Date above unread when both land on the same message, matching the web: the day
            // is context for what follows, the unread marker is the thing you're looking for.
            if dayChanged, let day {
                rows.append(.dateDivider(day))
                currentDay = day
            }
            if crossesReadBoundary {
                rows.append(.unreadDivider)
                unreadDividerPlaced = true
            }
            segment.append(message)
        }
        appendSegment(segment)

        // The typing line goes last, below even the newest message — it's the only row that
        // describes the present rather than the past. Appended *after* the run pass so it
        // never participates in one: it isn't a bubble, and a run that tried to include it
        // would re-tighten its corners every time somebody started or stopped typing.
        var built = withBubbleRuns(rows)
        if !typists.isEmpty { built.append(.typing(typists)) }
        return built
    }

    /// Second pass: fill in each bubble's `RunPosition` by looking at its neighbours. Only
    /// consecutive bubble rows group; a line, a summary, or a divider between two bubbles is a
    /// non-bubble neighbour and so breaks the run — exactly what we want.
    private static func withBubbleRuns(_ rows: [MessageRow]) -> [MessageRow] {
        func bubble(at index: Int) -> Message? {
            guard rows.indices.contains(index), case .bubble(let message, _) = rows[index] else { return nil }
            return message
        }
        return rows.enumerated().map { index, row in
            guard case .bubble(let message, _) = row else { return row }
            let isFirst = !MessageGrouping.continuesRun(message, after: bubble(at: index - 1))
            let isLast = bubble(at: index + 1).map { !MessageGrouping.continuesRun($0, after: message) } ?? true
            return .bubble(message, RunPosition(isFirst: isFirst, isLast: isLast))
        }
    }
}
