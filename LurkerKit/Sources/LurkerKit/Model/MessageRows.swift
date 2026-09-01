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
    /// The `/clear` boundary (#121) — everything above it is hidden, and this row is the way
    /// back. Carries the instant the clear was issued, for the same reason `awayDivider` does.
    ///
    /// Drawn even when it is the ONLY row. Clearing a buffer you then can't un-clear without
    /// typing `/clear off` blind is the one outcome this feature must not have, so an empty
    /// visible region still gets the divider.
    case clearedDivider(at: Date)
    /// Where your own `/away` falls in this buffer (#68) — the point past which the
    /// conversation carried on without you. Carries the away reason when one was given.
    ///
    /// The instant rides the row for the same reason `dateDivider` carries a `Date` rather
    /// than a string: what the label says is a render-time decision, and a row that had to be
    /// paired back up with store state to be drawn would be a row a second message-list style
    /// couldn't render on its own.
    case awayDivider(at: Date, message: String?)
    /// Where your own `/back` falls. Carries the away instant too, so the row can say how
    /// long you were gone without the renderer having to hold the away state as well.
    case backDivider(awayAt: Date, at: Date)
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
        case .unreadDivider, .dateDivider, .startOfHistory, .clearedDivider, .awayDivider, .backDivider,
             .typing: return nil
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
        case .consolidated, .unreadDivider, .dateDivider, .startOfHistory, .clearedDivider, .awayDivider, .backDivider,
             .typing: nil
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
        case .bubble, .unreadDivider, .dateDivider, .startOfHistory, .clearedDivider, .awayDivider, .backDivider,
             .typing: false
        }
    }

    /// Whether this row stands in for message `id` — its own row, or the summary whose span
    /// covers it after a history page merged it into a consolidated run.
    public func represents(_ id: Int) -> Bool {
        switch self {
        case .bubble(let message, _): message.id == id
        case .line(let message): message.id == id
        case .consolidated(let summary): summary.firstId <= id && id <= summary.lastId
        case .unreadDivider, .dateDivider, .startOfHistory, .clearedDivider, .awayDivider, .backDivider,
             .typing: false
        }
    }
}

/// Turns a buffer's filtered messages into the row stream a message list renders.
///
/// Lives here rather than in the view controller because it is the layout-independent half of
/// the list: the same rows feed whatever cell styles render them, so a second style inherits
/// the dividers, the consolidation and the run positions rather than rebuilding them.
public enum MessageRows {

    /// How long after `/back` the away/back pair keeps being drawn. Matches the web's
    /// `PRESENCE_MARKER_TTL_MS`.
    public static let presenceMarkerTTL: TimeInterval = 30 * 60

    /// Whether `date` falls after `instant` — the anchoring test both presence markers use.
    /// A message with no clock is never "after" anything: there is no instant to compare, and
    /// treating it as epoch (which the web's `Date.parse(…) || 0` effectively does) would put
    /// a marker above a line that could as easily belong below it.
    private static func crosses(_ date: Date?, _ instant: Date?) -> Bool {
        guard let date, let instant else { return false }
        return date > instant
    }

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
    ///   - hasMoreNewer: whether the loaded slice sits *below* the live tail — the buffer is
    ///     detached (#42), showing an `around` window around some older message. The presence
    ///     markers' foot fallback reads it to suppress itself (see there), and it suppresses
    ///     the `/clear` filter outright (see `clearedBeforeId`).
    ///   - clearedBeforeId: the `/clear` boundary (#121); every message at or below it is
    ///     hidden. 0 for a buffer that has never been cleared.
    ///
    ///   - showsClearedHistory: the reader is deliberately looking at what the marker hides —
    ///     a jump landed on a row below the boundary (#121). Suppresses the filter exactly like
    ///     detachment does, and is a SEPARATE flag for a reason: `hasMoreNewer` drives paging,
    ///     and claiming it on a buffer holding the tail makes the near-bottom `loadNewer` fire
    ///     and re-hide everything a frame later.
    ///
    ///     Passed in rather than read off the buffer because it belongs to the SCREEN, not the
    ///     account: a fresh one is built per open, so the reveal retires itself and a buffer
    ///     reopened later is cleared again. See `ChatViewController.showsClearedHistory`.
    ///
    ///     ⚠⚠ Suppressed entirely while DETACHED. A jump to a search hit or a highlight shows
    ///     context around its anchor regardless of the marker — the user asked to see that
    ///     message, and answering the tap with an empty screen because it predates a clear
    ///     would be obeying the wrong instruction. Same rule as the web
    ///     (`MessageList.vue:1064`), and the reason the filter lives here rather than in the
    ///     store: the messages are still held, they are just not drawn.
    ///   - clearedAt: when the clear was issued, for the divider's label. The divider is drawn
    ///     iff this is non-nil, so a boundary with no instant hides rows and says nothing —
    ///     which is why `Buffer.applyCleared` moves the two together.
    ///   - typists: who is composing right now, for the foot of the list.
    ///   - settings: the user's settings, for the event tier and the two consolidation keys.
    ///   - speakers: who has spoken in this buffer and when. Feeds both the `.smart` tier and
    ///     consolidation's truncated name lists — see `SpeakerMap`.
    ///   - ownNick: your nick on this buffer's network, so the `.smart` tier never hides your
    ///     own churn. Nil where there is no network to have a nick on (the system buffer).
    ///   - away: your own away state for this buffer's network, or nil for a buffer that
    ///     doesn't take presence markers (the `:server:` log, the system buffer). See
    ///     `presenceMarkerTTL` for when a settled pair stops being drawn.
    ///   - now: the instant the TTL is judged against. Passed in rather than read, so expiry
    ///     is testable at a chosen moment — the same read-time lease `typists(in:now:)` uses.
    ///   - calendar: which calendar decides a day boundary. Injected so tests can pin a
    ///     timezone; callers should take the default.
    public static func build(
        messages: [Message],
        dividerAfterId: Int?,
        hasMoreOlder: Bool,
        hasMoreNewer: Bool = false,
        clearedBeforeId: Int = 0,
        clearedAt: Date? = nil,
        showsClearedHistory: Bool = false,
        typists: [String] = [],
        settings: Settings = Settings(),
        speakers: SpeakerMap = SpeakerMap(),
        ownNick: String? = nil,
        away: AwayState? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [MessageRow] {
        let boundary = dividerAfterId ?? 0

        // The away/back pair anchors on message *time*, never on id: ids are insertion order,
        // so a later history prepend renumbers what sits either side of an id-anchored marker
        // and moves it somewhere it never happened.
        //
        // Both halves retire together once the user has been back a while. In a slow buffer
        // they'd otherwise sit there for days, describing an absence nobody remembers, and
        // retiring only the `back` half would leave a permanent "away" over a user who is
        // demonstrably here. Nothing forces a redraw at expiry — a marker survives in an idle
        // buffer until the next rebuild — which is acceptable for something already half an
        // hour stale, and is why this is a read-time lease rather than a timer.
        let presenceSettled = away?.backAt.map { now.timeIntervalSince($0) > presenceMarkerTTL } ?? false
        let awayAt = presenceSettled ? nil : away?.since
        let backAt = presenceSettled ? nil : away?.backAt

        // All server-side (#65), so the phone agrees with whatever the user set on the web.
        // The fallbacks match the registry's own defaults, so behavior doesn't shift under the
        // user when bootstrap lands a moment after launch.
        // The `/clear` marker, unless the buffer is detached — see the parameter's note. Both
        // halves are read through these, so a detached view can't half-apply the marker.
        //
        // ⚠⚠ And neither can a half-stated one. A boundary with no instant would hide the rows
        // and draw no divider, which is the single outcome this feature must not have: a blank
        // buffer whose only way back is a `/clear off` the reader was never told about. The
        // server's `cleared_at` is nullable and its rename/case-fold merges COALESCE the two
        // columns independently, so this is reachable from the wire, not just from a bug here.
        // Showing messages the user cleared is the safe direction to fail in; stranding them
        // behind an invisible filter is not.
        let suppressed = hasMoreNewer || showsClearedHistory
        let clearInstant = suppressed ? nil : clearedAt
        let clearBoundary = clearInstant == nil ? 0 : clearedBeforeId

        let eventMode = EventFilter.mode(settings)
        // At `.none` there are no event rows left to fold, so the consolidation pass is
        // skipped outright rather than run over a stream it can't match.
        let consolidateEnabled = eventMode != .none
            && settings.bool("chat.consolidate_joins", default: true)
        let maxNames = settings.int("chat.consolidate_max_names", default: 5)

        // The event tier (#666, #63) applies before anything else looks at the stream, so
        // dividers anchor to the first row the reader can actually see and a segment can't be
        // built out of rows that will never render. It also has to sit above consolidation
        // specifically: a filtered-out event that reached a summary would inflate its counts
        // and name people whose own lines are hidden.
        let messages = EventFilter.visible(
            // The clear boundary applies FIRST, above even the event tier: a cleared message
            // is not a row that was filtered, it is a row the user has said they are done
            // with. Feeding hidden lines to the tier or to consolidation would let them
            // inflate a summary's counts and name people whose own lines are gone.
            //
            // A message with no persisted id (a locally synthesized system line) has id 0 and
            // is never hidden — it has no place in the server's ordering to be above or below
            // the boundary, and it postdates the clear by construction.
            clearBoundary > 0 ? messages.filter { $0.id == 0 || $0.id > clearBoundary } : messages,
            settings: settings, speakers: speakers, ownNick: ownNick
        )

        // Who to float to the front of a summary that had to truncate its name list: the
        // people you were just talking to, rather than whoever happens to sort first.
        let recentSpeakers = speakers.nicks

        var rows: [MessageRow] = []
        func appendSegment(_ slice: [Message]) {
            guard consolidateEnabled else {
                // Off: every event stands on its own line, exactly as it arrived.
                rows.append(contentsOf: slice.map { $0.type.isBubble ? .bubble($0, .solo) : .line($0) })
                return
            }
            for row in Consolidation.consolidate(
                slice, maxNames: maxNames, recentSpeakers: recentSpeakers
            ) {
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
        //
        // ⚠ And suppressed while a clear is in force, where it would be a lie of a useful
        // kind: `hasMoreOlder` answers "is there more to FETCH", but what the row SAYS is
        // "there is nothing above this" — and above this there is a buffer's worth of hidden
        // conversation the divider below is offering to bring back.
        if !hasMoreOlder && !messages.isEmpty && clearInstant == nil { rows.append(.startOfHistory) }

        // The clear divider tops the visible region — above the first date, so the reader sees
        // "cleared at …" before any day (the web's ordering, `MessageList.vue:1222`).
        //
        // Emitted here rather than lazily at the first surviving row because the filter above
        // has already run: what remains IS the visible set, so its top is this. That also
        // covers the case the web has to special-case at the end of its loop — a clear that
        // hid everything leaves this row alone on screen, which is the whole point. Without
        // it the buffer would go blank with no way back but typing `/clear off` blind.
        if let clearInstant { rows.append(.clearedDivider(at: clearInstant)) }

        var segment: [Message] = []
        var currentDay: Date?
        var unreadDividerPlaced = false
        var awayDividerPlaced = false
        var backDividerPlaced = false

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
            // Each presence marker goes above the first line that happened *after* the
            // transition, which is the first thing you missed (away) or the first thing you
            // were back for (back). An undated line can't answer "after", so it never carries
            // one — it just rides its segment, exactly as it does for the day divider.
            let opensAway = !awayDividerPlaced && crosses(message.date, awayAt)
            let opensBack = !backDividerPlaced && crosses(message.date, backAt)

            if dayChanged || crossesReadBoundary || opensAway || opensBack {
                appendSegment(segment)
                segment = []
            }
            // Date above unread when both land on the same message, matching the web: the day
            // is context for what follows, the unread marker is the thing you're looking for.
            // The presence pair sits between them, for the same reason in both directions.
            if dayChanged, let day {
                rows.append(.dateDivider(day))
                currentDay = day
            }
            if opensAway, let awayAt {
                rows.append(.awayDivider(at: awayAt, message: away?.message))
                awayDividerPlaced = true
            }
            if opensBack, let awayAt, let backAt {
                rows.append(.backDivider(awayAt: awayAt, at: backAt))
                backDividerPlaced = true
            }
            if crossesReadBoundary {
                rows.append(.unreadDivider)
                unreadDividerPlaced = true
            }
            segment.append(message)
        }
        appendSegment(segment)

        // A presence marker with nothing below it belongs at the foot of the buffer.
        //
        // This is the *common* case, not an edge: you go away, and by definition nothing has
        // been said since — so neither timestamp has a message after it to sit above, and the
        // loop above places nothing. Left to the loop alone the markers would only ever appear
        // in the minority of buffers that kept talking without you, which is to say almost
        // never at the moment you'd look for one.
        //
        // Suppressed on an empty buffer, like `startOfHistory` above and for the same reason: a
        // lone marker over no conversation isn't a marker, and it would take the empty-state
        // placeholder down with it (`ChatViewController` reads `rows.isEmpty` for that).
        //
        // And suppressed on a *detached* buffer, where this fallback is a claim the window
        // can't support. Its meaning is "nothing has been said since" — only knowable when the
        // loaded slice reaches the tail. Jump to a search hit from last week and it would pin
        // "You went away" under a week-old message, asserting an absence that happened days
        // after anything on screen. Note this suppresses only the *fallback*: an anchored
        // marker stays, because sitting above the first message after the away instant is true
        // wherever that message is, tail or not.
        if !messages.isEmpty, !hasMoreNewer {
            if !awayDividerPlaced, let awayAt {
                rows.append(.awayDivider(at: awayAt, message: away?.message))
            }
            if !backDividerPlaced, let awayAt, let backAt {
                rows.append(.backDivider(awayAt: awayAt, at: backAt))
            }
        }

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
