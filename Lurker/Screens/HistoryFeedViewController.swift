// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// A cross-buffer feed of messages: every row is a line from somewhere else in the app, newest
/// first, grouped by channel+day, tapping one jumps to it.
///
/// Highlights (#13) and Bookmarks are the same screen with different words on it — same REST
/// cursor contract, same `{items, nextBefore}` page, same row shape (the server builds both from
/// one query so a single renderer serves both), same grouping, same paging, same three
/// placeholders. This holds all of that; a subclass supplies where the pages come from and what
/// the empty state says. Search and uploads are the next two that fit here.
///
/// Rendered in the app's own message-list language rather than a separate list style: each row is
/// a real `CompactCell` (the message list's cell), so an entry reads as a slice of the
/// conversation — the author header, the indent, nicks and mIRC colors intact. Grouped by
/// channel+day like iMessage search (`Network/#channel` left, day right). No disclosure chevron:
/// it cost every row the width of an indicator, which a monospaced line notices, and the section
/// header already says these are pointers into conversations elsewhere.
///
/// A REST read, paginated by a `before` cursor rather than streamed — so it fetches on open and
/// pages as you scroll, with pull-to-refresh to pick up anything that changed while it's been
/// sitting open. It deliberately does not subscribe to live state: something arriving in some
/// channel is a push/badge concern, not a reason to mutate a list you're reading.
class HistoryFeedViewController: UITableViewController {
    let viewModel: ChatViewModel

    /// The picked row. The presenter owns jumping to its buffer and dismissing this,
    /// exactly like the buffer switcher's `onSelect`.
    var onSelect: ((HighlightItem) -> Void)?

    /// The cursor, the generation, the hop budget, the rows and which placeholder stands in for
    /// them — every paging rule, pure and tested in LurkerKit. This screen runs the fetches it
    /// hands out and draws what it holds. Built on first use because `reloadSupersedes` is a
    /// subclass override, which `init` can't ask yet.
    private lazy var paging = FeedPaging(supersedes: reloadSupersedes)

    /// All rows, newest-first as the server returns them. `sections` is the channel+day-grouped
    /// view of this that the table renders; `items` stays flat so pagination just appends.
    var items: [HighlightItem] { paging.items }
    private var sections: [Section] = []
    /// The flat `items` index of each section's first row, so `willDisplay` can page in off the
    /// global position regardless of how the channel+day runs happen to be sized.
    private var sectionOffsets: [Int] = []

    /// The page fetch in flight, held so a superseding `reload()` can CANCEL it rather than
    /// merely out-generation it.
    ///
    /// ⚠⚠ The paging generation is still the correctness mechanism — cancellation is
    /// cooperative, and a request that has already returned cannot be recalled — but it only ever
    /// discarded an answer that had already been paid for. Since search became a REST read (#123)
    /// the request itself can be stopped: cancelling this cancels the URLSession task, and the
    /// route checks `req.destroyed` before spending the query. That is the difference between the
    /// server doing the work and throwing it away, and the server never doing it — and an FTS
    /// query runs on the same event loop that services every IRC connection on the cell.
    ///
    /// ⚠ Only ever non-nil for one load: `FeedPaging.isLoading` keeps `loadMore` and a
    /// non-superseding `reload` from overlapping, so this never orphans a task it should have
    /// cancelled.
    private var loadTask: Task<Void, Never>?
    /// A load was abandoned before it landed, so whatever is on screen answers nothing.
    ///
    /// Read by the screens that cancel — the ones whose reload is a different question each time
    /// — to decide whether coming back has to ask again. Cleared by any reload that commits, so
    /// it does not matter whether the reopen path or the appear path gets there first.
    private(set) var loadWasCancelled = false

    private let placeholder = StateView()

    /// Fetch the next page once the user scrolls within this many rows of the bottom, so the
    /// list extends before they hit the end rather than stalling on it.
    private static let prefetchThreshold = 8

    /// A rendered channel+day run: the resolved header text (network name + target + day) over
    /// the rows that share it. The run boundaries and day classification are computed by
    /// `HighlightGrouping` in LurkerKit; this only carries what the table draws.
    private struct Section {
        let networkName: String?
        /// The target as a reader should see it — `Buffer.displayName`, not the raw wire
        /// target. Server logs address themselves as `:server:<host>`, which is a routing
        /// sentinel and not something to print; every other surface in the app names a
        /// buffer through that helper, so this does too rather than growing a second
        /// answer that can drift from the chat title's.
        let displayTarget: String
        let dayLabel: String
        let items: [HighlightItem]
    }

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        super.init(style: .plain)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    // MARK: - Subclass surface

    /// What this feed is called, in the nav bar.
    var feedTitle: String { "" }

    /// One page, newest-first. `before` is the previous page's `next`, nil for the first.
    /// Nil return means the fetch failed (a 401 has already bounced the session).
    func fetchPage(before: FeedCursor?) async -> HighlightsPage? { nil }

    /// The first page, when this feed can answer it without asking anyone — nil (the default)
    /// when it has to ask. Landed inside the `reload()` that asked, before anything is drawn, so
    /// a page that never leaves the device never puts the loading placeholder up first: it would
    /// flash on every keystroke that moves Search into or out of a state it answers itself.
    func localFirstPage() -> HighlightsPage? { nil }

    /// The three placeholder states, in this feed's own words.
    var loadingModel: StateView.Model { StateView.Model(title: "Loading…", isLoading: true) }
    var emptyModel: StateView.Model { StateView.Model(title: "Nothing here") }
    var errorModel: StateView.Model {
        StateView.Model(
            symbol: "exclamationmark.triangle",
            title: "Couldn't load",
            subtitle: "Pull to try again."
        )
    }

    /// Trailing swipe actions for a row, if this feed offers any. Nil (the default) leaves rows
    /// unswipeable. Subclasses that mutate the list from here should call `removeItem(id:)` so
    /// the flat list, the sections and the placeholder all stay in step.
    func trailingSwipeActions(for item: HighlightItem) -> UISwipeActionsConfiguration? { nil }

    /// Whether a `reload()` should replace a *first* page already in flight rather than be
    /// dropped. A page-in or a skip-ahead hop is always replaced, and so is anything when the
    /// reload is a new question — see `FeedPaging.supersedes`.
    ///
    ///
    /// False for the feeds whose reload is idempotent: pulling Highlights twice re-fetches the
    /// same newest page, so the second pull buys nothing and dropping it keeps the refresh
    /// control honest. True for Search, where two reloads are two *different questions* and
    /// the one the user typed last is the only one whose answer they want — dropping it would
    /// leave the list showing results for a prefix of what's in the field. Read once, when the
    /// paging state is built.
    var reloadSupersedes: Bool { false }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = feedTitle
        navigationItem.largeTitleDisplayMode = .always
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        tableView.register(CompactCell.self, forCellReuseIdentifier: CompactCell.reuseID)
        // The same backdrop the message list uses, since a row is supposed to read as a slice of
        // one — on the system background it read as a different surface quoting the conversation.
        tableView.backgroundColor = MessageListRenderer().listBackground
        tableView.register(
            HistoryFeedSectionHeader.self,
            forHeaderFooterViewReuseIdentifier: HistoryFeedSectionHeader.reuseID
        )
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 60
        // The message rows are the visual units; a full-width separator between them would read as
        // a settings table, not a feed. The section headers carry the structure.
        tableView.separatorStyle = .none

        refreshControl = UIRefreshControl()
        refreshControl?.addAction(UIAction { [weak self] _ in self?.reload() }, for: .valueChanged)

        // reload() shows the loading placeholder itself while items is empty (it always is here).
        reload()
    }

    // MARK: - Loading

    /// (Re)fetch from the newest page. Used on first appearance, by pull-to-refresh, and —
    /// where `reloadSupersedes` is set — every time the feed's question changes.
    ///
    /// `newQuestion` is for that last case: the rows, the cursor and the end flag go at once and
    /// the loading placeholder goes up, so nothing on screen claims to answer a question it
    /// wasn't asked (lurker-ios#203; see `FeedPaging.reload`). Every other caller re-asks the
    /// question already on screen, and keeps its rows while it does.
    func reload(newQuestion: Bool = false) {
        // ⚠ Before the paging state is touched. The first `tableView` access below would
        // otherwise load the view mid-reload, and `viewDidLoad` reloads too — a nested reload
        // whose fetch the outer one then replaced in `loadTask` without cancelling, so a live
        // request went untracked. Loaded first, the nested reload finishes before this one
        // starts, and this one supersedes it (or, as a repeat pull, is dropped) like any other.
        loadViewIfNeeded()
        // A repeat pull while the first page is still loading is dropped — but its refresh
        // control is already spinning, so end it here or it spins forever. Feeds whose reloads
        // differ from one another supersede instead; see `reloadSupersedes`.
        guard let fetch = paging.reload(newQuestion: newQuestion) else {
            refreshControl?.endRefreshing()
            return
        }
        loadWasCancelled = false
        // The rows went with the old question, so the table has to stop drawing them now — not
        // when the new answer lands, or a failure would leave them up.
        if newQuestion { rowsChanged() }
        if let page = localFirstPage() {
            // Answered on the spot: whatever was in flight answers an older question.
            loadTask?.cancel()
            loadTask = nil
            land(page, for: fetch)
            return
        }
        renderPlaceholder()
        start(fetch)
    }

    /// Give up on the page in flight, because nobody is waiting for it any more.
    ///
    /// ⚠⚠ For the "user left" case, which a superseding `reload()` does not cover — and which is
    /// at least as common as "user typed another character". A search results screen is built
    /// once and reused (`BufferListViewController.searchResults`), so it is never deallocated and
    /// nothing else would stop the request. Since the whole argument for the REST move is that an
    /// FTS query runs on the event loop servicing every IRC connection on the cell, a query
    /// nobody will read is exactly the one worth not running.
    ///
    /// ⚠⚠ Clears the in-flight bookkeeping, and an earlier version of this did not — it left
    /// `isLoading` set on the theory that "the next `reload()` sets it honestly on the way past".
    /// There isn't always a next reload. `MessageSearchViewController.syncToField` deliberately
    /// does nothing when the field still holds the committed query, which is exactly the state a
    /// screen dismissed mid-search comes back in: `commit` assigns `query` before it reloads. So
    /// reopening showed a spinner nothing would ever resolve, over a list that `isLoading` had
    /// frozen against paging.
    ///
    /// ⚠ `loadWasCancelled` is what gets it out of that, rather than clearing the flags alone: a
    /// cancelled load leaves a question on screen with no answer under it, so somebody has to ask
    /// again. The placeholder is left as it is — this runs on the way out, so nobody sees it, and
    /// an error placeholder would claim a failure when the user simply left.
    ///
    /// ⚠ Guarded on the paging state's `isLoading`, not on `loadTask` being set: the task is left
    /// in place once it lands, so that check always passed, every disappearance counted as a
    /// cancelled load, and coming back from a search result re-ran the query — replacing the
    /// pages the reader had scrolled through with page one.
    func cancelLoad() {
        guard paging.isLoading else { return }
        loadTask?.cancel()
        loadTask = nil
        refreshControl?.endRefreshing()
        // Only a load that left nothing on screen needs asking again: leaving mid page-in, with
        // rows up, must not cost the reader their place when they come back.
        if paging.abandon() { loadWasCancelled = true }
    }

    /// Fetch the next older page, if there is one and we're not already fetching.
    private func loadMore() {
        guard let fetch = paging.loadMore() else { return }
        start(fetch)
    }

    /// Run one page fetch and hand its answer back to the paging state.
    ///
    /// Re-checked once the task actually starts, not only when its answer arrives. The fetch was
    /// stamped synchronously, but the body runs a turn later — and a feed whose question can
    /// change (Search) can have moved on by then. `land` would catch the result and discard it,
    /// which is correct but late: the request has already been made, so a *superseded* page still
    /// costs a full search on the server. For the one read where that cost is the whole concern,
    /// not asking is the point.
    ///
    /// Bailing doesn't strand `isLoading`: the generation can only have moved because a
    /// `reload()` superseded this — which set the flag itself and clears it when its own page
    /// lands — or because `cancelLoad` abandoned it, which cleared it.
    ///
    /// Cancels the task it replaces, so at most one is ever live and tracked. Usually that task
    /// is already done; when a reload replaces a page-in or a hop, cancelling it is what stops
    /// the request (⚠ order relative to the generation bump does not matter — `cancel()` only
    /// sets a flag, and nothing suspended can run until this returns; the generation check
    /// remains the correctness mechanism, this is the cost saving). A skip-ahead hop is started
    /// from inside the task whose page it follows, which this then cancels — harmless, since
    /// that task has nothing left to do once it has landed.
    private func start(_ fetch: FeedPaging.Fetch) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self, paging.isCurrent(fetch) else { return }
            let page = await fetchPage(before: fetch.cursor)
            // ⚠ A cancelled fetch reports nil, which is indistinguishable here from a failure —
            // and `land` would put an error placeholder up for a request the user superseded by
            // typing. The generation check inside it catches this too; this says so where the
            // cancelling happens.
            guard !Task.isCancelled else { return }
            land(page, for: fetch)
        }
    }

    /// A page arrived (nil: the fetch failed): apply it, redraw what it changed, and follow on
    /// with the next page if it filtered to nothing (see `FeedPaging.settle`).
    @MainActor
    private func land(_ page: HighlightsPage?, for fetch: FeedPaging.Fetch) {
        // Superseded: a newer reload owns the list now, and it will report its own result —
        // including ending the refresh control, which belongs to that reload, not this one.
        guard let landing = paging.land(page, for: fetch, visible: visible) else { return }
        if fetch.isFirstPage { refreshControl?.endRefreshing() }
        apply(landing)
    }

    /// Close out a list mutation: redraw the rows if they moved, say what the list now shows, and
    /// start the follow-on page the paging state asked for, if any.
    ///
    /// **Every path that can change `items` ends here** — the first page, an appended page, a
    /// removed row. A round that adds no rows can't page itself: this feed pages off
    /// `willDisplay`, which fires when a cell comes on screen, so nothing new being displayed
    /// means nothing further asked for. `landing.next` is the paging state asking anyway.
    @MainActor
    private func apply(_ landing: FeedPaging.Landing) {
        // Channel+day runs mean an appended page can extend the last section *or* open new ones,
        // so a targeted insert would have to reconcile section moves; a reload is simpler and,
        // since appended rows are below the fold, invisible.
        if landing.rowsChanged { rowsChanged() }
        renderPlaceholder()
        if let next = landing.next { start(next) }
    }

    private func rowsChanged() {
        rebuildSections()
        tableView.reloadData()
    }

    /// The rows an ignore rule doesn't hide (lurker #301).
    ///
    /// These feeds are cross-buffer, so each row carries its own network and target and is
    /// judged against that network's rules rather than one buffer's. Level, channel and
    /// content-pattern rules all apply here, not just whole-identity ones: a `/ignore x PUBLIC`
    /// or a `-pattern` rule is a statement about what you want to read, and a search that
    /// returned exactly what you'd told the client to hide would be the one place the rule
    /// didn't hold.
    ///
    /// Filtered as pages land rather than reactively, because this screen deliberately doesn't
    /// subscribe to live state (see the class doc) — a rule created while the list is open
    /// takes effect on the next pull-to-refresh, which is also when everything else about
    /// these rows would be re-read.
    private func visible(_ items: [HighlightItem]) -> [HighlightItem] {
        let ignores = viewModel.state.ignores
        return items.filter { item in
            !ignores.isMessageHidden(
                networkId: item.networkId, message: item.message, target: item.target
            )
        }
    }

    /// Drop one row from the feed, rebuilding the grouped view around it.
    ///
    /// Addressed by **message id, not index path**. A swipe action fires against the index path
    /// the swipe opened at, and the list can be replaced underneath it in between: pull to
    /// refresh, then act on the still-open swipe, and a first page has already swapped `items`
    /// wholesale. Resolving the position again at that point deletes whatever now occupies that
    /// slot — some other bookmark — while the unsave correctly went to the one the user swiped.
    /// An id can't drift like that, and a row that's already gone is a no-op.
    ///
    /// A full reload rather than a row deletion: removing the last row of a channel+day run has
    /// to take the section header with it, which is a section delete whose index depends on the
    /// regrouping — the same reason an appended page reloads. The placeholder is re-evaluated
    /// too, so emptying the list lands on the empty state rather than a blank table.
    @MainActor
    func removeItem(id messageId: Int) {
        guard let landing = paging.remove(messageId: messageId) else { return }
        apply(landing)
    }

    // MARK: - Sections (channel + day runs)

    /// Fold the flat, newest-first list into the channel+day runs the table draws. The run
    /// boundaries and day classification live in `HighlightGrouping` (pure + tested in
    /// LurkerKit); this maps each group to its rendered header — the roster-resolved network
    /// name, the target, and the formatted day.
    private func rebuildSections() {
        let groups = HighlightGrouping.group(items, now: Date())
        sections = groups.map { group in
            let item = group.items[0]
            let resolvedNetworkName = networkName(for: item)
            return Section(
                networkName: resolvedNetworkName,
                displayTarget: viewModel.state.buffer(for: item.bufferKey)
                    .displayName(networkName: resolvedNetworkName),
                dayLabel: Self.dayLabel(group.day),
                items: group.items
            )
        }
        sectionOffsets = groups.map(\.offset)
    }

    /// Format a `HighlightDay` for the header's trailing stamp — Today / Yesterday / a short
    /// date (with the year only when it isn't the current one) / "Earlier" for undated rows.
    private static func dayLabel(_ day: HighlightDay) -> String {
        switch day {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .undated: return "Earlier"
        case .on(let date):
            let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
            return (sameYear ? sameYearFormatter : fullDateFormatter).string(from: date)
        }
    }

    private static let sameYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMdyyyy")
        return formatter
    }()

    // MARK: - Placeholder

    /// Draw whichever placeholder the paging state says stands in for the rows, in this feed's
    /// own words — or none, when there are rows.
    private func renderPlaceholder() {
        let model: StateView.Model
        switch paging.placeholder {
        case nil:
            tableView.backgroundView = nil
            return
        case .loading: model = loadingModel
        case .empty: model = emptyModel
        case .error: model = errorModel
        }
        placeholder.configure(model)
        tableView.backgroundView = placeholder
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].items.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: CompactCell.reuseID, for: indexPath) as! CompactCell
        let section = sections[indexPath.section]
        let item = section.items[indexPath.row]
        // Every row is its own block — they come from different buffers and hours — so each gets a
        // header and each carries its time, rather than the message list's "only when the minute
        // changed" rule, which means nothing across unrelated conversations.
        //
        // `highlighted: false` keeps the matched wash off: in Highlights every row matched, so it
        // would be a monotone wall, and in Bookmarks the wash would claim a mention that isn't
        // what put the row there. `interactive: false` so a tap reaches the row's jump instead of
        // the text view hit-testing for a link. `section.networkName` is the roster-resolved name,
        // so a system/motd row on an older server (no networkName on the row) still names its
        // network.
        //
        // No *nick* for a `/me` or an activity line, exactly as the message list does it: those
        // print their actor inside the sentence, so naming them again above `* alice waves` would
        // say it twice. `isBubble` is the same test the list routes on — "does this line need to
        // be told who said it".
        //
        // The header itself stays, carrying the time alone. In the list a header-less row can go
        // without a stamp because the rows around it have one; here every row is a standalone
        // entry from a different buffer and hour, and the section header gives only the day.
        // A line from a marked relay bot reads as the person inside its envelope, as it does in
        // its buffer (#277) — and before replies are presented, which judge the line as it reads.
        // A reaction row is the reactor's, never relayed.
        let state = viewModel.state
        let line = item.reaction == nil
            ? state.relayBots.reattributing([item.message], networkId: item.networkId).first ?? item.message
            : item.message
        let name = line.type.isBubble
            ? MessageRenderer.caption(line, networkName: section.networkName)
            : nil
        let time = line.date.map { MessageRenderer.compactHeaderTime($0) }
        // A reaction to one of your lines (iOS #183): the reactor heads the row, as the speaker
        // does a highlight, and the body says what they reacted and to which line — the web's
        // `bob | 👍 on "…"`.
        // A reply reads as it does in its buffer (lurker#998): its quote above, its address gone.
        // Static here — the row's tap jumps to the reply, where the quote is live again.
        let shown = item.reaction == nil
            ? Replies.presenting(
                [line], networkId: item.networkId, target: item.target,
                ignores: state.ignores, relayBots: state.relayBots,
                ownNick: item.networkId.flatMap { state.networks[$0]?.nick }
            ).first ?? line
            : line
        let body = item.reaction.map { Self.reactionBody($0, traits: traitCollection) }
            ?? MessageRenderer.renderCompactBody(shown, traits: traitCollection)
        cell.configure(
            body,
            header: name == nil && time == nil ? nil : CompactCell.Header(
                nick: name ?? "",
                color: MessageRenderer.captionColor(line, networkName: section.networkName),
                time: time,
                relaySource: line.relaySource
            ),
            startsBlock: true,
            endsBlock: true,
            interactive: false,
            reply: shown.replyTo == nil ? nil : CompactCell.ReplyLine(quote: shown.replyQuote, onJump: nil),
            indentsBody: shown.type != .action,
            traits: traitCollection
        )
        // Tapping jumps, so the row has to acknowledge the touch. `CompactCell` defaults to no
        // selection style because a message list isn't a list of choices; this one is, and with
        // the disclosure chevron gone this is the only thing marking a row as tappable.
        cell.selectionStyle = .default
        return cell
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let header = tableView.dequeueReusableHeaderFooterView(
            withIdentifier: HistoryFeedSectionHeader.reuseID
        ) as! HistoryFeedSectionHeader
        let sec = sections[section]
        // A server log's display name IS its network's, so joining the two would read
        // "Libera/Libera". Deduped rather than branching on buffer kind here — the kind is
        // already what produced the name.
        let parts = [sec.networkName, sec.displayTarget].compactMap { $0 }
        let location = parts.count == 2 && parts[0] == parts[1]
            ? parts[0]
            : parts.joined(separator: "/")
        header.configure(location: location, day: sec.dayLabel)
        return header
    }

    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        // Page in off the global position, so the threshold means "N rows from the true end"
        // however the channel+day runs are sized.
        guard indexPath.section < sectionOffsets.count else { return }
        let globalIndex = sectionOffsets[indexPath.section] + indexPath.row
        if globalIndex >= items.count - Self.prefetchThreshold { loadMore() }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelect?(sections[indexPath.section].items[indexPath.row])
    }

    override func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard indexPath.section < sections.count,
              indexPath.row < sections[indexPath.section].items.count
        else { return nil }
        return trailingSwipeActions(for: sections[indexPath.section].items[indexPath.row])
    }

    /// `👍 on "your line"`, the value in the body's ink and the rest muted, indented like a body.
    private static func reactionBody(_ reaction: FeedReaction, traits: UITraitCollection) -> NSAttributedString {
        let font = MessageRenderer.compactFont(compatibleWith: traits)
        let indent = MessageRenderer.compactIndent(compatibleWith: traits)
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = indent
        paragraph.headIndent = indent
        paragraph.lineSpacing = MessageRenderer.compactLineGap
        let text = NSMutableAttributedString(
            string: reaction.value,
            attributes: [.font: font, .foregroundColor: Palette.fg, .paragraphStyle: paragraph]
        )
        let line = reaction.lineText.map { IRCFormatting.strip($0) } ?? ""
        text.append(NSAttributedString(
            string: " on \u{201C}\(line)\u{201D}",
            attributes: [.font: font, .foregroundColor: Palette.fgMuted, .paragraphStyle: paragraph]
        ))
        return text
    }

    /// The network's name for a row — the server-resolved one, falling back to the client's own
    /// roster if the row didn't carry it (an older server).
    private func networkName(for item: HighlightItem) -> String? {
        item.networkName ?? item.networkId.flatMap { viewModel.state.networks[$0]?.name }
    }
}

/// A channel+day section header: `Network/#channel` on the leading edge, the day on the
/// trailing edge, on one baseline — iMessage search's per-group header. A
/// `UITableViewHeaderFooterView` (not a bare view) so its content margins track the table's,
/// lining the text up with the bubbles' own leading margin.
private final class HistoryFeedSectionHeader: UITableViewHeaderFooterView {
    static let reuseID = "historyFeedHeader"

    private let locationLabel = UILabel()
    private let dayLabel = UILabel()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)

        locationLabel.font = UIFont.preferredFont(forTextStyle: .subheadline).semibold
        locationLabel.textColor = Palette.fg
        locationLabel.adjustsFontForContentSizeCategory = true
        locationLabel.lineBreakMode = .byTruncatingTail
        locationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        dayLabel.font = .preferredFont(forTextStyle: .subheadline)
        // The palette's, not the system's: this header sits on the feed's themed canvas
        // (`MessageListRenderer.listBackground`), same as the rows it groups.
        dayLabel.textColor = Palette.fgMuted
        dayLabel.adjustsFontForContentSizeCategory = true
        dayLabel.textAlignment = .right
        dayLabel.setContentHuggingPriority(.required, for: .horizontal)
        dayLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [locationLabel, dayLabel])
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .firstBaseline
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    func configure(location: String, day: String) {
        locationLabel.text = location
        dayLabel.text = day
    }
}
