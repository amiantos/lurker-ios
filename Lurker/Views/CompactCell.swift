// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// One row of the compact message list: an optional author header, then the text indented under it.
///
/// ```
/// alice                      14:42
///  morning — did the deploy land?
///  and is the changelog updated?
/// bob
///  yeah, ten minutes ago
/// ```
///
/// The shape is the PWA's mobile compact mode, with one deliberate difference: the timestamp sits
/// on the author line rather than floating at the right edge of whichever body line happens to
/// start a new minute. Same rule about *when* it appears — only when the minute changes — but it
/// lands somewhere structural instead of somewhere incidental.
///
/// That rule is also why a header appears on an author change **or** a minute change: a stamp needs
/// a header to sit on, so a run crossing a minute boundary starts a new one rather than losing the
/// time. See `CompactListStyle`.
///
/// Anything that names its own actor — a `/me`, a join, a collapsed run — is header-less and draws
/// as a body line, because a nick header above "alice waves" would say her name twice.
///
/// Two things it deliberately doesn't have: no timestamp reveal (the times are already here — see
/// `MessageListStyle.revealsTimestamps`, which is why that gesture isn't installed at all in this
/// style), and no bubble run positions, which describe corner rounding this style has no corners
/// for.
final class CompactCell: UITableViewCell, MessageBodyHosting {
    static let reuseID = "compact"

    /// What to draw above the body, when the row starts a new author/minute block.
    struct Header {
        let nick: String
        let color: UIColor
        /// Nil unless the minute changed — the whole point of the format.
        let time: String?
    }

    private let column = UIStackView()
    private let headerRow = UIStackView()
    private let nickLabel = UILabel()
    private let timeLabel = UILabel()
    private let messageText = MessageTextView()
    /// Carries the matched-rule wash — see `configure`.
    private let fill = UIView()
    /// Held so the block gap can be taken *outside* the wash: the fill stops at the text, and the
    /// separating space below is plain background. Otherwise a matched block's band hangs three
    /// quarters of a line below its last word.
    private var fillBottom: NSLayoutConstraint!

    /// How far the body sits in from the author above it: exactly one character of the monospaced
    /// face, so the indent lands on the same grid as the text rather than at an arbitrary offset.
    private static var bodyIndent: CGFloat {
        (" " as NSString).size(withAttributes: [.font: MessageRenderer.compactFont()]).width
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear

        nickLabel.adjustsFontForContentSizeCategory = true
        nickLabel.lineBreakMode = .byTruncatingTail
        // Spoken as part of the body's label instead; addressable here it would be said twice.
        nickLabel.isAccessibilityElement = false

        timeLabel.adjustsFontForContentSizeCategory = true
        timeLabel.textColor = .secondaryLabel
        timeLabel.isAccessibilityElement = false
        // The nick truncates before the clock does: a long nick is recoverable from context, a
        // half-rendered time is just wrong.
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        nickLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        headerRow.axis = .horizontal
        headerRow.alignment = .firstBaseline
        headerRow.addArrangedSubview(nickLabel)
        headerRow.addArrangedSubview(UIView()) // spacer: pushes the time to the trailing edge
        headerRow.addArrangedSubview(timeLabel)

        messageText.isScrollEnabled = false
        messageText.backgroundColor = .clear
        messageText.textColor = .label
        messageText.textContainer.lineFragmentPadding = 0
        messageText.onOpenURL = { url in UIApplication.shared.open(url) }

        column.axis = .vertical
        column.isLayoutMarginsRelativeArrangement = true
        column.addArrangedSubview(headerRow)
        column.addArrangedSubview(messageText)
        column.translatesAutoresizingMaskIntoConstraints = false
        fill.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(fill)
        fill.addSubview(column)

        fillBottom = fill.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        NSLayoutConstraint.activate([
            // Full-bleed and flush to the cell, so two washed rows meet with no seam.
            fill.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            fill.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            fill.topAnchor.constraint(equalTo: contentView.topAnchor),
            fillBottom,

            column.topAnchor.constraint(equalTo: fill.topAnchor),
            column.bottomAnchor.constraint(equalTo: fill.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    /// A nil `header` renders the body alone — a continuation, or a line that names its own actor.
    ///
    /// `highlighted` is the matched-rule wash, full-bleed rather than anything bubble-shaped.
    ///
    /// `endsBlock` adds the gap that separates one author block from the next. It's a *bottom*
    /// margin rather than a top one on the following header, so the last block in a buffer is
    /// pushed clear of the composer too instead of sitting against it.
    func configure(
        _ attributed: NSAttributedString,
        header: Header?,
        highlighted: Bool = false,
        endsBlock: Bool = false
    ) {
        let font = MessageRenderer.compactFont()
        headerRow.isHidden = header == nil
        if let header {
            nickLabel.font = font.semibold
            nickLabel.text = header.nick
            nickLabel.textColor = header.color
            timeLabel.font = font
            timeLabel.text = header.time
            // Hidden rather than left empty, so the spacer doesn't hold a gap open for a stamp
            // that isn't there.
            timeLabel.isHidden = header.time == nil
        }

        // Half the line gap at each end, so two adjacent cells put exactly one gap between their
        // text — the same distance `MessageRenderer` puts between two wrapped lines of one message.
        // The body keeps that half above it whether or not there's a header, which is what sets an
        // author's name off from their words instead of clamping them together.
        let padding = MessageRenderer.compactLineGap / 2
        column.layoutMargins = UIEdgeInsets(top: header == nil ? 0 : padding, left: 0, bottom: 0, right: 0)
        messageText.textContainerInset = UIEdgeInsets(
            top: padding, left: Self.bodyIndent, bottom: padding, right: 0
        )
        // Reserved by the cell but excluded from the fill, so the gap between blocks is background
        // rather than an extension of a matched block's wash.
        fillBottom.constant = endsBlock ? -MessageRenderer.compactBlockGap : 0

        messageText.attributedText = attributed
        // No zebra of any kind: the author header marks where a block starts, which is the job the
        // striping was doing. Only a matched rule paints a row.
        fill.backgroundColor = highlighted ? Palette.highlightBubble : .clear
        messageText.accessibilityLabel = [header?.nick, attributed.string, header?.time]
            .compactMap { $0 }
            .joined(separator: ", ")
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
