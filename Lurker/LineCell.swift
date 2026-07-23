// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// A full-width line, for the events that aren't dialogue: `/me` actions, structural
/// traffic, and the system and server buffers' own output. These carry their own inline
/// prefix ("* nick waves", "--", a network name) and read as narration about the room
/// rather than speech in it, so they stay lines while dialogue becomes bubbles.
///
/// Backed by a `UITextView` rather than a label so auto-linked URLs are actually tappable
/// (a `UILabel` ignores `.link` interaction) and text is selectable to copy. Non-editable
/// and non-scrolling so it behaves like a self-sizing label.
final class LineCell: UITableViewCell, TimestampRevealing {
    static let reuseID = "line"

    private let messageText = UITextView()
    private let revealTime = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        // Parks the timestamp off the trailing edge until the drag pulls it in.
        contentView.clipsToBounds = true

        revealTime.font = .preferredFont(forTextStyle: .subheadline)
        revealTime.textColor = .tertiaryLabel
        revealTime.adjustsFontForContentSizeCategory = true
        revealTime.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(revealTime)

        messageText.isEditable = false
        messageText.isScrollEnabled = false
        messageText.isSelectable = true // required for tappable links (also enables copy)
        messageText.backgroundColor = .clear
        messageText.textColor = .label // dynamic fallback for any run without an explicit color
        // No left inset here: the leading edge is set by pinning to the same layout-margin
        // guide the bubbles use (below), so an action's `*` lines up with the nicks and
        // bubble edges rather than sitting a couple points inside them off its own inset.
        messageText.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 12)
        messageText.textContainer.lineFragmentPadding = 0
        // Body-colored with a soft underline, matching the web's `--link` default and the
        // bubbles' links (see BubbleCell) — the underline alone marks it.
        messageText.linkTextAttributes = [
            .foregroundColor: UIColor.label,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: UIColor.label.withAlphaComponent(0.4),
        ]
        messageText.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(messageText)
        NSLayoutConstraint.activate([
            messageText.topAnchor.constraint(equalTo: contentView.topAnchor),
            messageText.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            // Short of the trailing edge by exactly the reveal's width, so the timestamp
            // has somewhere to arrive. A line is flush to *both* margins, so unlike a
            // bubble it has no gutter of its own — and it can't slide aside to make one
            // the way our own bubbles do, because there's nothing to its leading side but
            // the edge: it would push its own first characters off the screen. Reserving
            // the room costs the same ~19% a bubble already gives up, and nothing reflows
            // mid-drag.
            messageText.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -TimestampReveal.maxOffset
            ),
            messageText.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            revealTime.leadingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: 12),
            // Centered on the line rather than pinned a fixed distance below its top — a
            // hard-coded offset drifts off the text as Dynamic Type grows the font. Matches
            // how BubbleCell centers its own time.
            revealTime.centerYAnchor.constraint(equalTo: messageText.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    /// `topInset`/`bottomInset` are set per row, not fixed, so a block of status lines can
    /// open a gap above and below itself while staying tight internally — the same "run
    /// reads as a block" rhythm `BubbleCell` uses. Callers that don't care (a `/me` action)
    /// keep the conversational default.
    /// `highlighted` washes the whole row in the warm highlight fill — for a `/me` action a
    /// rule matched. It's a full-bleed band rather than a bubble because a line has no bubble;
    /// this mirrors the web's `.line.highlight`. Only actions ever pass true — status
    /// narration and consolidated runs carry no rule match — so it defaults off.
    func configure(
        _ attributed: NSAttributedString, date: Date?,
        topInset: CGFloat = 4, bottomInset: CGFloat = 4, highlighted: Bool = false
    ) {
        messageText.textContainerInset = UIEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 12)
        messageText.attributedText = attributed
        contentView.backgroundColor = highlighted ? Palette.highlightBubble : .clear
        revealTime.text = MessageRenderer.timestamp(date)
        // VoiceOver has no drag to make, so the time is spoken as part of the line rather
        // than left behind a gesture it can't perform.
        messageText.accessibilityLabel = [attributed.string, revealTime.text]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    /// The line itself never moves — only the timestamp does. See the trailing constraint.
    func setReveal(_ offset: CGFloat) {
        revealTime.transform = CGAffineTransform(translationX: -offset, y: 0)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // A cell recycled mid-drag would otherwise come back with its time still pulled in.
        setReveal(0)
        // configure() always reassigns contentView.backgroundColor on dequeue, so a stale
        // matched-line wash never survives — but an in-flight jump-flash animation (#42) would,
        // so cancel it here rather than let it pulse an unrelated message.
        contentView.layer.removeAllAnimations()
    }
}
