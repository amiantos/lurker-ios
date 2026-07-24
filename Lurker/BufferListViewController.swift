// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine
import LurkerKit
import UIKit

/// The app's home screen: every buffer you have, and the way into all of them.
///
/// It is the navigation stack's *root*, and a chat screen is pushed on top of it. That's the
/// ordinary iOS shape for a list of things you go into and come back from, and it buys the
/// back button and the interactive pop gesture rather than making this screen invent its own
/// way in and out. It used to be a sheet over the chat screen, which meant a bespoke button
/// to summon it, an edge swipe wired by hand, and a chat screen that could never be left.
///
/// Not a directory: the buffers you actually move between are a handful you keep returning
/// to, so recents and pins come first at a size you can hit without looking, and the full
/// grouped roster sits underneath, denser, for the times you want something you haven't
/// touched in a week.
///
/// "Denser" is spacing, not type size — one font size app-wide. The hierarchy is row
/// height, a network subtitle on the promoted rows, and order.
///
/// It reports the pick through `onSelect` and doesn't know what happens next.
final class BufferListViewController: UITableViewController {
    private let viewModel: ChatViewModel
    private var cancellables = Set<AnyCancellable>()

    /// Called with the picked buffer. The presenter owns opening it.
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
        navigationItem.largeTitleDisplayMode = .always
        // Account and Join go in the bottom toolbar rather than the navigation bar: they're
        // the two things you *do* here, as against the list itself, and the bottom of a tall
        // phone is where a thumb already is. (`toolbarItems` is the plain navigation-
        // controller toolbar — on iOS 26 it renders as the floating glass bar.)
        toolbarItems = [accountItem(), .flexibleSpace(), joinItem]
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

    /// The toolbar belongs to the navigation controller, so each screen has to say whether
    /// it wants one — the chat screen hides it (see `ChatViewController.viewWillAppear`),
    /// and coming back here has to put it up again.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(false, animated: animated)
    }

    private func apply(_ state: ChatState) {
        self.state = state
        sections = buildSections(state)
        tableView.reloadData()
    }

    // MARK: - Bar items

    /// Account, not buffer: the things that outlast whichever conversation you're reading.
    /// It lives here rather than on the chat screen's "…" because that one is a list of
    /// *views* — and because sign-out sitting next to "Members" put the end of your session
    /// one slipped thumb from a nick list.
    ///
    /// Settings (#20) lands here too, which is why it's an ellipsis and not a door.
    private func accountItem() -> UIBarButtonItem {
        let signOut = UIAction(
            title: "Sign Out",
            image: UIImage(systemName: "rectangle.portrait.and.arrow.right"),
            attributes: .destructive
        ) { [weak self] _ in
            // Revokes server-side + clears the Keychain; SceneDelegate returns us to sign-in.
            self?.viewModel.logout()
        }
        let item = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: [signOut]))
        item.accessibilityLabel = "Account"
        return item
    }

    // MARK: - Joining

    /// Join, in the bottom-right of the list — where an app whose home screen is a list of
    /// things puts "one more of these".
    ///
    /// Its menu is **deferred**, so which networks it offers is decided when you tap it
    /// rather than whenever the item happened to be built. That's the whole reason this can
    /// be a menu at all: the item itself is never replaced (a `toolbarItems` array set once
    /// in `viewDidLoad`), and it was *replacing* a bar item on every unread count that
    /// previously closed the menu out from under whoever had it open.
    ///
    /// #11 will add "Add Network…" alongside the channels.
    private lazy var joinItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            menu: UIMenu(children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    completion(self?.joinElements() ?? [])
                },
            ])
        )
        item.accessibilityLabel = "Join Channel"
        return item
    }()

    /// One network makes the "+" a straight tap through to the prompt — a menu of one is a
    /// tap spent to learn nothing — and several make it a list to pick from.
    ///
    /// Networks that aren't connected are offered but disabled, matching the web's `net-add`:
    /// a JOIN with no socket to travel down goes nowhere, and nothing comes back to say so.
    /// Shown rather than hidden because the network is still yours, and a list that silently
    /// omits it just looks wrong.
    private func joinElements() -> [UIMenuElement] {
        let networks = state.networks.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
        guard !networks.isEmpty else {
            return [UIAction(title: "No networks", attributes: .disabled) { _ in }]
        }
        if let only = networks.first, networks.count == 1 {
            return [UIAction(
                title: "Join Channel…",
                attributes: only.state == .connected ? [] : .disabled
            ) { [weak self] _ in
                self?.presentJoinAlert(network: only)
            }]
        }
        return networks.map { network in
            UIAction(
                title: network.name,
                subtitle: network.state == .connected ? nil : "not connected",
                attributes: network.state == .connected ? [] : .disabled
            ) { [weak self] _ in
                self?.presentJoinAlert(network: network)
            }
        }
    }

    private func presentJoinAlert(network: Network) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Join channel", message: "on \(network.name)", preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = "#channel"
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
            $0.spellCheckingType = .no
            $0.returnKeyType = .join
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Join", style: .default) { [weak self, weak alert] _ in
            let typed = (alert?.textFields?.first?.text ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self?.join(network: network, channel: typed)
        })
        present(alert, animated: true)
    }

    /// Joining is also switching: you asked for a channel, so land in it. The buffer won't
    /// exist yet — its row arrives with the server's `channel-joined` — so hand over a
    /// synthesized one exactly as a notification tap does, and let the chat screen's
    /// `hydrateIfNeeded` fill it in when the join completes.
    private func join(network: Network, channel typed: String) {
        // A bare sigil is not a name: `ensurePrefix("#")` would send a JOIN for "#".
        guard !ChannelName.fold(typed).isEmpty else { return }
        let channel = ChannelName.ensurePrefix(typed)
        viewModel.joinChannel(networkId: network.id, channel: channel)
        // `buffer(for:)` rather than a hand-built one: `ensurePrefix` accepts the full
        // RFC-1459 sigil set, of which `BufferKind.of` classifies only `#` and `&` as
        // channels — so hardcoding `.channel` here would hand the chat screen a member list
        // its store row disagrees with.
        onSelect?(state.buffer(for: BufferKey(networkId: network.id, target: channel)))
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

        // Everything promoted above is then held out of the roster below, so a buffer
        // appears exactly once. Without this a recently-visited favorite printed three
        // times over — twice promoted and once in its network — with badges updating in
        // lockstep and a swipe-to-Leave on any one silently removing the other two.
        var promoted = Set<String>()

        let favorites = favoriteRows(state, promoted: &promoted)
        let recents = recentRows(state, promoted: &promoted)
        if !recents.isEmpty { sections.append(Section(title: "Recent", rows: recents)) }
        if !favorites.isEmpty { sections.append(Section(title: "Favorites", rows: favorites)) }

        let networks = state.networks.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
        var seen = Set<Int>()
        for network in networks {
            seen.insert(network.id)
            let buffers = (byNetwork[network.id] ?? [])
                .filter { !promoted.contains($0.key.id) }
                .sorted(by: Self.order)
            guard !buffers.isEmpty else { continue }
            sections.append(Section(title: header(for: network), rows: buffers.map(compactRow)))
        }
        // Buffers whose network isn't in the roster yet (snapshot race).
        for (networkId, buffers) in byNetwork where !seen.contains(networkId) {
            let rest = buffers.filter { !promoted.contains($0.key.id) }.sorted(by: Self.order)
            guard !rest.isEmpty else { continue }
            sections.append(Section(title: "network", rows: rest.map(compactRow)))
        }
        return sections
    }

    /// The buffers you've actually been in lately, newest first.
    ///
    /// The buffer you were *just* in is included, and sits at the top. As a sheet over the
    /// chat screen this list excluded it — the row you were already on would have been the
    /// first thing under your thumb, doing nothing. Backing out to a home screen inverts
    /// that: the conversation you just left is the single likeliest place you'd want to
    /// return to, and a list that hid it would be the thing that looked broken.
    ///
    /// Keys that no longer resolve (a closed buffer, a left channel) just fall out, and the
    /// system buffer is excluded because it already has its own row above.
    private func recentRows(_ state: ChatState, promoted: inout Set<String>) -> [Row] {
        let rows = UserPreferences.standard.recentBufferKeys
            .filter { !promoted.contains($0) }
            .compactMap { state.buffers[$0] }
            .filter { $0.kind != .system }
            .prefix(Self.recentLimit)
            .map { promotedRow($0, state) }
        promoted.formUnion(rows.map(\.buffer.key.id))
        return Array(rows)
    }

    /// Pinned buffers, claimed before recents so a favorite you just visited stays in the
    /// section you pinned it to rather than moving around under you.
    private func favoriteRows(_ state: ChatState, promoted: inout Set<String>) -> [Row] {
        let rows = UserPreferences.standard.favoriteBufferKeys
            .compactMap { state.buffers[$0] }
            .filter { $0.kind != .system }
            .map { promotedRow($0, state) }
        promoted.formUnion(rows.map(\.buffer.key.id))
        return rows
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
        // No `networkName` here, unlike the pill: every row already states its network — as
        // a subtitle when promoted, as its section header otherwise — so resolving a server
        // log to its network's name would just print "libera" above "libera".
        content.text = row.buffer.displayName()
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
