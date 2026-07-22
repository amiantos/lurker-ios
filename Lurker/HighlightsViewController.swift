// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// The recent-highlights list (#13): every line a highlight rule matched, newest first,
/// across every buffer at once. A read surface, not a picker — the row shows the match
/// itself (who, where, what), so you can catch up on mentions without opening each channel;
/// tapping one jumps to that conversation.
///
/// Rendered in the app's own message-list language rather than a separate list style: each
/// hit is a real `BubbleCell` (the message list's cell), so a highlight reads as a slice of
/// the conversation — leading/filled for others, trailing for you, nicks and mIRC colors
/// intact. Grouped by channel+day like iMessage search (`Network/#channel` left, day right),
/// with a chevron for the jump. The highlight wash is suppressed here: every row matched, so
/// it would only be a monotone wall — this is exactly the shape search and bookmarks reuse.
///
/// Highlights are a REST read (`GET /api/highlights`), paginated by a `before` cursor rather
/// than streamed — so this fetches on open and pages as you scroll, with pull-to-refresh to
/// pick up anything that matched while it's been sitting open. It deliberately does not
/// subscribe to live state: a highlight arriving in some channel is a push/badge concern,
/// not a reason to mutate a list you're reading.
final class HighlightsViewController: UITableViewController {
    private let viewModel: ChatViewModel

    /// The picked highlight. The presenter owns jumping to its buffer and dismissing this,
    /// exactly like the buffer switcher's `onSelect`.
    var onSelect: ((HighlightItem) -> Void)?

    /// All rows, newest-first as the server returns them. `sections` is the channel+day-grouped
    /// view of this that the table renders; `items` stays flat so pagination just appends.
    private var items: [HighlightItem] = []
    private var sections: [Section] = []
    /// The flat `items` index of each section's first row, so `willDisplay` can page in off the
    /// global position regardless of how the channel+day runs happen to be sized.
    private var sectionOffsets: [Int] = []

    /// The next-page cursor from the last response; nil once the server has no more.
    private var nextBefore: Int?
    private var reachedEnd = false
    private var isLoading = false
    /// The first fetch failed with nothing to show — distinct from an empty result, so the
    /// placeholder can offer a retry rather than claim there are no highlights.
    private var loadFailed = false

    private let placeholder = StateView()

    /// Fetch the next page once the user scrolls within this many rows of the bottom, so the
    /// list extends before they hit the end rather than stalling on it.
    private static let prefetchThreshold = 8

    /// A rendered channel+day run: the resolved header text (network name + target + day) over
    /// the matches that share it. The run boundaries and day classification are computed by
    /// `HighlightGrouping` in LurkerKit; this only carries what the table draws.
    private struct Section {
        let networkName: String?
        let target: String
        let dayLabel: String
        let items: [HighlightItem]
    }

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        super.init(style: .plain)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Highlights"
        navigationItem.largeTitleDisplayMode = .always
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        tableView.register(BubbleCell.self, forCellReuseIdentifier: BubbleCell.reuseID)
        tableView.register(HighlightSectionHeader.self, forHeaderFooterViewReuseIdentifier: HighlightSectionHeader.reuseID)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 60
        // The bubbles are the visual units; a full-width separator between them would read as
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
            let page = await viewModel.fetchHighlights(before: nil)
            await handleFirstPage(page)
        }
    }

    /// Fetch the next older page, if there is one and we're not already fetching.
    private func loadMore() {
        guard !isLoading, !reachedEnd, let cursor = nextBefore else { return }
        isLoading = true
        Task { [weak self] in
            guard let self else { return }
            let page = await viewModel.fetchHighlights(before: cursor)
            await appendPage(page)
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

    // MARK: - Sections (channel + day runs)

    /// Fold the flat, newest-first list into the channel+day runs the table draws. The run
    /// boundaries and day classification live in `HighlightGrouping` (pure + tested in
    /// LurkerKit); this maps each group to its rendered header — the roster-resolved network
    /// name, the target, and the formatted day.
    private func rebuildSections() {
        let groups = HighlightGrouping.group(items, now: Date())
        sections = groups.map { group in
            Section(
                networkName: networkName(for: group.items[0]),
                target: group.target,
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
        case .loading:
            model = StateView.Model(title: "Loading highlights…", isLoading: true)
        case .empty:
            model = StateView.Model(
                symbol: "at",
                title: "No recent highlights",
                subtitle: "Messages that match your highlight rules show up here."
            )
        case .error:
            model = StateView.Model(
                symbol: "exclamationmark.triangle",
                title: "Couldn't load highlights",
                subtitle: "Pull to try again."
            )
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
        let cell = tableView.dequeueReusableCell(withIdentifier: BubbleCell.reuseID, for: indexPath) as! BubbleCell
        let section = sections[indexPath.section]
        let item = section.items[indexPath.row]
        // .solo — each match is its own run — and showsHighlight:false so the wash stays off
        // (every row matched, so it would be a monotone wall). The chevron marks the jump.
        // `section.networkName` is the roster-resolved name, so a system/motd highlight on an
        // older server (no networkName on the row) still captions its network.
        cell.configure(item.message, position: .solo, networkName: section.networkName, showsHighlight: false)
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let header = tableView.dequeueReusableHeaderFooterView(
            withIdentifier: HighlightSectionHeader.reuseID
        ) as! HighlightSectionHeader
        let sec = sections[section]
        let location = [sec.networkName, sec.target].compactMap { $0 }.joined(separator: "/")
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
private final class HighlightSectionHeader: UITableViewHeaderFooterView {
    static let reuseID = "highlightHeader"

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
