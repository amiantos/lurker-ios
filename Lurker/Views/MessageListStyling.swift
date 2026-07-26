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
    /// The cell classes this style dequeues. Called before it first renders.
    func register(in tableView: UITableView)
    func cell(
        for row: MessageRow, at index: Int, in tableView: UITableView, context: MessageListContext
    ) -> UITableViewCell
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

/// The terminal feed: every row is one full-width monospaced line with its time at the head.
///
/// No bubbles, no captions, no grouping, and no reveal gesture — see `CompactCell`. The row stream
/// still arrives with `RunPosition`s attached and this ignores them, which is the point of run
/// positions being computed once by `MessageRows`: a style takes what it needs.
struct CompactListStyle: MessageListStyling {

    func register(in tableView: UITableView) {
        tableView.register(CompactCell.self, forCellReuseIdentifier: CompactCell.reuseID)
    }

    func cell(
        for row: MessageRow, at index: Int, in tableView: UITableView, context: MessageListContext
    ) -> UITableViewCell {
        if let marker = MessageListMarker.cell(for: row, in: tableView) { return marker }

        let cell = tableView.dequeueReusableCell(withIdentifier: CompactCell.reuseID) as! CompactCell
        switch row {
        // Dialogue and narration draw identically here — that uniformity is the style.
        case .bubble(let message, _), .line(let message):
            cell.configure(
                MessageRenderer.renderCompact(
                    message, networkName: context.networkName(message),
                    traits: context.traits, settings: context.settings, highlighter: context.highlighter
                ),
                highlighted: message.matched,
                striped: message.alt
            )
        case .consolidated(let summary):
            cell.configure(MessageRenderer.renderCompactConsolidation(summary))
        case .typing(let nicks):
            cell.configure(MessageRenderer.renderCompactTyping(nicks) ?? NSAttributedString())
        case .unreadDivider, .dateDivider, .startOfHistory:
            preconditionFailure("markers are handled above")
        }
        return cell
    }
}
