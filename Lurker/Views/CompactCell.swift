// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// One row of the compact message list: an optional author header, then the text indented under it.
///
/// ```
/// alice 14:42
///  morning — did the deploy land?
///  and is the changelog updated?
/// bob joined 14:43
/// bob 14:43
///  yeah, ten minutes ago
/// ```
///
/// The shape is the PWA's compact layout: a header with the nick and then its time opens each
/// author run, and the run's later lines carry no time. A run lasts while the same author keeps
/// talking within `look.message.collapse_authors_window`, whatever the minute. See
/// `MessageListRenderer`, which decides. Nothing sits at the trailing edge (lurker#1237).
///
/// Anything that names its own actor — a `/me`, a join, a collapsed run — is header-less and draws
/// as a body line, because a nick header above "alice waves" would say her name twice. Its time
/// follows its text, inside the body (`MessageRenderer.renderCompactBody`).
///
/// How far apart it all sits is `look.message.compact.*` (lurker#1224), handed in per configure as
/// `MessageRenderer.CompactSpacing`.
///
/// There's no drag-to-reveal timestamp gesture anywhere in the app any more: the times are already
/// here, on the block headers.
final class CompactCell: UITableViewCell, MessageBodyHosting {
    static let reuseID = "compact"

    /// What to draw above the body, when the row starts a new author block.
    struct Header {
        let nick: String
        let color: UIColor
        /// Nil only for a line with no clock.
        let time: String?
        /// The speaker's channel-mode glyph, when `nick` opens with one. Carried separately from
        /// the name it's already part of, because it doesn't wear the name's color: a rank is a
        /// property of the room, not of the person, so the web gives it `look.color.member.*`
        /// and iOS follows. Empty for every header that isn't a channel member's — a network,
        /// a notice's `-mark-`, or the highlights feed, which doesn't resolve the nicklist.
        ///
        /// With its colour tier — by the mode letter's role, which the glyph alone can't say on a
        /// network whose symbols aren't the conventional ones (lurker-ios#191). One value, so the
        /// glyph and its colour can't disagree.
        let modeMark: MemberPrefix.Mark?
        var modePrefix: String { modeMark?.glyph ?? "" }
        /// Where a re-attributed relay line was bridged from (#277) — "Discord", "github", the
        /// source network. Nil on every header that isn't one, which is nearly all of them.
        ///
        /// It rides the header rather than the body because it qualifies the *name*: the header
        /// says who spoke, and this says where. Living here also means it's drawn exactly once per
        /// author block, which is where a run of one speaker's lines wants it.
        let relaySource: String?
        /// The display name to draw in place of the nick (lurker#1203), raw with its mIRC codes,
        /// or nil to draw `nick`. The caller has already applied the setting, the strip-to-empty
        /// rule and the relay exclusion; this only paints. The colour stays `color`, the nick's.
        let displayName: String?

        init(
            nick: String, color: UIColor, time: String?, modeMark: MemberPrefix.Mark? = nil,
            relaySource: String? = nil, displayName: String? = nil
        ) {
            self.nick = nick
            self.color = color
            self.time = time
            self.modeMark = modeMark
            self.relaySource = relaySource
            self.displayName = displayName
        }
    }

    /// The avatar column (lurker#607): present when `look.message.avatars` is on. `spec` is the
    /// tile to draw on a run's first row, nil on a continuation or a narration line, which keep
    /// the gutter so bodies stay on one edge.
    struct Avatar {
        let size: CGFloat
        let spec: NickAvatarView.Spec?
        let model: ChatViewModel?
        let onTap: (() -> Void)?
    }

    /// The reaction chips under a line (iOS #183), and what tapping them does. The closures
    /// close over the row's message, so they're handed in per configure and dropped on reuse.
    ///
    /// Not `Reactions`: that's LurkerKit's rules type, and a nested one would shadow it here.
    struct ReactionChips {
        let groups: [ReactionGroup]
        /// Tapping this chip can go out right now — see `ReactionContext.canToggle`.
        let canToggle: (ReactionGroup) -> Bool
        /// The line is one we could ever react to from here (not a notice, not encrypted).
        let showsAdd: Bool
        let onToggle: (String) -> Void
        let onOpen: () -> Void
        let onHeightChange: () -> Void
    }

    /// An IRCv3 reply's quote line (iOS #184): the line it answers, or nil for "unavailable", and
    /// where a tap on it goes — nil out of the buffer (a results row's tap is the row's own).
    struct ReplyLine {
        let quote: ReplyQuote?
        let onJump: ((ReplyQuote) -> Void)?
        /// The quoted nick's shown name (lurker#1203), or nil for nicks.
        var names: MessageRenderer.NameLookup? = nil
    }

    /// A spoiler in this cell's message was tapped, by its ordinal within the message. Set per
    /// configure and cleared in `prepareForReuse`, because it closes over that message.
    var onToggleSpoiler: ((Int) -> Void)?

    private let column = UIStackView()
    private let headerRow = UIStackView()
    private let nickLabel = UILabel()
    private let timeLabel = UILabel()
    /// Takes the rest of a horizontal header, so neither label stretches.
    private let headerSpacer = UIView()
    private let messageText = MessageTextView()
    /// A reply's quote, as the body's first line — part of the message, so a reply doesn't break
    /// its author's run. Faded as a whole (the web's opacity 0.45), so the quoted nick keeps its
    /// colour under the fade. Hidden on everything that isn't a reply.
    private let replyHolder = UIView()
    private let replyLabel = UILabel()
    private var replyTop: NSLayoutConstraint!
    private var onJumpToReply: (() -> Void)?
    /// Inline media / preview cards under the body (off by default; see
    /// `chat.inline_media.enabled` and `chat.link_previews.enabled`). Hidden and empty for
    /// the overwhelming majority of rows, which is why it's a plain stack view rather than
    /// anything lazier — an empty hidden `UIStackView` costs a pointer.
    private let attachments = MessageAttachmentsView()
    /// The reaction chips, in a holder that indents them under the body and gives them air.
    /// Hidden on every line nobody has reacted to, which is nearly all of them.
    private let reactionHolder = ReactionSlotView()
    private let reactionRow = ReactionRowView()
    private var reactionIndent: NSLayoutConstraint!
    private var reactionBottom: NSLayoutConstraint!
    /// Carries the matched-rule wash — see `configure`.
    private let fill = UIView()
    /// The avatar column (lurker#607): the tile on a run's first row, and the hairline down the
    /// gutter's right edge that makes it read as a panel beside the text — on the cell rather than
    /// the table so a washed row doesn't cut it, and full height so it runs through the gaps.
    private let avatarView = NickAvatarView()
    private let hairline = UIView()
    private var avatarSize: NSLayoutConstraint!
    private var avatarTop: NSLayoutConstraint!
    private var hairlineLeading: NSLayoutConstraint!
    /// How far the text column sits in from the side margin: 0, or the gutter when avatars are on.
    private var columnLeading: NSLayoutConstraint!
    /// An optical correction on the bottom of a block's fill.
    ///
    /// Equal padding above and below doesn't *look* equal: a line box carries its descender space
    /// below the baseline, so text sits high in it and the bottom of the band reads tighter than
    /// the top even when both are the same number. One point, measured by eye rather than derived
    /// — which is what an optical correction is.
    static let washBottomNudge: CGFloat = 1

    /// How far the body sits in, as the last `configure` resolved it — what attachments line up
    /// with.
    private var bodyIndent: CGFloat = 0

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
        // The time right after the nick, as Slack and Discord place it; the spacer behind them
        // takes the rest of the row, so neither label stretches.
        headerRow.addArrangedSubview(timeLabel)
        headerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        headerRow.addArrangedSubview(headerSpacer)

        messageText.isScrollEnabled = false
        messageText.backgroundColor = .clear
        // The view's default only — `MessageRenderer.body` stamps an explicit foreground on
        // every run it produces, so nothing this cell is handed actually falls back to it. What
        // colors the log is that renderer's `fallback:` argument, which is the same token. Kept
        // in step with it so an unstyled string dropped in here doesn't arrive a different color.
        messageText.textColor = Palette.fg
        messageText.textContainer.lineFragmentPadding = 0
        // ⚠⚠ The words must never be the thing that gives. A `UITextView` resists vertical
        // compression at 750 by default, and an attachment's height constraints are REQUIRED —
        // so any layout pass that hands this cell less height than its content wants collapses
        // the TEXT rather than the picture, and a message quietly loses lines. Observed as "in
        // lurker 2.1.1 there is a glimpse of" with the rest of the sentence gone, on exactly the
        // rows that carried an attachment.
        //
        // Paired with the attachment heights dropping to 999 (see `MessageAttachmentsView`), so
        // the two can't both be immovable: if something has to yield it is the decoration, which
        // is recoverable by looking, not the sentence, which is not.
        messageText.setContentCompressionResistancePriority(.required, for: .vertical)
        messageText.onOpenURL = { url in UIApplication.shared.open(url) }
        messageText.onToggleSpoiler = { [weak self] ordinal in self?.onToggleSpoiler?(ordinal) }

        column.axis = .vertical
        column.isLayoutMarginsRelativeArrangement = true
        attachments.isHidden = true
        attachments.onOpen = { url in UIApplication.shared.open(url) }
        attachments.onOpenGallery = { [weak self] previews, at in
            self?.onOpenMedia?(previews, at)
        }
        // Line up with the message body, which sits `look.message.compact.indent` characters in
        // from its author (the paragraph style's indent — see MessageRenderer.spaced). Without this an attachment
        // starts flush with the nick while the words above it don't, and the block loses the
        // single left edge that makes a run of messages read as one column.
        attachments.isLayoutMarginsRelativeArrangement = true

        // The column's side margins are the cell's own, not the table's — see
        // `useOwnSideMargins` for what the inherited ones do beside the iPhone Duo's side rail.
        MessageListRenderer.useOwnSideMargins(contentView)

        replyLabel.numberOfLines = 1
        replyLabel.lineBreakMode = .byTruncatingTail
        replyLabel.alpha = 0.45
        replyLabel.translatesAutoresizingMaskIntoConstraints = false
        replyLabel.isUserInteractionEnabled = true
        replyLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(replyTapped)))
        replyHolder.isHidden = true
        replyHolder.addSubview(replyLabel)
        replyTop = replyLabel.topAnchor.constraint(equalTo: replyHolder.topAnchor)
        NSLayoutConstraint.activate([
            replyTop,
            replyLabel.bottomAnchor.constraint(equalTo: replyHolder.bottomAnchor),
            replyLabel.leadingAnchor.constraint(equalTo: replyHolder.leadingAnchor),
            replyLabel.trailingAnchor.constraint(equalTo: replyHolder.trailingAnchor),
        ])

        column.addArrangedSubview(headerRow)
        column.addArrangedSubview(replyHolder)
        column.addArrangedSubview(messageText)
        column.addArrangedSubview(attachments)
        reactionHolder.isHidden = true
        reactionRow.translatesAutoresizingMaskIntoConstraints = false
        reactionHolder.addSubview(reactionRow)
        reactionHolder.row = reactionRow
        reactionIndent = reactionRow.leadingAnchor.constraint(equalTo: reactionHolder.leadingAnchor)
        reactionBottom = reactionRow.bottomAnchor.constraint(equalTo: reactionHolder.bottomAnchor)
        NSLayoutConstraint.activate([
            reactionIndent,
            reactionBottom,
            reactionRow.trailingAnchor.constraint(equalTo: reactionHolder.trailingAnchor),
            // Air above as well as below: a matched line's wash ends at the cell's edge, and chips
            // flush against it looked cut off (the web's note on its own row).
            reactionRow.topAnchor.constraint(equalTo: reactionHolder.topAnchor, constant: 6),
        ])
        column.addArrangedSubview(reactionHolder)
        column.translatesAutoresizingMaskIntoConstraints = false
        fill.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(fill)
        fill.addSubview(column)
        // Over the fill, as the web paints its `::before` hairline over a hovered row's ground.
        hairline.backgroundColor = Palette.border
        hairline.isHidden = true
        hairline.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(hairline)
        avatarView.isHidden = true
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(avatarView)

        fillBottom = fill.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        columnLeading = column.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor)
        avatarSize = avatarView.widthAnchor.constraint(equalToConstant: 0)
        avatarTop = avatarView.topAnchor.constraint(equalTo: contentView.topAnchor)
        hairlineLeading = hairline.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor)
        NSLayoutConstraint.activate([
            // Full-bleed and flush to the cell, so two washed rows meet with no seam.
            fill.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            fill.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            fill.topAnchor.constraint(equalTo: contentView.topAnchor),
            fillBottom,

            column.topAnchor.constraint(equalTo: fill.topAnchor),
            column.bottomAnchor.constraint(equalTo: fill.bottomAnchor),
            columnLeading,
            column.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),

            avatarView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            avatarSize,
            avatarView.heightAnchor.constraint(equalTo: avatarView.widthAnchor),
            avatarTop,
            // Through the row's whole height, gaps included: the cells abut, so the line is one.
            hairlineLeading,
            hairline.widthAnchor.constraint(equalToConstant: 1),
            hairline.topAnchor.constraint(equalTo: contentView.topAnchor),
            hairline.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
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
        reactions: ReactionChips? = nil,
        reply: ReplyLine? = nil,
        indentsBody: Bool = true,
        avatar: Avatar? = nil,
        spacing: MessageRenderer.CompactSpacing,
        traits: UITraitCollection
    ) {
        // A results list turns this off so a tap anywhere reaches the row's own selection (the
        // jump) instead of being swallowed by the text view hit-testing for a link.
        messageText.isUserInteractionEnabled = interactive
        // The screen's live traits, handed down with the row — a cell's own `traitCollection` isn't
        // settled while it's being configured, and neither is `UITraitCollection.current`.
        let font = MessageRenderer.compactFont(compatibleWith: traits)
        // What the reactions and attachments line up with: the body's setting under a header, the
        // narration's own one-character hang on a header-less line (a `/me`), whose words start
        // flush and which the setting leaves alone.
        bodyIndent = indentsBody ? spacing.bodyIndent : MessageRenderer.compactIndent(compatibleWith: traits)
        headerRow.isHidden = header == nil
        // The web's 0.75ch between the name and its time. A stack view drops the spacing beside a
        // hidden arranged view, so a header with no time leaves no gap behind.
        headerRow.spacing = MessageRenderer.compactIndent(compatibleWith: traits) * 0.75
        // At the accessibility sizes the time goes under the name and may wrap: an older line's
        // `2026-10-20 14:42` is wider than a phone at 49pt, and beside the nick on one line it
        // could only overflow the row. The stacked-at-large-sizes layout Apple's own lists use.
        let stacked = traits.preferredContentSizeCategory.isAccessibilityCategory
        headerRow.axis = stacked ? .vertical : .horizontal
        headerRow.alignment = stacked ? .leading : .firstBaseline
        headerSpacer.isHidden = stacked
        timeLabel.numberOfLines = stacked ? 0 : 1
        // A required resistance would still claim its one-line width and push past the row.
        timeLabel.setContentCompressionResistancePriority(stacked ? .defaultHigh : .required, for: .horizontal)
        if let header {
            // The name at the body's weight, as the web draws it — except beside the avatar gutter,
            // where the body sits flush under the nick and weight is what tells the head line from
            // the text (the web's `font-weight: 600` there; bold is the only weight this face has).
            let nameFont = avatar == nil ? font : font.bold
            let name: NSMutableAttributedString
            if let shown = header.displayName {
                // The display name (lurker#1203) with its own formatting over the nick's colour;
                // the rank glyph ahead of it as it is ahead of a nick.
                name = NSMutableAttributedString()
                if let mark = header.modeMark {
                    name.append(NSAttributedString(
                        string: mark.glyph,
                        attributes: [.font: font.bold, .foregroundColor: Palette.memberPrefix(mark.tier)]
                    ))
                }
                name.append(MessageRenderer.formattedName(shown, color: header.color, base: nameFont))
            } else {
                name = NSMutableAttributedString(
                    string: header.nick,
                    attributes: [.font: nameFont, .foregroundColor: header.color]
                )
                // The mode glyph in its rank's color, the name in the speaker's — the split the
                // web's `NickRef` makes.
                //
                // Bold via `withTrait`, the only weight that takes on this monospaced face
                // (`semibold` resolves to the same Regular). The glyph needs the weight for
                // contrast: the rank hues are ~3.5-4:1 on the light canvas.
                if let mark = header.modeMark, header.nick.hasPrefix(mark.glyph) {
                    let rank = Palette.memberPrefix(mark.tier)
                    name.addAttributes(
                        [.foregroundColor: rank, .font: font.bold],
                        range: NSRange(location: 0, length: header.modePrefix.utf16.count)
                    )
                }
            }
            // Relay provenance (#277), trailing the name it qualifies: `alice github`.
            // Unbracketed, and in the timestamp's `fgMuted`, as the web draws it: it sits between
            // the name and the time now, and reads as part of the grey that follows the name.
            // It's a hint, not a field — you read it when you wonder where someone is speaking
            // from, and the rest of the time it shouldn't be pulling at a name that's already
            // carrying a colour of its own.
            //
            // Last in the label on purpose: it truncates from the tail, so under width pressure
            // the provenance goes before the speaker's name does.
            if let source = header.relaySource, !source.isEmpty {
                name.append(NSAttributedString(
                    string: " \(source)",
                    attributes: [.font: font, .foregroundColor: Palette.fgMuted]
                ))
            }
            // Always attributed, never `text`. Cells are reused, and a header that took an
            // attributed path last time leaves a string behind that only a `text` assignment
            // clears — a hazard that existed while this was two branches and doesn't now that
            // it's one.
            nickLabel.attributedText = name
            // Hidden when there's no name to show (a reaction to a `/me` in the highlights feed),
            // so the stack's spacing doesn't push the time off the left edge.
            nickLabel.isHidden = name.length == 0
            timeLabel.font = font
            timeLabel.text = header.time
            // Hidden rather than left empty, so the stack's spacing doesn't hold a gap open for a
            // stamp that isn't there.
            timeLabel.isHidden = header.time == nil
        }

        // Half the line gap at each end, so two adjacent cells put exactly one gap between their
        // text — the same distance `MessageRenderer` puts between two wrapped lines of one message.
        // A header takes a slightly wider gap of its own (`headerGap`), because a name and the
        // words under it are less alike than two body lines are.
        let padding = spacing.lineGap / 2
        let wash = spacing.washPadding
        column.layoutMargins = UIEdgeInsets(
            top: (header == nil ? 0 : padding) + (startsBlock ? wash : 0), left: 0, bottom: 0, right: 0
        )
        // The block's closing air goes under whatever is last: the chips when there are any, so
        // a matched block's wash still ends a band's width below its last visible thing.
        let closing = endsBlock ? wash + Self.washBottomNudge : 0
        let showsReactions = !(reactions?.groups.isEmpty ?? true)
        // A quote takes the gap above the body, and the body follows it a line-gap down — the
        // distance between two lines of one message, which is what the two are.
        let topGap = header == nil ? padding : spacing.headerGap
        replyHolder.isHidden = reply == nil
        onJumpToReply = nil
        if let reply {
            replyTop.constant = topGap
            replyLabel.attributedText = MessageRenderer.renderReplyQuote(
                reply.quote,
                indent: indentsBody ? spacing.bodyIndent : 0,
                traits: traits,
                names: reply.names
            )
            replyLabel.accessibilityLabel = MessageRenderer.spokenReplyQuote(reply.quote)
            if let quote = reply.quote, let jump = reply.onJump {
                onJumpToReply = { jump(quote) }
                replyLabel.accessibilityTraits = .button
                replyLabel.accessibilityHint = "Jumps to that message."
            } else {
                replyLabel.accessibilityTraits = .staticText
                replyLabel.accessibilityHint = nil
            }
            replyLabel.isUserInteractionEnabled = interactive && onJumpToReply != nil
        }
        messageText.textContainerInset = UIEdgeInsets(
            top: reply != nil ? spacing.lineGap : topGap,
            left: 0, // indentation is the paragraph style's — see `MessageRenderer.spaced`
            bottom: padding + (showsReactions ? 0 : closing),
            right: 0
        )
        reactionHolder.isHidden = !showsReactions
        if let reactions, showsReactions {
            reactionIndent.constant = bodyIndent
            reactionBottom.constant = -(padding + 2 + closing)
            reactionRow.onToggle = reactions.onToggle
            reactionRow.onOpen = reactions.onOpen
            reactionRow.onHeightChange = reactions.onHeightChange
            reactionRow.configure(
                groups: reactions.groups, canToggle: reactions.canToggle,
                showsAdd: reactions.showsAdd, traits: traits
            )
        }
        // The rest of the gap — the part that isn't inside either block's fill — is reserved by
        // the cell and excluded from it, so what separates two blocks is background.
        fillBottom.constant = endsBlock
            ? -(spacing.blockGap - 2 * wash)
            : 0

        // The avatar column (lurker#607). Every row takes the gutter while avatars are on —
        // continuations and narration too, so bodies stay on one edge — and only a run's first
        // row draws a tile, centred on its head and first body line, the two lines a short
        // message's wash covers. The tile at the side margin where the text otherwise starts,
        // the web's `--space-4`, a hairline, then `--space-5` before the text.
        avatarView.onTap = nil
        if let avatar {
            columnLeading.constant = avatar.size + NickAvatarView.gutterPadding + NickAvatarView.gutterAfterLine
            hairlineLeading.constant = avatar.size + NickAvatarView.gutterPadding
            hairline.isHidden = false
            avatarSize.constant = avatar.size
            if let spec = avatar.spec, header != nil {
                let headAndFirstLine = 2 * font.lineHeight + spacing.headerGap
                avatarTop.constant = column.layoutMargins.top + max(0, (headAndFirstLine - avatar.size) / 2)
                avatarView.configure(spec, size: avatar.size, model: avatar.model)
                avatarView.onTap = avatar.onTap
                avatarView.isHidden = false
            } else {
                avatarView.isHidden = true
            }
        } else {
            columnLeading.constant = 0
            hairline.isHidden = true
            avatarView.isHidden = true
        }

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
        // Empties dropped as well as nils: a header can carry a time with no nick (a reaction to a
        // `/me` in the highlights feed), and an unfiltered join would open the spoken label with a comma.
        //
        // Relay provenance needs a connective it doesn't need in print, where colour separates the
        // two words: read out bare, "alice github" is two names. It says "from" rather than the
        // action sheet's "via", because the two name different things — a source and the bot.
        let spokenNick = header.map { head in
            // The shown name where there is one (lurker#1203), with the rank glyph the nick carries.
            let said = UserMetadata.shown(head.displayName).map { head.modePrefix + $0 } ?? head.nick
            return head.relaySource.flatMap { $0.isEmpty ? nil : "\(said) from \($0)" } ?? said
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
    /// Present the message's pictures full-screen. Set by the row builder from the screen, like
    /// `onToggleSpoiler` — a cell has no business knowing how to present a view controller.
    var onOpenMedia: (([LinkPreview], Int) -> Void)?

    func showAttachments(_ previews: [LinkPreview], model: ChatViewModel) {
        // The indent `configure` resolved, from the screen's traits and the density — so a
        // picture lines up with the words above it at any text size and any indent.
        let indent = bodyIndent
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

    @objc private func replyTapped() { onJumpToReply?() }

    func reactionChip(at point: CGPoint) -> Bool {
        guard !reactionHolder.isHidden, reactionHolder.bounds.contains(convert(point, to: reactionHolder))
        else { return false }
        return reactionRow.containsChip(at: convert(point, to: reactionRow))
    }

    /// Measured at the width the table is asking about, so the chips know where they wrap.
    ///
    /// ⚠ The chip row's height is a function of its width, and Auto Layout hands a self-sizing
    /// cell's subviews no width before it asks their heights — the trap `UILabel` escapes with
    /// `preferredMaxLayoutWidth`. So lay out once at the target width, tell the row what it got,
    /// and only then measure. Skipped on every line without chips, which is nearly all of them.
    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontal: UILayoutPriority,
        verticalFittingPriority vertical: UILayoutPriority
    ) -> CGSize {
        guard !reactionHolder.isHidden, targetSize.width > 0 else {
            return super.systemLayoutSizeFitting(
                targetSize, withHorizontalFittingPriority: horizontal, verticalFittingPriority: vertical)
        }
        // A measuring pass lays the row out at widths of its own; that's not a mismatch to report.
        reactionRow.isMeasuring = true
        defer { reactionRow.isMeasuring = false }
        bounds.size.width = targetSize.width
        layoutIfNeeded()
        reactionRow.availableWidth = reactionRow.bounds.width
        return super.systemLayoutSizeFitting(
            targetSize, withHorizontalFittingPriority: horizontal, verticalFittingPriority: vertical)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // An in-flight jump flash (#42) would otherwise pulse on an unrelated line.
        contentView.layer.removeAllAnimations()
        fill.layer.removeAllAnimations()
        // The closure captures the message it was built for. Left in place, a tap on a recycled
        // cell whose row didn't set one would toggle a spoiler on whatever message used it last.
        onToggleSpoiler = nil
        onOpenMedia = nil
        reactionRow.onToggle = nil
        reactionRow.onOpen = nil
        reactionRow.onHeightChange = nil
        onJumpToReply = nil
        avatarView.onTap = nil
    }
}
