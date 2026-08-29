// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine
import LurkerKit
import UIKit

/// The networks screen (#11): what the account is configured to connect to, and the four
/// things you can do to one.
///
/// This is the screen that makes the app self-sufficient. Until it existed, a phone that
/// signed in to an account with no networks was a dead end — the buffer list said "add a
/// network" and there was nowhere to do it — and even an account with networks had to go to
/// the browser to connect one that had been left off.
///
/// **Two sources, one row.** The configuration (name, host, port, whether the admin's
/// allowlist blocks it) comes from `GET /api/networks`, fetched when this screen opens. The
/// connection state comes from the store, live, because that's where `state` events land. So
/// the list is re-fetched on appear and after anything that changes its membership, while the
/// dots move on their own without re-asking the server.
///
/// Editing and adding are #11's next PR; a row's tap is deliberately inert until then rather
/// than doing something it will stop doing.
final class NetworksViewController: UITableViewController {

    /// Where the config list is in its lifecycle. The three unhappy paths are distinguished
    /// rather than collapsed into "no rows" (#19): a fresh account with no networks, a fetch
    /// still running, and a fetch that failed are three different things to say, and only one
    /// of them is the user's to act on.
    private enum Load: Equatable {
        case loading
        case loaded([NetworkConfig])
        case failed
    }

    private let viewModel: ChatViewModel
    private let showsDoneButton: Bool
    private var cancellables = Set<AnyCancellable>()
    private var load: Load = .loading
    private let placeholderView = StateView()
    /// What's on screen now, so a state change that doesn't move it doesn't reconfigure it.
    private var shownPlaceholder: StateView.Model?

    private var configs: [NetworkConfig] {
        if case .loaded(let configs) = load { return configs }
        return []
    }

    /// `showsDoneButton` is passed rather than inferred from the navigation stack: this screen
    /// is both the root of its own sheet (from the buffer list) and a push inside Settings,
    /// and a Done button that guessed wrong would either strand the sheet or put a second
    /// dismiss next to Settings'.
    init(viewModel: ChatViewModel, showsDoneButton: Bool) {
        self.viewModel = viewModel
        self.showsDoneButton = showsDoneButton
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Networks"
        if showsDoneButton {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
            )
        }
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "network")
        placeholderView.onAction = { [weak self] in self?.reload() }

        // Only the connection states, and only when they actually move. `statePublisher`
        // fires on every frame the store reduces — every message in every buffer — and this
        // screen cares about one dictionary's worth of it. Without the map and the dedupe,
        // an open networks screen would rebuild itself on the traffic of an idle channel.
        viewModel.statePublisher
            .map { state in state.networks.mapValues(\.state) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.tableView.reloadData() }
            .store(in: &cancellables)

        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Re-read on every appearance, not just the first: a network added or deleted from
        // the web while this screen sat behind Settings is exactly the kind of change nobody
        // is going to push at us — the roster frame carries names, not hosts or ports.
        if case .loading = load { return } // the first load is already in flight
        reload()
    }

    // MARK: - Loading

    private func reload() {
        // Only show the spinner when there's nothing to show already. A refresh behind a
        // populated list should not blank it — the list is still true while we re-ask.
        if configs.isEmpty { load = .loading }
        render()
        Task { [weak self] in
            guard let self else { return }
            let fetched = await viewModel.networkConfigs()
            // ⚠ Nil is "we couldn't ask", never "no networks" — the client draws that
            // distinction deliberately, and collapsing it here would greet a failed request
            // with the empty state's welcome.
            //
            // ⚠⚠ And a failed *refresh* keeps the list it already had. The spinner is
            // suppressed above when there's something on screen, on the grounds that a list
            // stays true while we re-ask — which was a lie the moment the failure branch
            // replaced that list with an error screen. A stale row beats a wiped screen: the
            // configuration hasn't changed just because one request didn't arrive, and the
            // next appearance asks again.
            switch (fetched, load) {
            case (let fetched?, _): load = .loaded(fetched)
            case (nil, .loaded(let existing)) where !existing.isEmpty: break
            case (nil, _): load = .failed
            }
            render()
        }
    }

    private func render() {
        tableView.reloadData()
        updatePlaceholder()
    }

    private func updatePlaceholder() {
        let model: StateView.Model?
        switch load {
        case .loading:
            model = .init(title: "Loading networks…", isLoading: true)
        case .failed:
            model = .init(
                symbol: "exclamationmark.triangle",
                title: "Couldn't load networks",
                subtitle: "Check your connection and try again.",
                actionTitle: "Try Again"
            )
        case .loaded(let configs):
            model = configs.isEmpty
                ? .init(
                    symbol: "network",
                    title: "No networks yet",
                    // No call to action while there's no way to answer it — adding is the
                    // next PR. Saying "add one" over a screen with no add button would be
                    // the buffer list's dead end again, one level down.
                    subtitle: "Networks you've added appear here."
                )
                : nil
        }
        guard model != shownPlaceholder else { return }
        shownPlaceholder = model
        if let model {
            placeholderView.configure(model)
            tableView.backgroundView = placeholderView
        } else {
            tableView.backgroundView = nil
        }
    }

    // MARK: - Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        configs.count
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        // Said once, under the list, rather than in every blocked row's subtitle: it explains
        // a policy, and a policy repeated per row reads as a per-row problem.
        configs.contains(where: \.blocked)
            ? "This server's administrator limits which networks can be connected to."
            : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "network", for: indexPath)
        let config = configs[indexPath.row]
        let status = status(of: config)

        var content = cell.defaultContentConfiguration()
        content.text = config.name
        content.secondaryText = "\(config.host):\(config.port) · \(Self.label(for: status))"
        content.secondaryTextProperties.color = .secondaryLabel
        // The dot carries the state; the words repeat it for anyone who can't use colour.
        content.image = UIImage(systemName: "circle.fill")
        content.imageProperties.tintColor = Palette.color(for: status.light)
        content.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 10)
        cell.contentConfiguration = content

        // The row itself is inert until editing exists (next PR), so everything this screen
        // can do lives behind one button rather than a tap target that does nothing.
        cell.accessoryView = actionButton(for: config, status: status)
        cell.selectionStyle = .none
        return cell
    }

    /// Swipe-to-delete as well as the menu — it's the one action muscle memory reaches for in
    /// a list like this, and it lands on the same confirmation.
    override func tableView(
        _ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let config = configs[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
            self?.confirmDelete(config)
            // Reported handled either way: the row is only removed once the server says so,
            // so leaving the swipe open would suggest the deletion is still pending on it.
            done(true)
        }
        delete.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [delete])
    }

    // MARK: - Actions

    private func status(of config: NetworkConfig) -> NetworkRowStatus {
        NetworkRowStatus.of(
            connection: viewModel.state.networks[config.id]?.state ?? .disconnected,
            blocked: config.blocked
        )
    }

    private func actionButton(for config: NetworkConfig, status: NetworkRowStatus) -> UIButton {
        let actions = status.actions.map { action in
            UIAction(
                title: Self.label(for: action),
                image: UIImage(systemName: Self.symbol(for: action)),
                attributes: action.isDestructive ? .destructive : []
            ) { [weak self] _ in
                self?.perform(action, on: config)
            }
        }
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
        button.menu = UIMenu(title: config.name, children: actions)
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = "Actions for \(config.name)"
        button.sizeToFit()
        return button
    }

    private func perform(_ action: NetworkAction, on config: NetworkConfig) {
        switch action {
        case .delete:
            confirmDelete(config)
        case .connect:
            run { await self.viewModel.connectNetwork(id: config.id) }
        case .disconnect:
            run { await self.viewModel.disconnectNetwork(id: config.id) }
        case .reconnect:
            run { await self.viewModel.reconnectNetwork(id: config.id) }
        }
    }

    /// Run a verb that answers with an error message or nil, and say so if it refused.
    ///
    /// Nothing is applied optimistically. Every one of these is answered by the server the
    /// long way round — the connection transitions arrive as `state` events, the delete by
    /// the roster it triggers — and a row that moved on its own would be claiming an outcome
    /// the server hasn't reached yet. On a paused account (#18) they are all refused, which
    /// is the case that makes the message worth showing rather than swallowing.
    private func run(_ verb: @escaping () async -> String?) {
        Task { [weak self] in
            guard let message = await verb() else { return }
            self?.presentError(message)
        }
    }

    private func confirmDelete(_ config: NetworkConfig) {
        guard presentedViewController == nil else { return }
        let sheet = UIAlertController(
            title: "Delete \(config.name)?",
            // Named plainly because it is not recoverable and is much larger than the row
            // being tapped: the server cascades the network's buffers, so this is the
            // conversation history too, on every device.
            message: "This removes its channels, direct messages and history from Lurker, on all your devices.",
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self else { return }
            Task { [weak self] in
                guard let self else { return }
                if let message = await viewModel.deleteNetwork(id: config.id) {
                    presentError(message)
                    return
                }
                // The roster re-read the delete triggers has already updated the store; this
                // screen's own list is a separate fetch and has to catch up on its own.
                reload()
            }
        })
        // An action sheet needs an anchor on iPad, and the row is where the gesture came from.
        if let popover = sheet.popoverPresentationController,
           let index = configs.firstIndex(of: config) {
            popover.sourceView = tableView
            popover.sourceRect = tableView.rectForRow(at: IndexPath(row: index, section: 0))
        }
        present(sheet, animated: true)
    }

    private func presentError(_ message: String) {
        guard presentedViewController == nil else { return }
        // The server's own wording, which knows why it refused — a blocked host, a paused
        // account, a network that isn't connected.
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: - Copy

    private static func label(for status: NetworkRowStatus) -> String {
        switch status {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .reconnecting: "Reconnecting…"
        case .disconnected: "Offline"
        case .blocked: "Not allowed here"
        }
    }

    private static func label(for action: NetworkAction) -> String {
        switch action {
        case .connect: "Connect"
        case .disconnect: "Disconnect"
        case .reconnect: "Reconnect"
        case .delete: "Delete"
        }
    }

    private static func symbol(for action: NetworkAction) -> String {
        switch action {
        case .connect: "bolt"
        case .disconnect: "bolt.slash"
        case .reconnect: "arrow.clockwise"
        case .delete: "trash"
        }
    }
}
