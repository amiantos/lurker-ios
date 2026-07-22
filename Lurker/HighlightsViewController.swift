// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// The recent-highlights list (#13): every line a highlight rule matched, newest first,
/// across every buffer at once. A read surface, not a picker — the row shows the match
/// itself (who, where, what), so you can catch up on mentions without opening each channel;
/// tapping one jumps to that conversation.
///
/// Styled the way Mail / Notification Center do a cross-conversation feed: inset-grouped
/// cards, day-grouped sections, and a large title. Each row follows the web client's own
/// shape — a `Network/#channel` + time metadata bar, then the match as `<nick> message`.
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

    /// All rows, newest-first as the server returns them. `sections` is the day-bucketed
    /// view of this that the table renders; `items` stays flat so pagination just appends.
    private var items: [HighlightItem] = []
    private var sections: [Section] = []

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

    private struct Section {
        let title: String
        let items: [HighlightItem]
    }

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        super.init(style: .insetGrouped)
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
        tableView.register(HighlightCell.self, forCellReuseIdentifier: HighlightCell.reuseID)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 84

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
        // Day-bucketed sections mean an appended page can extend the last section *or* open
        // new ones, so a targeted insert would have to reconcile section moves; a reload is
        // simpler and, since the added rows are below the fold, invisible.
        tableView.reloadData()
    }

    // MARK: - Sections (day buckets)

    /// Bucket the flat, newest-first list into the day groups Mail and Notification Center
    /// use. Items arrive newest-first and each bucket is strictly older than the last, so a
    /// single pass keeps both the sections and the rows within them in order.
    private func rebuildSections() {
        let calendar = Calendar.current
        let now = Date()
        var buckets: [[HighlightItem]] = Array(repeating: [], count: Self.bucketTitles.count)
        for item in items { buckets[Self.bucket(item.message.date, calendar: calendar, now: now)].append(item) }
        sections = zip(Self.bucketTitles, buckets).compactMap { title, rows in
            rows.isEmpty ? nil : Section(title: title, items: rows)
        }
    }

    private static let bucketTitles = ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "Earlier"]

    /// The index into `bucketTitles` for a date. A missing date (an event with no readable
    /// time) sinks to "Earlier" rather than claiming to be recent.
    private static func bucket(_ date: Date?, calendar: Calendar, now: Date) -> Int {
        guard let date else { return bucketTitles.count - 1 }
        if calendar.isDateInToday(date) { return 0 }
        if calendar.isDateInYesterday(date) { return 1 }
        let days = calendar.dateComponents([.day], from: date, to: now).day ?? .max
        if days < 7 { return 2 }
        if days < 30 { return 3 }
        return 4
    }

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

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].items.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: HighlightCell.reuseID, for: indexPath) as! HighlightCell
        let item = sections[indexPath.section].items[indexPath.row]
        cell.configure(item, networkName: networkName(for: item))
        return cell
    }

    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        // Page in when the last section's tail comes into view.
        guard indexPath.section == sections.count - 1 else { return }
        if indexPath.row >= sections[indexPath.section].items.count - Self.prefetchThreshold { loadMore() }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelect?(sections[indexPath.section].items[indexPath.row])
    }

    /// The network's name for the context line — the server-resolved one, falling back to the
    /// client's own roster if the row didn't carry it (an older server).
    private func networkName(for item: HighlightItem) -> String? {
        item.networkName ?? item.networkId.flatMap { viewModel.state.networks[$0]?.name }
    }
}

/// One highlight, laid out the way the web client does it: a metadata top bar — the location
/// (`Network/#channel`) on the left, the time on the right — then the matched line itself in
/// IRC's own `<nick> message` form, the nick in its color and the body as it reads in-buffer
/// (mIRC formatting and colors preserved).
private final class HighlightCell: UITableViewCell {
    static let reuseID = "highlight"

    private let locationLabel = UILabel()
    private let timeLabel = UILabel()
    private let messageLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        // Location and time are one metadata bar, so they share the font *and* the color —
        // same caption, same muted tertiary — rather than reading as two different styles.
        let caption = UIFont.preferredFont(forTextStyle: .caption1)
        locationLabel.font = caption
        locationLabel.textColor = .tertiaryLabel
        styleLabel(locationLabel)
        locationLabel.lineBreakMode = .byTruncatingTail
        locationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        timeLabel.font = caption
        timeLabel.textColor = .tertiaryLabel
        styleLabel(timeLabel)
        timeLabel.textAlignment = .right
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.textColor = .label
        styleLabel(messageLabel)
        messageLabel.numberOfLines = 3 // the nick rides inline now, so give the body a line more

        // Metadata bar: location grows, time hugs the trailing edge, both on one baseline.
        let header = UIStackView(arrangedSubviews: [locationLabel, timeLabel])
        header.axis = .horizontal
        header.spacing = 8
        header.alignment = .firstBaseline

        let column = UIStackView(arrangedSubviews: [header, messageLabel])
        column.axis = .vertical
        column.spacing = 7
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)

        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    /// Common label setup: Dynamic Type + one line unless overridden.
    private func styleLabel(_ label: UILabel) {
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
    }

    func configure(_ item: HighlightItem, networkName: String?) {
        let message = item.message
        timeLabel.text = Self.relativeTime(message.date)
        // "Libera/#lurker" — the network then the buffer, matching the web's metadata bar.
        // Falls back to the raw target if the network can't be named.
        locationLabel.text = [networkName, item.target].compactMap { $0 }.joined(separator: "/")

        // The matched line in IRC's `<nick> message` form, then the body as it reads
        // in-buffer (mIRC formatting and colors preserved). Only the nick is colored — the
        // `<>` delimiters stay muted so the name is what carries the color. A notice keeps its
        // `-nick-` mark and an action its `* nick`, since those aren't `<nick>` lines.
        let base = UIFont.preferredFont(forTextStyle: .subheadline)
        let delimiter: [NSAttributedString.Key: Any] = [.font: base, .foregroundColor: UIColor.secondaryLabel]
        let name: [NSAttributedString.Key: Any] = [.font: base, .foregroundColor: MessageRenderer.nickColor(message)]
        let nick = message.nick ?? item.target
        let (open, close): (String, String)
        switch message.type {
        case .notice: (open, close) = ("-", "- ")
        case .action: (open, close) = ("* ", " ")
        default: (open, close) = ("<", "> ")
        }
        let line = NSMutableAttributedString()
        line.append(NSAttributedString(string: open, attributes: delimiter))
        line.append(NSAttributedString(string: nick, attributes: name))
        line.append(NSAttributedString(string: close, attributes: delimiter))
        line.append(MessageRenderer.renderBubble(message))
        messageLabel.attributedText = line

        accessibilityLabel = [locationLabel.text, line.string, timeLabel.text]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        messageLabel.attributedText = nil
    }

    /// A short "how long ago" for the header — a recent-mentions list reads better in
    /// relative time ("8m ago") than a bare clock stamp with no date, since a highlight can
    /// be days old. Nil dates (an event with no readable time) simply show nothing.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static func relativeTime(_ date: Date?) -> String? {
        guard let date else { return nil }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
