// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine
import LurkerKit
import UIKit

/// The buffer picker, summoned from the title pill or a swipe in from the left edge.
///
/// A quick switcher rather than a directory: the buffers you actually move between are a
/// handful you keep returning to, so recents and pins come first at a size you can hit
/// without looking, and the full grouped roster sits underneath, denser, for the times you
/// want something you haven't touched in a week.
///
/// "Denser" is spacing, not type size — one font size app-wide. The hierarchy is row
/// height, a network subtitle on the promoted rows, and order.
///
/// It reports the pick through `onSelect` and doesn't know what happens next; the chat
/// screen swaps itself out.
final class BufferSwitcherViewController: UITableViewController {
    private let viewModel: ChatViewModel
    private var cancellables = Set<AnyCancellable>()

    /// Called with the picked buffer. The presenter owns hydrating it and dismissing this.
    var onSelect: ((Buffer) -> Void)?

    /// How many recents to promote. A quick switcher that lists thirty "recent" buffers is
    /// just the roster again — this is a display cap, not a limit on what's remembered.
    private static let recentLimit = 5

    private struct Row {
        let buffer: Buffer
        /// Which network this buffer is on, shown on promoted rows where the row has been
        /// lifted out of its network's section and would otherwise be ambiguous.
        let subtitle: String?
        /// Only the Lurker row carries a light; see `buildSections`.
        let light: StatusLight?
        let compact: Bool
    }

    private struct Section {
        let title: String?
        let rows: [Row]
    }

    private var state = ChatState()
    private var sections: [Section] = []

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Buffers"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            }
        )
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "buffer")

        // The list depends on networks, buffers, and connection state — a message arriving
        // in some channel shouldn't rebuild it (badge counts arrive as read-state updates,
        // which do change `buffers`). `connection` and `reachable` are here because the
        // Lurker row renders them.
        viewModel.statePublisher
            .removeDuplicates {
                $0.networks == $1.networks
                    && $0.buffers == $1.buffers
                    && $0.connection == $1.connection
                    && $0.reachable == $1.reachable
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.apply(state) }
            .store(in: &cancellables)
        apply(viewModel.state)
    }

    private func apply(_ state: ChatState) {
        self.state = state
        sections = buildSections(state)
        tableView.reloadData()
    }

    // MARK: - Sections

    private func buildSections(_ state: ChatState) -> [Section] {
        var byNetwork: [Int: [Buffer]] = [:]
        var system: Buffer?
        for buffer in state.buffers.values {
            if let networkId = buffer.networkId {
                byNetwork[networkId, default: []].append(buffer)
            } else {
                system = buffer
            }
        }

        var sections: [Section] = []

        // The Lurker row, carrying the socket light — the same signal the title pill shows
        // on the system buffer. It has to live here too: the pill is on the chat screen,
        // and this sheet covers it, so without this row a socket drop while you're picking
        // a buffer would be invisible. (The web client's list keeps a LURKER row for the
        // same reason.) The buffer may not have arrived yet, so fall back to the synthetic
        // one — it's the launch screen's buffer and always exists.
        sections.append(Section(title: nil, rows: [Row(
            buffer: system ?? .system,
            subtitle: nil,
            light: StatusLight.of(reachable: state.reachable, connection: state.connection, network: nil),
            compact: false
        )]))

        let recents = recentRows(state)
        if !recents.isEmpty { sections.append(Section(title: "Recent", rows: recents)) }
        let favorites = favoriteRows(state)
        if !favorites.isEmpty { sections.append(Section(title: "Favorites", rows: favorites)) }

        let networks = state.networks.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
        var seen = Set<Int>()
        for network in networks {
            seen.insert(network.id)
            let buffers = (byNetwork[network.id] ?? []).sorted(by: Self.order)
            guard !buffers.isEmpty else { continue }
            sections.append(Section(title: header(for: network), rows: buffers.map(compactRow)))
        }
        // Buffers whose network isn't in the roster yet (snapshot race).
        for (networkId, buffers) in byNetwork where !seen.contains(networkId) {
            sections.append(Section(title: "network", rows: buffers.sorted(by: Self.order).map(compactRow)))
        }
        return sections
    }

    /// The buffers you've actually been in lately, newest first — the whole point of the
    /// switcher. Keys that no longer resolve (a closed buffer, a left channel) just fall
    /// out; the system buffer is excluded because it already has its own row above.
    private func recentRows(_ state: ChatState) -> [Row] {
        UserPreferences.standard.recentBufferKeys
            .compactMap { state.buffers[$0] }
            .filter { $0.kind != .system }
            .prefix(Self.recentLimit)
            .map { promotedRow($0, state) }
    }

    private func favoriteRows(_ state: ChatState) -> [Row] {
        UserPreferences.standard.favoriteBufferKeys
            .compactMap { state.buffers[$0] }
            .filter { $0.kind != .system }
            .map { promotedRow($0, state) }
    }

    private func promotedRow(_ buffer: Buffer, _ state: ChatState) -> Row {
        Row(
            buffer: buffer,
            subtitle: buffer.networkId.flatMap { state.networks[$0]?.name },
            light: nil,
            compact: false
        )
    }

    private func compactRow(_ buffer: Buffer) -> Row {
        Row(buffer: buffer, subtitle: nil, light: nil, compact: true)
    }

    private func header(for network: Network) -> String {
        switch network.state {
        case .connected: return network.name
        case .connecting: return "\(network.name) — connecting…"
        case .reconnecting: return "\(network.name) — reconnecting…"
        case .disconnected: return "\(network.name) — offline"
        }
    }

    /// Channels, then DMs, then the server log; alphabetical within each.
    private nonisolated static func order(_ lhs: Buffer, _ rhs: Buffer) -> Bool {
        func rank(_ kind: BufferKind) -> Int {
            switch kind {
            case .channel: 0
            case .dm: 1
            case .server: 2
            case .system: 3
            }
        }
        if rank(lhs.kind) != rank(rhs.kind) { return rank(lhs.kind) < rank(rhs.kind) }
        return lhs.target.lowercased() < rhs.target.lowercased()
    }

    /// The system buffer is called "Lurker" wherever the user sees it — it's the app's own
    /// buffer, and the pill it opens under says the same.
    private func displayName(_ buffer: Buffer) -> String {
        switch buffer.kind {
        case .server: return "Server"
        case .system: return "Lurker"
        default: return buffer.target
        }
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "buffer", for: indexPath)
        let row = sections[indexPath.section].rows[indexPath.row]

        // `subtitleCell()` explicitly, not `cell.defaultContentConfiguration()`: the cells
        // are registered as plain `UITableViewCell`, whose default style has no secondary
        // label at all, so the network name would silently never appear.
        var content = row.subtitle == nil
            ? UIListContentConfiguration.cell()
            : UIListContentConfiguration.subtitleCell()
        content.text = displayName(row.buffer)
        content.secondaryText = row.subtitle
        if let light = row.light {
            content.image = Self.lightImage(light)
        }
        if row.compact {
            // Density comes from the row box, never from type size — one font size app-wide.
            content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0)
        }
        cell.contentConfiguration = content

        cell.accessoryView = badge(unread: row.buffer.unread, highlights: row.buffer.highlights)
        cell.accessoryType = cell.accessoryView == nil ? .disclosureIndicator : .none
        return cell
    }

    /// The status light as a leading image, so it sits in the cell's own image slot and
    /// stays aligned with the text however the row is laid out.
    private static func lightImage(_ light: StatusLight) -> UIImage? {
        UIImage(systemName: "circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9))?
            .withTintColor(Palette.color(for: light), renderingMode: .alwaysOriginal)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelect?(sections[indexPath.section].rows[indexPath.row].buffer)
    }

    override func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let buffer = sections[indexPath.section].rows[indexPath.row].buffer
        // The server log and the system buffer can't be closed.
        guard buffer.kind != .server, buffer.kind != .system else { return nil }
        let title = buffer.kind == .channel ? "Leave" : "Close"
        let close = UIContextualAction(style: .destructive, title: title) { [weak self] _, _, done in
            self?.viewModel.closeBuffer(buffer.key)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [close])
    }

    /// Long-press to pin. The Favorites section is only as real as the way to fill it, and
    /// a section with no path into it would just be a permanently empty box.
    override func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        let buffer = sections[indexPath.section].rows[indexPath.row].buffer
        guard buffer.kind != .system else { return nil }
        let key = buffer.key.id
        let isFavorite = UserPreferences.standard.isFavorite(key)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(
                    title: isFavorite ? "Unfavorite" : "Favorite",
                    image: UIImage(systemName: isFavorite ? "star.slash" : "star")
                ) { _ in
                    UserPreferences.standard.toggleFavorite(key)
                    guard let self else { return }
                    self.apply(self.state)
                },
            ])
        }
    }

    /// A pill showing the unread count, tinted red when the buffer holds a highlight.
    private func badge(unread: Int, highlights: Int) -> UIView? {
        guard unread > 0 else { return nil }
        let label = UILabel()
        label.text = " \(unread) "
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .white
        label.backgroundColor = highlights > 0 ? .systemRed : .systemGray
        label.textAlignment = .center
        label.sizeToFit()
        let height = label.bounds.height + 4
        label.frame = CGRect(x: 0, y: 0, width: max(label.bounds.width + 8, height), height: height)
        label.layer.cornerRadius = height / 2
        label.layer.masksToBounds = true
        return label
    }
}
