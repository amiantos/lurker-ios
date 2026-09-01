// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// A cell whose body can say whether a point lands on a link (#60).
///
/// The message list hit-tests before deciding what a long press is about — a press on a URL is
/// about the URL, not the line around it. The cell owns the conversion because only it knows where
/// its body sits inside the row.
protocol MessageBodyHosting: UITableViewCell {
    func linkURL(at point: CGPoint) -> URL?
}

/// Everything a row needs that comes from the screen rather than from the row itself.
///
/// Passed in rather than reached for, so rows can be built without a `ChatViewController` — the
/// highlights feed and the throwaway layout probes both do — and so the screen's own state stays
/// the screen's. The closures are resolvers the screen already had; they're handed over whole
/// rather than copied per row.
struct MessageListContext {
    /// What to call the network a nick-less line belongs to.
    let networkName: (Message) -> String?
    /// Colors known nicks mentioned in message bodies.
    let highlighter: NickHighlighter
    /// Lowercased nick → channel-mode glyph, for the author header.
    let modePrefixes: [String: String]
    let settings: Settings
    /// The screen's live traits. Not `UITraitCollection.current`, which isn't reliably set during
    /// `cellForRowAt` — see `MessageRenderer.compactFont`, which was caught doing exactly that.
    let traits: UITraitCollection
    /// Whether the row at an index is status narration, so a run of it can be spaced as one block.
    let isStatusRow: (Int) -> Bool
    /// The row at an index, or nil out of range — the renderer looks at a row's neighbours to
    /// decide whether it opens an author block.
    let row: (Int) -> MessageRow?
    /// Which spoilers in a message the reader has opened, by their ordinal within it.
    ///
    /// Held by the screen, not the cell: cells are recycled, so a reveal stored on one would
    /// reappear on whatever message scrolled into its place. Keyed by message id for the same
    /// reason — an index into the row stream shifts every time backlog loads above.
    let revealedSpoilers: (Message) -> Set<Int>
    /// A spoiler in `Message` was tapped, identified by its ordinal within that message. The
    /// screen owns the toggle and the redraw.
    let onToggleSpoiler: (Message, Int) -> Void
    /// Present a message's pictures full-screen. Nil on screens with nothing to present from —
    /// the highlights feed and the layout probes — where a tap falls back to opening the address.
    var onOpenMedia: (([LinkPreview], Int) -> Void)?
    /// Link previews, or nil on the screens that don't show them.
    ///
    /// Optional rather than always-present because the highlights feed and the throwaway
    /// layout probes build a context without a view model, and previews are decoration those
    /// two have no business fetching.
    let previews: PreviewContext?
}

/// What a row needs to draw link previews. Bundled so `MessageListContext` grows by one
/// optional field rather than four.
struct PreviewContext {
    let store: LinkPreviewStore
    let model: ChatViewModel
    /// Resolved once per reload rather than once per cell — the settings can't change
    /// mid-reload, and `Settings.bool` on every visible row is pure repetition.
    let inlineMedia: Bool
    let linkPreviews: Bool
    /// Whether either feature is on. Both off and nothing below this ever runs.
    var isEnabled: Bool { inlineMedia || linkPreviews }
}

/// Turns a `MessageRow` into a cell.
///
/// Lives outside `ChatViewController` for two reasons: that screen is long enough already and cell
/// construction is a self-contained job, and the highlights feed renders single messages through
/// the same path, so a hit reads exactly like the line it came from.
///
/// Deliberately *not* a protocol with one conformer any more. While there were two styles behind
/// one interface the indirection paid for itself; with a single way to draw a message it was a
/// vtable and a registration dance in front of one struct. Reintroducing the seam for a third
/// style is a smaller change than keeping it warm was.
struct MessageListRenderer {

    /// What the list sits on: the web client's `look.color.bg` in both schemes — its charcoal
    /// rather than the system's near-black, its warm off-white rather than pure white. The log
    /// is the one surface that is Lurker's rather than the system's; see `Palette`.
    var listBackground: UIColor { Palette.bg }

    func register(in tableView: UITableView) {
        tableView.register(CompactCell.self, forCellReuseIdentifier: CompactCell.reuseID)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: MessageListMarker.reuseID)
    }

    /// A row's cell.
    ///
    /// The shape: an author header (nick, plus the time when the minute changed) and the message
    /// indented one character under it, several messages stacking beneath one header. A header
    /// appears on an author change — `RunPosition.isFirst`, which `MessageRows` already computed —
    /// **or** on a minute change, because the stamp needs a header to sit on and a run crossing a
    /// minute boundary would otherwise lose it.
    ///
    /// Anything that names its own actor — a `/me`, a join, a collapsed run, the typing line — is
    /// header-less and starts flush with the nicks, because it *is* that line.
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
            let plan = Self.previewPlan(for: message, context: context)
            cell.onToggleSpoiler = { [onToggleSpoiler = context.onToggleSpoiler] ordinal in
                onToggleSpoiler(message, ordinal)
            }
            cell.configure(
                MessageRenderer.renderCompactBody(
                    message, traits: context.traits, settings: context.settings,
                    highlighter: context.highlighter,
                    revealed: context.revealedSpoilers(message),
                    hiddenUrls: plan.hidden
                ),
                header: blockHeader,
                startsBlock: blockHeader != nil,
                endsBlock: endsBlock(at: index, context: context),
                highlighted: message.matched,
                traits: context.traits
            )
            attach(plan, to: cell, context: context)
        case .line(let message):
            let plan = Self.previewPlan(for: message, context: context)
            cell.onToggleSpoiler = { [onToggleSpoiler = context.onToggleSpoiler] ordinal in
                onToggleSpoiler(message, ordinal)
            }
            cell.configure(
                MessageRenderer.renderCompactBody(
                    message, traits: context.traits, settings: context.settings,
                    highlighter: context.highlighter,
                    revealed: context.revealedSpoilers(message),
                    hiddenUrls: plan.hidden
                ),
                header: nil, startsBlock: startsBlock(at: index, context: context),
                endsBlock: endsBlock(at: index, context: context),
                highlighted: message.matched,
                traits: context.traits
            )
            attach(plan, to: cell, context: context)
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
        case .unreadDivider, .dateDivider, .startOfHistory, .clearedDivider, .awayDivider,
             .backDivider:
            preconditionFailure("markers are handled above")
        }
        return cell
    }

    /// Draw a message's link previews, if it has any and the reader wants them.
    ///
    /// The order matters and is the whole reason this is lazy: `PreviewSelection.urls` returns
    /// empty the moment both settings are off, so a reader with the features disabled — the
    /// default — pays one boolean check per row and nothing else. No regex, no store lookup,
    /// no request.
    ///
    /// ⚠ Reads ONLY — this never asks for a preview. Requesting is done at message ingest
    /// (`ChatViewModel.primePreviews`), so by the time a row is drawn its preview is usually
    /// already known and the row's height is right on first measure. Asking from here is what
    /// made scrolling into history grow rows under the reader.
    /// What a row's previews mean for it: which addresses the body drops, and what to draw.
    ///
    /// ⚠ Computed ONCE per row. The two halves used to derive it separately, so every cell ran
    /// `PreviewSelection.urls` twice — a formatting parse and a regex sweep over the message body,
    /// on every dequeue, in a list that reloads its visible rows whenever a batch of previews
    /// lands. They also have to agree by construction: the text losing a URL and the picture
    /// appearing are the same event, so deriving them from two passes is the defect class this
    /// feature keeps producing, one level up from where it last appeared.
    struct PreviewPlan {
        let hidden: Set<String>
        let resolved: [LinkPreview]
        static let none = PreviewPlan(hidden: [], resolved: [])
    }

    static func previewPlan(for message: Message, context: MessageListContext) -> PreviewPlan {
        guard let previews = context.previews, previews.isEnabled,
            PreviewSelection.isPreviewable(message.type)
        else { return .none }

        let urls = PreviewSelection.urls(
            in: message.text,
            inlineMedia: previews.inlineMedia,
            linkPreviews: previews.linkPreviews
        )
        // ⚠⚠ ATOMIC REVEAL, and it gates BOTH halves. A message shows none of its attachments
        // until every URL in it has settled, because no layout may depend on when a sibling
        // resolves — three images with one already cached painted as a lone picture and then
        // re-arranged. ⚠⚠ ASKED, never timed, and `allSettled` fails open in every branch: the
        // gate withholds a whole message, so every "not sure" turns a partial failure into a
        // blank one.
        guard !urls.isEmpty, previews.store.allSettled(urls) else { return .none }

        // Re-checked against the SERVER's answer, not the extension guess that prompted the
        // request: an extensionless URL that turns out to be a PNG is inline media, and a `.jpg`
        // that redirects to an HTML login page is not.
        let resolved = urls
            .compactMap { previews.store.preview(for: $0) }
            .filter {
                $0.isAllowed(inlineMedia: previews.inlineMedia, linkPreviews: previews.linkPreviews)
            }

        // ⚠ Only MEDIA may take its address away. A card keeps its URL — its heading is different
        // text from the address, and the address is what you copy.
        //
        // ⚠⚠ And only media that IS what the address points to — `standsInForItsURL`, not the
        // kind. Nothing may be hidden without something rendered in its place: a posterless clip
        // is a grey box with a glyph in it, and taking the address out of the message left an
        // unnamed rectangle with no way to tell what it was, copy it, or reach it. A video's
        // poster is a frame OF the video and does stand in for it; an mp3's is cover art, a
        // picture ABOUT the track, and does not. See `standsInForItsURL` for the whole rule.
        //
        // ⚠ Decided from the DESCRIPTOR, knowingly, even though a poster is the one preview
        // image the server may legitimately 404 (an evicted byte-cache entry under a record that
        // still mints its token) — in which case an address is hidden behind a box that stays
        // empty. Deciding it from whether the bytes actually arrived would be worse, and not
        // marginally: the message's TEXT would then depend on when a download finished, so a row
        // would re-flow mid-scroll — the late-growth class the atomic reveal exists to kill. An
        // image whose bytes fail has always behaved exactly this way, and the box is still
        // tappable, so the link is reachable if not copyable.
        let media = Set(resolved.filter(\.standsInForItsURL).map(\.url))
        let hidden =
            media.isEmpty ? [] : PreviewHiding.hideableUrls(in: message.text, candidates: media)
        return PreviewPlan(hidden: hidden, resolved: resolved)
    }

    private func attach(
        _ plan: PreviewPlan, to cell: CompactCell, context: MessageListContext
    ) {
        guard let previews = context.previews, !plan.resolved.isEmpty else { return }
        cell.onOpenMedia = context.onOpenMedia
        cell.showAttachments(plan.resolved, model: previews.model, traits: context.traits)
    }

    /// The header for a message, or nil when it continues the block above it.
    ///
    /// The time is carried only when the minute differs from the previous message's — that's the
    /// format's whole idea, and why a minute change forces a header even mid-run.
    func header(
        for message: Message, position: RunPosition, at index: Int, context: MessageListContext
    ) -> CompactCell.Header? {
        let previous = previousMessage(before: index, context: context)
        let minuteChanged = changedMinute(message.date, previous?.date)
        guard position.isFirst || minuteChanged else { return nil }

        // No rank glyph on a re-attributed relay line (#277). The name in that header belongs to
        // someone speaking through a bridge, not to a member of this channel — so a hit in the
        // nicklist would be a coincidence of spelling, and it would decorate the visitor with a
        // local user's `@`. The bot's own rank isn't shown either: it isn't the one talking.
        let prefix = message.relayBot == nil
            ? message.nick.flatMap { context.modePrefixes[$0.lowercased()] } ?? ""
            : ""
        // Nil means there's nothing to call this line: server text whose network hasn't resolved
        // yet, most often. An empty header is a blank line above the text with a stray
        // right-aligned timestamp beside it, so there just isn't one.
        guard let name = MessageRenderer.caption(
            message, networkName: context.networkName(message), modePrefix: prefix
        ) else { return nil }
        return CompactCell.Header(
            nick: name,
            color: MessageRenderer.captionColor(message, networkName: context.networkName(message)),
            // Called rather than passed as a function value: an unapplied reference to a
            // main-actor method crosses isolation on its own, which the compiler warns about even
            // though every caller here is already on the main actor.
            time: minuteChanged ? message.date.map { MessageRenderer.compactHeaderTime($0) } : nil,
            // Only when `caption` actually used it: it prefixes a nick and nothing else, so a
            // notice or a network line gets the glyph resolved and then discarded.
            modePrefix: name.hasPrefix(prefix) ? prefix : "",
            // Where a re-attributed relay line came from (#277). Nil on everything else, and nil
            // for a bare `<nick> message` relay too, whose envelope names no source — that line
            // simply reads as the speaker, which is the call the web makes as well.
            relaySource: message.relaySource
        )
    }

    /// Whether the row at `index` is the last of its block — i.e. whatever follows starts a new
    /// one, or there's nothing after it at all.
    ///
    /// Asked of the *next* row rather than tracked as state, because a table builds its cells in
    /// whatever order it likes and a running flag would be wrong on the way back up.
    private func endsBlock(at index: Int, context: MessageListContext) -> Bool {
        guard let next = context.row(index + 1) else { return true }
        // A run of status narration is one block. Without this a netsplit with consolidation off
        // puts three quarters of a line between every join — looser than the old bubble layout
        // managed, which is backwards for the one that exists to be dense.
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

// MARK: - Markers

/// A centered marker row — the unread divider, a day change, the start of history, your own
/// away/back.
///
/// Its own type rather than a case inside the renderer: a break in the flow that names itself is
/// not a message, shares none of a message's layout, and is the part a future second style would
/// be most likely to keep unchanged.
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

    /// The markers. Nil for anything that isn't one.
    ///
    /// Only the unread divider is loud. It's the one the reader is *looking for* — everything
    /// else here is context they read past on the way to it, and a second red row would cost
    /// the first one its meaning.
    static func cell(for row: MessageRow, in tableView: UITableView) -> UITableViewCell? {
        switch row {
        case .unreadDivider:
            cell("New messages", color: Palette.bad, bold: true, in: tableView)
        case .dateDivider(let day):
            cell(MessageRenderer.dayLabel(day), color: Palette.fgMuted, bold: false, in: tableView)
        case .startOfHistory:
            cell("— start of history —", color: Palette.fgFaint, bold: false, in: tableView)
        case .clearedDivider(let at):
            // `.tintColor`, not a `Palette` grey: this is the one marker here that is also a
            // CONTROL, and a row the reader is meant to tap has to look unlike the rows they
            // read past. The tint is what this app already uses for a tappable label
            // (`UserProfileViewController`), so it reads as an action without inventing a
            // token. Still not `Palette.bad` — the unread divider keeps that, and a second
            // loud row would cost the first its meaning (see this method's note).
            cell(
                MessageRenderer.clearedLabel(at: at), color: .tintColor, bold: false,
                in: tableView)
        case .awayDivider(_, let message):
            cell(MessageRenderer.awayLabel(message: message), color: Palette.fgMuted, bold: false, in: tableView)
        case .backDivider(let awayAt, let backAt):
            cell(
                MessageRenderer.backLabel(awayAt: awayAt, backAt: backAt),
                color: Palette.fgMuted, bold: false, in: tableView
            )
        default:
            nil
        }
    }
}
