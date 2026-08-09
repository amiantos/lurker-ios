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
/// time. See `MessageListRenderer`, which decides.
///
/// Anything that names its own actor — a `/me`, a join, a collapsed run — is header-less and draws
/// as a body line, because a nick header above "alice waves" would say her name twice.
///
/// There's no drag-to-reveal timestamp gesture anywhere in the app any more: the times are already
/// here, on the block headers.
final class CompactCell: UITableViewCell, MessageBodyHosting {
    static let reuseID = "compact"

    /// What to draw above the body, when the row starts a new author/minute block.
    struct Header {
        let nick: String
        let color: UIColor
        /// Nil unless the minute changed — the whole point of the format.
        let time: String?
        /// The speaker's channel-mode glyph, when `nick` opens with one. Carried separately from
        /// the name it's already part of, because it doesn't wear the name's color: a rank is a
        /// property of the room, not of the person, so the web gives it `look.color.member.*`
        /// and iOS follows. Empty for every header that isn't a channel member's — a network,
        /// a notice's `-mark-`, or the highlights feed, which doesn't resolve the nicklist.
        let modePrefix: String
        /// Where a re-attributed relay line was bridged from (#277) — "Discord", "github", the
        /// source network. Nil on every header that isn't one, which is nearly all of them.
        ///
        /// It rides the header rather than the body because it qualifies the *name*: the header
        /// says who spoke, and this says where. Living here also means it's drawn exactly once per
        /// author block, which is where a run of one speaker's lines wants it.
        let relaySource: String?

        init(nick: String, color: UIColor, time: String?, modePrefix: String = "", relaySource: String? = nil) {
            self.nick = nick
            self.color = color
            self.time = time
            self.modePrefix = modePrefix
            self.relaySource = relaySource
        }
    }

    /// A spoiler in this cell's message was tapped, by its ordinal within the message. Set per
    /// configure and cleared in `prepareForReuse`, because it closes over that message.
    var onToggleSpoiler: ((Int) -> Void)?

    private let column = UIStackView()
    private let headerRow = UIStackView()
    private let nickLabel = UILabel()
    private let timeLabel = UILabel()
    private let messageText = MessageTextView()
    /// Inline media / preview cards under the body (off by default; see
    /// `chat.inline_media.enabled` and `chat.link_previews.enabled`). Hidden and empty for
    /// the overwhelming majority of rows, which is why it's a plain stack view rather than
    /// anything lazier — an empty hidden `UIStackView` costs a pointer.
    private let attachments = MessageAttachmentsView()
    /// Carries the matched-rule wash — see `configure`.
    private let fill = UIView()
    /// An optical correction on the bottom of a block's fill.
    ///
    /// Equal padding above and below doesn't *look* equal: a line box carries its descender space
    /// below the baseline, so text sits high in it and the bottom of the band reads tighter than
    /// the top even when both are the same number. One point, measured by eye rather than derived
    /// — which is what an optical correction is.
    private static let washBottomNudge: CGFloat = 1

    /// Held so the block gap can be taken *outside* the wash: the fill stops at the text, and the
    /// separating space below is plain background. Otherwise a matched block's band hangs three
    /// quarters of a line below its last word.
    private var fillBottom: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear

        // No `adjustsFontForContentSizeCategory` on either label. It only rescales a font that
        // carries a text style, and the compact face is a `monospacedSystemFont` at an
        // already-scaled point size — no style to track, so the flag was doing nothing but
        // implying it was.
        //
        // What does carry a text size change through is the table rebuilding its cells, since
        // `configure` re-assigns the font every time. That's measured, not promised: a probe
        // counted `cellForRowAt` on a category change (+7/+17/+14/+16 calls, the font tracking
        // each category exactly) against a control where an appearance change produced none —
        // which is why the appearance trait needs the explicit observer in `ChatViewController`
        // and this one doesn't. If that ever stops holding, the fix is an observer beside that
        // one rather than this flag, which cannot help whatever UIKit does.
        nickLabel.lineBreakMode = .byTruncatingTail
        // Spoken as part of the body's label instead; addressable here it would be said twice.
        nickLabel.isAccessibilityElement = false

        timeLabel.textColor = Palette.fgMuted
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
        // The view's default only — `MessageRenderer.body` stamps an explicit foreground on
        // every run it produces, so nothing this cell is handed actually falls back to it. What
        // colors the log is that renderer's `fallback:` argument, which is the same token. Kept
        // in step with it so an unstyled string dropped in here doesn't arrive a different color.
        messageText.textColor = Palette.fg
        messageText.textContainer.lineFragmentPadding = 0
        messageText.onOpenURL = { url in UIApplication.shared.open(url) }
        messageText.onToggleSpoiler = { [weak self] ordinal in self?.onToggleSpoiler?(ordinal) }

        column.axis = .vertical
        column.isLayoutMarginsRelativeArrangement = true
        attachments.isHidden = true
        attachments.onOpen = { url in UIApplication.shared.open(url) }
        // Line up with the message body, which sits one character in from its author (the
        // paragraph style's indent — see MessageRenderer.spaced). Without this an attachment
        // starts flush with the nick while the words above it don't, and the block loses the
        // single left edge that makes a run of messages read as one column.
        attachments.isLayoutMarginsRelativeArrangement = true

        column.addArrangedSubview(headerRow)
        column.addArrangedSubview(messageText)
        column.addArrangedSubview(attachments)
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
    /// `startsBlock` and `endsBlock` mark the ends of an author block. They do two things: put the
    /// separating gap after the last row (a *bottom* margin rather than a top one on the next
    /// header, so the final block is pushed clear of the composer instead of sitting against it),
    /// and keep a third of that gap inside the fill at each end, so a matched block's wash is a
    /// band its text sits inside rather than a highlighter dragged across it.
    func configure(
        _ attributed: NSAttributedString,
        header: Header?,
        startsBlock: Bool = true,
        endsBlock: Bool = false,
        highlighted: Bool = false,
        interactive: Bool = true,
        traits: UITraitCollection
    ) {
        // A results list turns this off so a tap anywhere reaches the row's own selection (the
        // jump) instead of being swallowed by the text view hit-testing for a link.
        messageText.isUserInteractionEnabled = interactive
        // The screen's live traits, handed down with the row — a cell's own `traitCollection` isn't
        // settled while it's being configured, and neither is `UITraitCollection.current`.
        let font = MessageRenderer.compactFont(compatibleWith: traits)
        headerRow.isHidden = header == nil
        if let header {
            let nickFont = font.semibold
            let name = NSMutableAttributedString(
                string: header.nick,
                attributes: [.font: nickFont, .foregroundColor: header.color]
            )
            // The mode glyph in its rank's color, the name in the speaker's — the split the web's
            // `NickRef` makes.
            //
            // Bold via `withTrait`, which is the only thing that takes on this face — `semibold`
            // adds a weight attribute that a monospaced font's concrete name beats in matching, so
            // `nickFont` above is not in fact heavier than the body. The glyph needs the weight for
            // contrast: the rank hues are ~3.5-4:1 on the light canvas, which clears the bar for
            // large text and not the one for regular.
            if let rank = Palette.memberPrefix(header.modePrefix), header.nick.hasPrefix(header.modePrefix) {
                name.addAttributes(
                    [.foregroundColor: rank, .font: nickFont.bold],
                    range: NSRange(location: 0, length: header.modePrefix.utf16.count)
                )
            }
            // Relay provenance (#277), trailing the name it qualifies: `alice github`.
            // Unbracketed, and `fgFaint` — a tier below the timestamp at the other end of this
            // row, not level with it. It's a hint, not a field: you read it when you wonder where
            // someone is speaking from, and the rest of the time it shouldn't be pulling at a name
            // that's already carrying a colour of its own.
            //
            // Last on the line on purpose: the label truncates from the tail, so under width
            // pressure the provenance goes before the speaker's name does.
            if let source = header.relaySource, !source.isEmpty {
                name.append(NSAttributedString(
                    string: " \(source)",
                    attributes: [.font: font, .foregroundColor: Palette.fgFaint]
                ))
            }
            // Always attributed, never `text`. Cells are reused, and a header that took an
            // attributed path last time leaves a string behind that only a `text` assignment
            // clears — a hazard that existed while this was two branches and doesn't now that
            // it's one.
            nickLabel.attributedText = name
            timeLabel.font = font
            timeLabel.text = header.time
            // Hidden rather than left empty, so the spacer doesn't hold a gap open for a stamp
            // that isn't there.
            timeLabel.isHidden = header.time == nil
        }

        // Half the line gap at each end, so two adjacent cells put exactly one gap between their
        // text — the same distance `MessageRenderer` puts between two wrapped lines of one message.
        // A header takes a slightly wider gap of its own (`compactHeaderGap`), because a name and
        // the words under it are less alike than two body lines are.
        let padding = MessageRenderer.compactLineGap / 2
        let wash = MessageRenderer.compactWashPadding(compatibleWith: traits)
        column.layoutMargins = UIEdgeInsets(
            top: (header == nil ? 0 : padding) + (startsBlock ? wash : 0), left: 0, bottom: 0, right: 0
        )
        messageText.textContainerInset = UIEdgeInsets(
            top: header == nil ? padding : MessageRenderer.compactHeaderGap,
            left: 0, // indentation is the paragraph style's — see `MessageRenderer.spaced`
            bottom: padding + (endsBlock ? wash + Self.washBottomNudge : 0),
            right: 0
        )
        // The rest of the gap — the part that isn't inside either block's fill — is reserved by
        // the cell and excluded from it, so what separates two blocks is background.
        fillBottom.constant = endsBlock
            ? -(MessageRenderer.compactBlockGap(compatibleWith: traits) - 2 * wash)
            : 0

        messageText.attributedText = attributed
        // ⚠⚠ Collapsed when the body has no text left, which happens exactly when every URL in
        // the message was hidden because its picture is standing in for it — the common shape
        // for "someone posted a screenshot and nothing else". An empty `UITextView` still claims
        // a full line box, so without this the picture sits under a blank line and reads as
        // belonging to the message above it.
        //
        // This is iOS's answer to the case the web solved differently: there an attachments-only
        // body has no line box at all, so `align-items: baseline` fell through to whatever the
        // attachment exposed and the nick appeared level with an image's bottom edge, or a
        // card's title, seemingly at random. A stack view collapses a hidden arranged subview
        // outright, so the nick and timestamp keep their place with nothing to fall through to.
        messageText.isHidden = attributed.length == 0
        // Torn down, not merely hidden. Hiding left the previous message's image views — and
        // their strong references to decoded UIImages, plus a strip's width constraints — alive
        // for the cell's whole lifetime, quietly defeating the NSCache eviction the loader
        // relies on. `showAttachments` re-populates when there IS something to show.
        attachments.clear()
        // No zebra of any kind: the author header marks where a block starts, which is the job the
        // striping was doing. Only a matched rule paints a row.
        fill.backgroundColor = highlighted ? Palette.highlightBubble : .clear
        // Empties dropped as well as nils: a header can carry a time with no nick (a `/me` in the
        // highlights feed), and an unfiltered join would open the spoken label with a comma.
        //
        // Relay provenance needs a connective it doesn't need in print, where colour separates the
        // two words: read out bare, "alice github" is two names. It says "from" rather than the
        // action sheet's "via", because the two name different things — a source and the bot.
        let spokenNick = header.map { head in
            head.relaySource.flatMap { $0.isEmpty ? nil : "\(head.nick) from \($0)" } ?? head.nick
        }
        messageText.accessibilityLabel = [spokenNick, MessageRenderer.spoken(attributed), header?.time]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        // The label may be only half of it. A non-editable UITextView is documented to derive
        // its `accessibilityValue` from its own text, and VoiceOver reads label THEN value — if
        // that holds here, the substituted label above would be followed by the raw hidden text,
        // announcing the very secret it just declined to.
        //
        // ⚠ UNVERIFIED. Blanking the value costs nothing and closes that hole *if* it's the
        // hole; nobody has yet put VoiceOver on a message with a hidden spoiler and listened.
        // Until someone has, treat the spoiler's screen-reader story as untested rather than
        // solved — this line is a precaution, not a proof.
        messageText.accessibilityValue = ""
        applySpoilerActions(for: attributed)
    }

    /// One VoiceOver action per hidden spoiler, because the tap that opens one is hit-tested
    /// against a screen point and VoiceOver has no point to give.
    ///
    /// ⚠ Without these the label's "double tap to reveal" is a promise nothing keeps: a
    /// VoiceOver double tap activates the element, not a coordinate, so it could only ever hit a
    /// spoiler by coincidence — and never choose between two in one line. The actions are named
    /// by position ("reveal spoiler 2 of 3") since the whole point is that their contents can't
    /// be read out to tell them apart.
    private func applySpoilerActions(for attributed: NSAttributedString) {
        var ordinals: [Int] = []
        attributed.enumerateAttribute(
            .spoiler, in: NSRange(location: 0, length: attributed.length)
        ) { value, range, _ in
            guard let ordinal = value as? Int,
                  attributed.attribute(.spoilerHidden, at: range.location, effectiveRange: nil) != nil,
                  !ordinals.contains(ordinal)
            else { return }
            ordinals.append(ordinal)
        }
        guard !ordinals.isEmpty else {
            messageText.accessibilityCustomActions = nil
            return
        }
        let total = ordinals.count
        messageText.accessibilityCustomActions = ordinals.enumerated().map { position, ordinal in
            let name = total == 1 ? "Reveal spoiler" : "Reveal spoiler \(position + 1) of \(total)"
            return UIAccessibilityCustomAction(name: name) { [weak self] _ in
                self?.onToggleSpoiler?(ordinal)
                return true
            }
        }
    }

    /// Show link previews under the body. Called after `configure`, which has already cleared
    /// whatever the recycled cell was showing before.
    ///
    /// Nothing here is conditional on the settings — the renderer resolves those once per
    /// reload rather than once per cell, and hands down an already-filtered list.
    func showAttachments(_ previews: [LinkPreview], model: ChatViewModel, traits: UITraitCollection) {
        // Resolved from the screen's traits, not `UITraitCollection.current`, which isn't
        // reliably set during `cellForRowAt` — the same trap MessageRenderer.compactFont was
        // caught in. The indent scales with Dynamic Type, so it can't be a constant.
        let indent = MessageRenderer.compactIndent(compatibleWith: traits)
        // Breathing room below as well as above, matching the web client. Without it an image
        // sits flush against the next author's name and reads as belonging to the message below
        // it rather than the one above. INSIDE the cell's fill on purpose: on a highlighted row
        // the wash should cover the attachment and its padding, since both belong to that message.
        attachments.layoutMargins = UIEdgeInsets(top: 6, left: indent, bottom: 8, right: 0)
        attachments.configure(previews: previews, model: model)
    }

    func linkURL(at point: CGPoint) -> URL? {
        messageText.url(at: convert(point, to: messageText))
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // An in-flight jump flash (#42) would otherwise pulse on an unrelated line.
        contentView.layer.removeAllAnimations()
        fill.layer.removeAllAnimations()
        // The closure captures the message it was built for. Left in place, a tap on a recycled
        // cell whose row didn't set one would toggle a spoiler on whatever message used it last.
        onToggleSpoiler = nil
    }
}
