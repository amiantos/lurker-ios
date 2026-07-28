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

    /// All rows, newest-first as the server returns them. `sections` is the channel+day-grouped
    /// view of this that the table renders; `items` stays flat so pagination just appends.
    private(set) var items: [HighlightItem] = []
    private var sections: [Section] = []
    /// The flat `items` index of each section's first row, so `willDisplay` can page in off the
    /// global position regardless of how the channel+day runs happen to be sized.
    private var sectionOffsets: [Int] = []

    /// The next-page cursor from the last response; nil once the server has no more.
    private var nextBefore: Int?
    private var reachedEnd = false
    private var isLoading = false
    /// The first fetch failed with nothing to show — distinct from an empty result, so the
    /// placeholder can offer a retry rather than claim the feed is empty.
    private var loadFailed = false

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
        /// answer that can drift from the title pill's.
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

    /// One page, newest-first. `before` is the previous page's `nextBefore`, nil for the first.
    /// Nil return means the fetch failed (a 401 has already bounced the session).
    func fetchPage(before: Int?) async -> HighlightsPage? { nil }

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

    /// (Re)fetch from the newest page. Used on first appearance and by pull-to-refresh.
    private func reload() {
        // A pull-to-refresh that lands while a page is already loading is dropped — but its
        // refresh control is already spinning, so end it here or it spins forever.
        guard !isLoading else { refreshControl?.endRefreshing(); return }
        isLoading = true
        loadFailed = false
        // Only show the full-screen spinner on a cold load; a refresh keeps the list up with
        // the refresh control's own spinner rather than blanking what's already there.
        if items.isEmpty { renderPlaceholder(.loading) }
        Task { [weak self] in
            guard let self else { return }
            let page = await fetchPage(before: nil)
            handleFirstPage(page)
        }
    }

    /// Fetch the next older page, if there is one and we're not already fetching.
    private func loadMore() {
        guard !isLoading, !reachedEnd, let cursor = nextBefore else { return }
        isLoading = true
        Task { [weak self] in
            guard let self else { return }
            let page = await fetchPage(before: cursor)
            appendPage(page)
        }
    }

    @MainActor
    private func handleFirstPage(_ page: HighlightsPage?) {
        isLoading = false
        refreshControl?.endRefreshing()
        guard let page else {
            loadFailed = true
            if items.isEmpty { renderPlaceholder(.error) }
            return
        }
        items = page.items
        nextBefore = page.nextBefore
        reachedEnd = !page.hasMore
        rebuildSections()
        tableView.reloadData()
        renderPlaceholderForCurrentState()
    }

    @MainActor
    private func appendPage(_ page: HighlightsPage?) {
        isLoading = false
        guard let page else {
            // A failed page-in leaves what we have and just stops paging; the user can pull
            // to refresh. Don't latch `reachedEnd` — the next scroll re-arms `loadMore`.
            return
        }
        guard !page.items.isEmpty else {
            nextBefore = page.nextBefore
            reachedEnd = !page.hasMore
            return
        }
        items.append(contentsOf: page.items)
        nextBefore = page.nextBefore
        reachedEnd = !page.hasMore
        rebuildSections()
        // Channel+day runs mean an appended page can extend the last section *or* open new
        // ones, so a targeted insert would have to reconcile section moves; a reload is
        // simpler and, since the added rows are below the fold, invisible.
        tableView.reloadData()
    }

    /// Drop one row from the feed, rebuilding the grouped view around it.
    ///
    /// Addressed by **message id, not index path**. A swipe action fires against the index path
    /// the swipe opened at, and the list can be replaced underneath it in between: pull to
    /// refresh, then act on the still-open swipe, and `handleFirstPage` has already swapped
    /// `items` wholesale. Resolving the position again at that point deletes whatever now
    /// occupies that slot — some other bookmark — while the unsave correctly went to the one
    /// the user swiped. An id can't drift like that, and a row that's already gone is a no-op.
    ///
    /// A full reload rather than a row deletion: removing the last row of a channel+day run has
    /// to take the section header with it, which is a section delete whose index depends on the
    /// regrouping — the same reason `appendPage` reloads. The placeholder is re-evaluated too,
    /// so emptying the list lands on the empty state rather than a blank table.
    @MainActor
    func removeItem(id messageId: Int) {
        guard let index = items.firstIndex(where: { $0.message.id == messageId }) else { return }
        items.remove(at: index)
        rebuildSections()
        tableView.reloadData()
        renderPlaceholderForCurrentState()
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

    private enum Placeholder { case loading, empty, error }

    private func renderPlaceholderForCurrentState() {
        if items.isEmpty { renderPlaceholder(loadFailed ? .error : .empty) } else { hidePlaceholder() }
    }

    private func renderPlaceholder(_ kind: Placeholder) {
        let model: StateView.Model
        switch kind {
        case .loading: model = loadingModel
        case .empty: model = emptyModel
        case .error: model = errorModel
        }
        placeholder.configure(model)
        tableView.backgroundView = placeholder
    }

    private func hidePlaceholder() {
        tableView.backgroundView = nil
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
        let name = item.message.type.isBubble
            ? MessageRenderer.caption(item.message, networkName: section.networkName)
            : nil
        let time = item.message.date.map { MessageRenderer.compactHeaderTime($0) }
        cell.configure(
            MessageRenderer.renderCompactBody(item.message, traits: traitCollection),
            header: name == nil && time == nil ? nil : CompactCell.Header(
                nick: name ?? "",
                color: MessageRenderer.captionColor(item.message, networkName: section.networkName),
                time: time
            ),
            startsBlock: true,
            endsBlock: true,
            interactive: false,
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
        locationLabel.textColor = .label
        locationLabel.adjustsFontForContentSizeCategory = true
        locationLabel.lineBreakMode = .byTruncatingTail
        locationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        dayLabel.font = .preferredFont(forTextStyle: .subheadline)
        dayLabel.textColor = .secondaryLabel
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
