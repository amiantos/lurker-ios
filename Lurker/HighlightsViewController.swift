// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// The recent-highlights list (#13): every line a highlight rule matched, newest first,
/// across every buffer at once. A read surface, not a picker — the row shows the match
/// itself (who, where, what), so you can catch up on mentions without opening each channel;
/// tapping one jumps to that conversation for context.
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

    private var items: [HighlightItem] = []
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

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        super.init(style: .plain)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Highlights"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        tableView.register(HighlightCell.self, forCellReuseIdentifier: HighlightCell.reuseID)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        // A highlight is a self-contained card; a full-width separator between them reads as
        // a table of settings rather than a feed. The cell draws its own vertical rhythm.
        tableView.separatorStyle = .none
        tableView.allowsSelectionDuringEditing = false

        refreshControl = UIRefreshControl()
        refreshControl?.addAction(UIAction { [weak self] _ in self?.reload() }, for: .valueChanged)

        renderPlaceholder(.loading)
        reload()
    }

    // MARK: - Loading

    /// (Re)fetch from the newest page. Used on first appearance and by pull-to-refresh.
    private func reload() {
        guard !isLoading else { return }
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
        tableView.reloadData()
        renderPlaceholderForCurrentState()
    }

    @MainActor
    private func appendPage(_ page: HighlightsPage?) {
        isLoading = false
        guard let page else {
            // A failed page-in leaves what we have and just stops paging; the user can pull
            // to refresh. Re-arm on the next scroll rather than latching `reachedEnd`.
            return
        }
        let start = items.count
        items.append(contentsOf: page.items)
        nextBefore = page.nextBefore
        reachedEnd = !page.hasMore
        guard !page.items.isEmpty else { return }
        let indexPaths = (start..<items.count).map { IndexPath(row: $0, section: 0) }
        tableView.insertRows(at: indexPaths, with: .none)
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

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: HighlightCell.reuseID, for: indexPath) as! HighlightCell
        cell.configure(items[indexPath.row], networkName: networkName(for: items[indexPath.row]))
        return cell
    }

    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if indexPath.row >= items.count - Self.prefetchThreshold { loadMore() }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelect?(items[indexPath.row])
    }

    /// The network's name for the context line — the server-resolved one, falling back to the
    /// client's own roster if the row didn't carry it (an older server).
    private func networkName(for item: HighlightItem) -> String? {
        item.networkName ?? item.networkId.flatMap { viewModel.state.networks[$0]?.name }
    }
}

/// One highlight: a context line naming where it happened and when, then the matched message
/// itself rendered the way it looks in its buffer (author in their color, body with mIRC
/// formatting). Two-line layout, one font size — the context recedes on color and the
/// message carries the weight, per the app's single-size rule.
private final class HighlightCell: UITableViewCell {
    static let reuseID = "highlight"

    private let contextLabel = UILabel()
    private let timeLabel = UILabel()
    private let messageLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear

        let caption = UIFont.preferredFont(forTextStyle: .caption1)
        contextLabel.font = caption
        contextLabel.textColor = .secondaryLabel
        contextLabel.adjustsFontForContentSizeCategory = true
        contextLabel.lineBreakMode = .byTruncatingTail
        contextLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        timeLabel.font = caption
        timeLabel.textColor = .tertiaryLabel
        timeLabel.adjustsFontForContentSizeCategory = true
        timeLabel.textAlignment = .right
        // The time is short and fixed-ish; let the context line give way first.
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.textColor = .label
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.numberOfLines = 4 // enough to read the match; a wall of text still truncates

        let header = UIStackView(arrangedSubviews: [contextLabel, timeLabel])
        header.axis = .horizontal
        header.spacing = 8
        header.alignment = .firstBaseline

        let column = UIStackView(arrangedSubviews: [header, messageLabel])
        column.axis = .vertical
        column.spacing = 3
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)

        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            column.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    func configure(_ item: HighlightItem, networkName: String?) {
        let message = item.message
        // "Libera · #lurker" — the network, then the buffer it matched in. Falls back to the
        // raw target if we can't name the network, rather than printing a lone middot.
        contextLabel.text = [networkName, item.target].compactMap { $0 }.joined(separator: " · ")
        timeLabel.text = Self.relativeTime(message.date)

        // The match rendered as it reads in its buffer: the author in their caption color,
        // then the body with mIRC formatting and colors. Reuses MessageRenderer so a highlight
        // and its in-buffer twin never drift apart.
        let line = NSMutableAttributedString()
        if let author = MessageRenderer.caption(message, networkName: networkName) {
            let base = UIFont.preferredFont(forTextStyle: .subheadline)
            line.append(NSAttributedString(string: author, attributes: [
                .font: base.semibold,
                .foregroundColor: MessageRenderer.captionColor(message, networkName: networkName),
            ]))
            line.append(NSAttributedString(string: "  ", attributes: [.font: base]))
        }
        line.append(MessageRenderer.renderBubble(message))
        messageLabel.attributedText = line

        accessibilityLabel = [contextLabel.text, line.string, timeLabel.text]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        messageLabel.attributedText = nil
    }

    /// A short "how long ago" for the header — a recent-mentions list reads better in
    /// relative time ("2h ago") than a bare clock stamp with no date, since a highlight can
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
