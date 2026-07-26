// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// Everything a row needs that comes from the screen rather than from the row itself.
///
/// Passed in rather than reached for, so a style can be exercised without a `ChatViewController` —
/// and so the screen's own state stays the screen's. The closures are resolvers the screen already
/// had; they're handed over whole rather than copied per row.
struct MessageListContext {
    /// What to call the network a nick-less line belongs to.
    let networkName: (Message) -> String?
    /// Colors known nicks mentioned in message bodies.
    let highlighter: NickHighlighter
    /// Lowercased nick → channel-mode glyph, for the author caption.
    let modePrefixes: [String: String]
    let settings: Settings
    /// The screen's live traits — `UITraitCollection.current` isn't reliably set in `cellForRowAt`.
    let traits: UITraitCollection
    /// How far the timestamps are currently slid in, for a style that reveals them.
    let reveal: CGFloat
    /// Whether the row at an index is status narration, for styles that space runs of it apart.
    let isStatusRow: (Int) -> Bool
    /// The row at an index, or nil out of range — for a style that has to look at a row's
    /// neighbours to lay it out. The compact style needs the one above to decide whether a message
    /// starts a new author block.
    let row: (Int) -> MessageRow?
}

/// How one message-list style turns rows into cells.
///
/// **This is the whole swappable surface.** A style owns its cells and the gestures that only make
/// sense for its cells, and nothing else: the composer, the nav pill, the banners and the floating
/// pills are a layer of glass above a list that can be replaced underneath them. The row *stream*
/// isn't a style's business either — `MessageRows` builds dividers, consolidation and run positions
/// once, for everyone.
///
/// Anything a style adds that the actions sheet needs (#60) is inherited rather than reimplemented:
/// the long-press recognizer lives on the table, and a cell only has to conform to
/// `MessageBodyHosting` for link presses to keep working.
protocol MessageListStyling {
    /// What the list sits on. Part of the style because it's part of the list — the chrome above
    /// it is untouched either way.
    var listBackground: UIColor { get }
    /// The cell classes this style dequeues. Called before it first renders.
    func register(in tableView: UITableView)
    func cell(
        for row: MessageRow, at index: Int, in tableView: UITableView, context: MessageListContext
    ) -> UITableViewCell
}

extension MessageListStyling {
    /// The system's, unless a style says otherwise.
    var listBackground: UIColor { .systemBackground }
}

extension MessageListStyle {
    /// The renderer for this style. A value, not a singleton — they're stateless.
    var styling: any MessageListStyling {
        switch self {
        case .bubbles: BubbleListStyle()
        case .compact: CompactListStyle()
        }
    }
}

// MARK: - Shared furniture

/// A centered marker row — the unread divider, a day change, the start of history.
///
/// Shared by every style rather than reimplemented per style: a break in the flow that names itself
/// looks the same whatever the rows around it look like, and the alternative is two places to fix
/// when a fourth marker lands.
enum MessageListMarker {
    static let reuseID = "divider"

    static func cell(_ text: String, color: UIColor, bold: Bool, in tableView: UITableView) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: reuseID)!
        var content = cell.defaultContentConfiguration()
        content.text = text
        content.textProperties.color = color
        let caption = UIFont.preferredFont(forTextStyle: .caption1)
        content.textProperties.font = bold
            ? caption.fontDescriptor.withSymbolicTraits(.traitBold)
                .map { UIFont(descriptor: $0, size: 0) } ?? caption
            : caption
        content.textProperties.alignment = .center
        cell.contentConfiguration = content
        cell.backgroundColor = .clear
        return cell
    }

    /// The three markers, identically in every style.
    static func cell(for row: MessageRow, in tableView: UITableView) -> UITableViewCell? {
        switch row {
        case .unreadDivider:
            cell("New messages", color: .systemRed, bold: true, in: tableView)
        case .dateDivider(let day):
            cell(MessageRenderer.dayLabel(day), color: .secondaryLabel, bold: false, in: tableView)
        case .startOfHistory:
            cell("— start of history —", color: .tertiaryLabel, bold: false, in: tableView)
        default:
            nil
        }
    }
}

// MARK: - Bubbles

/// The default style: dialogue as chat bubbles, narration as full-width lines, timestamps parked
/// off the right edge until the list is dragged. Exactly what the app rendered before styles
/// existed — this is that code, moved rather than rewritten.
struct BubbleListStyle: MessageListStyling {

    func register(in tableView: UITableView) {
        tableView.register(BubbleCell.self, forCellReuseIdentifier: BubbleCell.reuseID)
        tableView.register(LineCell.self, forCellReuseIdentifier: LineCell.reuseID)
    }

    func cell(
        for row: MessageRow, at index: Int, in tableView: UITableView, context: MessageListContext
    ) -> UITableViewCell {
        if let marker = MessageListMarker.cell(for: row, in: tableView) { return marker }

        switch row {
        case .bubble(let message, let position):
            let cell = tableView.dequeueReusableCell(withIdentifier: BubbleCell.reuseID) as! BubbleCell
            cell.configure(
                message, position: position, networkName: context.networkName(message),
                highlighter: context.highlighter,
                modePrefix: message.nick.flatMap { context.modePrefixes[$0.lowercased()] } ?? ""
            )
            // Scrolled into view mid-drag: match the neighbors it's arriving next to.
            cell.setReveal(context.reveal)
            return cell

        case .line(let message):
            let cell = tableView.dequeueReusableCell(withIdentifier: LineCell.reuseID) as! LineCell
            // A `/me` action is conversation and keeps the tight default; a status line is
            // narration and gets the block spacing that sets its run apart from the chat.
            let spacing = message.type.isActivity
                ? statusSpacing(at: index, context: context)
                : (top: CGFloat(4), bottom: CGFloat(4))
            cell.configure(
                MessageRenderer.render(message, traits: context.traits, settings: context.settings),
                date: message.date,
                topInset: spacing.top, bottomInset: spacing.bottom, highlighted: message.matched
            )
            cell.setReveal(context.reveal)
            return cell

        case .consolidated(let summary):
            // A collapsed run is a full-width meta line like any other activity line, so it rides
            // the same cell — just rendered from the summary instead of one message.
            let cell = tableView.dequeueReusableCell(withIdentifier: LineCell.reuseID) as! LineCell
            let spacing = statusSpacing(at: index, context: context)
            cell.configure(
                MessageRenderer.renderConsolidation(summary), date: summary.date,
                topInset: spacing.top, bottomInset: spacing.bottom
            )
            cell.setReveal(context.reveal)
            return cell

        case .typing(let nicks):
            // Rides `LineCell` like every other piece of narration — same margins, same font, same
            // reveal behavior. It just has no timestamp, because it isn't a moment.
            let cell = tableView.dequeueReusableCell(withIdentifier: LineCell.reuseID) as! LineCell
            cell.configure(
                MessageRenderer.renderTyping(nicks) ?? NSAttributedString(),
                date: nil, topInset: 10, bottomInset: 6
            )
            cell.setReveal(context.reveal)
            return cell

        case .unreadDivider, .dateDivider, .startOfHistory:
            preconditionFailure("markers are handled above")
        }
    }

    /// Vertical padding for a status line, by where it sits in a run of consecutive status rows.
    /// Like a bubble run, a status block opens a gap above its first line and below its last, but
    /// sits tight internally — so a cluster of joins/modes/topics reads as one block with air
    /// around it rather than as loose lines threaded through the conversation.
    private func statusSpacing(at index: Int, context: MessageListContext) -> (top: CGFloat, bottom: CGFloat) {
        let edge: CGFloat = 10, inner: CGFloat = 2
        return (
            top: context.isStatusRow(index - 1) ? inner : edge,
            bottom: context.isStatusRow(index + 1) ? inner : edge
        )
    }
}

// MARK: - Compact

/// The PWA's mobile compact shape: an author header with the time on it, then the message indented
/// underneath, several messages stacking under one header.
///
/// A header is drawn when the author block changes — which is `RunPosition.isFirst`, the same
/// answer the bubble style uses to decide whether to caption a run — **or** when the minute
/// changes. The second half is what makes the timestamp rule work: stamps only appear when the
/// minute rolls over, and a stamp needs a header to sit on, so a run crossing a minute boundary
/// breaks rather than losing the time.
///
/// The row stream still arrives with `RunPosition`s attached and this uses only `isFirst`, which
/// is the point of them being computed once by `MessageRows`: a style takes what it needs.
struct CompactListStyle: MessageListStyling {

    var listBackground: UIColor { Palette.compactListBackground }

    func register(in tableView: UITableView) {
        tableView.register(CompactCell.self, forCellReuseIdentifier: CompactCell.reuseID)
    }

    func cell(
        for row: MessageRow, at index: Int, in tableView: UITableView, context: MessageListContext
    ) -> UITableViewCell {
        if let marker = MessageListMarker.cell(for: row, in: tableView) { return marker }

        let cell = tableView.dequeueReusableCell(withIdentifier: CompactCell.reuseID) as! CompactCell
        switch row {
        case .bubble(let message, let position):
            // Once, not three times: it walks the neighbouring rows, builds a caption and hits
            // `Calendar`, and this runs for every visible cell on every reload.
            let blockHeader = header(for: message, position: position, at: index, context: context)
            cell.configure(
                MessageRenderer.renderCompactBody(
                    message, traits: context.traits, settings: context.settings,
                    highlighter: context.highlighter
                ),
                header: blockHeader,
                startsBlock: blockHeader != nil,
                endsBlock: endsBlock(at: index, context: context),
                highlighted: message.matched,
                traits: context.traits
            )
        case .line(let message):
            // A `/me` and the activity lines name their own actor, so they take no header.
            cell.configure(
                MessageRenderer.renderCompactBody(
                    message, traits: context.traits, settings: context.settings,
                    highlighter: context.highlighter
                ),
                header: nil, startsBlock: startsBlock(at: index, context: context),
                endsBlock: endsBlock(at: index, context: context),
                highlighted: message.matched,
                traits: context.traits
            )
        case .consolidated(let summary):
            cell.configure(
                MessageRenderer.renderCompactConsolidation(summary, traits: context.traits),
                header: nil,
                startsBlock: startsBlock(at: index, context: context),
                endsBlock: endsBlock(at: index, context: context),
                traits: context.traits
            )
        case .typing(let nicks):
            cell.configure(
                MessageRenderer.renderCompactTyping(nicks, traits: context.traits) ?? NSAttributedString(),
                header: nil,
                startsBlock: startsBlock(at: index, context: context),
                endsBlock: endsBlock(at: index, context: context),
                traits: context.traits
            )
        case .unreadDivider, .dateDivider, .startOfHistory:
            preconditionFailure("markers are handled above")
        }
        return cell
    }

    /// The header for a message, or nil when it continues the block above it.
    ///
    /// The time is carried only when the minute differs from the previous message's — that's the
    /// format's whole idea, and it's why a minute change forces a header even mid-run.
    private func header(
        for message: Message, position: RunPosition, at index: Int, context: MessageListContext
    ) -> CompactCell.Header? {
        let previous = previousMessage(before: index, context: context)
        let minuteChanged = changedMinute(message.date, previous?.date)
        guard position.isFirst || minuteChanged else { return nil }

        let prefix = message.nick.flatMap { context.modePrefixes[$0.lowercased()] } ?? ""
        // `caption` for the nick-less lines — server text names its network rather than a person,
        // exactly as the bubble style captions it. Nil means there's nothing to call this line:
        // server text whose network hasn't resolved yet, most often. The bubble style leaves such
        // a run uncaptioned, and so does this — an empty header is a blank line above the text,
        // with a stray right-aligned timestamp beside it on a minute change.
        guard let name = MessageRenderer.caption(
            message, networkName: context.networkName(message), modePrefix: prefix
        ) else { return nil }
        return CompactCell.Header(
            nick: name,
            color: MessageRenderer.captionColor(message, networkName: context.networkName(message)),
            // Called rather than passed as a function value: an unapplied reference to a
            // main-actor method crosses isolation on its own, which the compiler warns about even
            // though every caller here is already on the main actor.
            time: minuteChanged ? message.date.map { MessageRenderer.compactHeaderTime($0) } : nil
        )
    }

    /// Whether the row at `index` is the last of its block — i.e. whatever follows starts a new
    /// one, or there's nothing after it at all.
    ///
    /// Asked of the *next* row rather than tracked as state, because a table builds its cells in
    /// whatever order it likes and a running flag would be wrong on the way back up.
    private func endsBlock(at index: Int, context: MessageListContext) -> Bool {
        guard let next = context.row(index + 1) else { return true }
        // A run of status narration is one block, the same call the bubble style makes with its
        // tight `inner` spacing. Without this a netsplit with consolidation off puts three quarters
        // of a line between every join — looser in "compact" than in bubbles, which is backwards.
        if context.isStatusRow(index), context.isStatusRow(index + 1) { return false }
        guard case .bubble(let message, let position) = next else {
            // A divider, a `/me`, the typing line: each stands alone, so the row above it is the
            // end of whatever it was part of.
            return true
        }
        return header(for: message, position: position, at: index + 1, context: context) != nil
    }

    /// Whether a header-less row opens a block. Only status narration ever doesn't: a run of joins
    /// is one block, so only its first row carries the block's leading air.
    private func startsBlock(at index: Int, context: MessageListContext) -> Bool {
        !(context.isStatusRow(index) && context.isStatusRow(index - 1))
    }

    /// The nearest message above `index`, skipping the rows that carry none (dividers). Those are
    /// hard breaks in the flow anyway: a header under one is wanted regardless.
    private func previousMessage(before index: Int, context: MessageListContext) -> Message? {
        guard index > 0, let previous = context.row(index - 1) else { return nil }
        return previous.message
    }

    /// Whether these two instants fall in different minutes.
    ///
    /// A message with no clock never counts as a change: it has no stamp to show, so breaking the
    /// block for it would cost a header and gain nothing. A message *following* one with no clock
    /// does count, so the first line that knows what time it is says so.
    private func changedMinute(_ date: Date?, _ previous: Date?) -> Bool {
        guard let date, let previous else { return date != nil }
        return !Calendar.current.isDate(date, equalTo: previous, toGranularity: .minute)
    }
}
