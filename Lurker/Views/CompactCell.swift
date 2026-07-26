// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// One line of the compact (terminal) message list: a fixed-width log line, timestamp included.
///
/// Deliberately the *only* cell that style uses. Where the bubble style splits rows into dialogue
/// (`BubbleCell`) and narration (`LineCell`), this draws everything the same way — a message, a
/// join, a collapsed run and the typing line are all one full-width line — because that uniformity
/// is what makes it read as a log rather than as a chat with the bubbles taken off.
///
/// Two things it deliberately doesn't have, both of which `BubbleCell` needs and this doesn't:
///
///  - **No timestamp reveal.** The time is already at the head of every line, so there's nothing
///    to slide in — see `MessageListStyle.revealsTimestamps`, which is why the gesture isn't even
///    installed in this style. That also frees the trailing gutter `LineCell` has to reserve, so
///    lines run the full width.
///  - **No run positions.** Nothing groups, so nothing needs to know where it sits in a run.
final class CompactCell: UITableViewCell, MessageBodyHosting {
    static let reuseID = "compact"

    private let messageText = MessageTextView()
    /// Carries the row's fill — the zebra stripe, or the warm wash when a rule matched.
    ///
    /// A view rather than `contentView.backgroundColor` so the cell's vertical padding sits
    /// *outside* it: the gap between lines stays the list's background, and a highlighted line
    /// reads as a band around its own text instead of a slab that touches its neighbours.
    private let fill = UIView()

    /// The gap between lines. Small on purpose — the density is the feature — but enough that a
    /// highlighted or striped row is a band rather than part of a block.
    private static let verticalGap: CGFloat = 2
    /// Breathing room inside the fill, so text isn't flush against the top of its own stripe.
    private static let textPadding: CGFloat = 2

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear

        messageText.isScrollEnabled = false
        messageText.backgroundColor = .clear
        messageText.textColor = .label
        messageText.textContainer.lineFragmentPadding = 0
        messageText.onOpenURL = { url in UIApplication.shared.open(url) }
        messageText.translatesAutoresizingMaskIntoConstraints = false
        fill.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(fill)
        fill.addSubview(messageText)

        NSLayoutConstraint.activate([
            // Full bleed horizontally: a stripe that stopped at the text margin would read as a
            // highlighted *word* rather than a row.
            fill.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            fill.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            fill.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.verticalGap / 2),
            fill.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Self.verticalGap / 2),

            messageText.topAnchor.constraint(equalTo: fill.topAnchor),
            messageText.bottomAnchor.constraint(equalTo: fill.bottomAnchor),
            messageText.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            messageText.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    /// `highlighted` washes the line the way the other styles wash a matched message; `striped`
    /// is the zebra band. Both are full-bleed rather than anything bubble-shaped — there are no
    /// shapes in here — and a match wins, because it's the one you're meant to find.
    func configure(_ attributed: NSAttributedString, highlighted: Bool = false, striped: Bool = false) {
        messageText.textContainerInset = UIEdgeInsets(
            top: Self.textPadding, left: 0, bottom: Self.textPadding, right: 0
        )
        messageText.attributedText = attributed
        fill.backgroundColor = if highlighted {
            Palette.highlightBubble
        } else if striped {
            Palette.altRow
        } else {
            .clear
        }
        messageText.accessibilityLabel = attributed.string
    }

    func linkURL(at point: CGPoint) -> URL? {
        messageText.url(at: convert(point, to: messageText))
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // An in-flight jump flash (#42) would otherwise pulse on an unrelated line.
        contentView.layer.removeAllAnimations()
        fill.layer.removeAllAnimations()
    }
}
