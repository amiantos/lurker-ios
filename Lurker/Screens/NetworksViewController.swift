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
    private var cancellables = Set<AnyCancellable>()
    private var load: Load = .loading
    private let placeholderView = StateView()
    /// What's on screen now, so a state change that doesn't move it doesn't reconfigure it.
    private var shownPlaceholder: StateView.Model?
    /// The row model each network was last drawn with, so a live transition reconfigures only
    /// the networks it actually moved — see `applyLiveStatuses`.
    ///
    /// ⚠ Kept for the whole list, not just the visible cells. Populated from `cellForRowAt`
    /// it had no entry for any row that had never been scrolled to, so every one of those
    /// counted as "changed" on every state emission — which quietly retired a refusal pinned
    /// under a row nobody had touched, before its owner could scroll back and read it.
    private var shownRows: [Int: NetworkRow] = [:]
    /// The list as last drawn, so a re-read that changed nothing doesn't redraw it.
    private var shownConfigs: [NetworkConfig] = []
    /// Which fetch is the current one. Three call sites can start one — every appearance, a
    /// completed delete, and Try Again — and they are not ordered by anything.
    private var loadGeneration = 0
    /// The most recent refusal, under the row it belongs to.
    ///
    /// Shown in the row rather than in an alert, following the settings screen's failed-write
    /// pattern. An alert for an *asynchronous* result is droppable — anything else presented
    /// in the round trip (the delete confirmation, say) silently eats it, and the user is left
    /// with a row that didn't change and no reason why. A row can't lose its own subtitle.
    private var actionError: (id: Int, message: String)?

    private var configs: [NetworkConfig] {
        if case .loaded(let configs) = load { return configs }
        return []
    }

    /// Pushed, never presented — so no Done button of its own. It carries no
    /// `showsDoneButton` switch because there is nowhere in the app that presents it as a
    /// sheet; a parameter with no caller is a path nobody has walked, and this one would have
    /// shipped with a doc comment describing a presentation that doesn't exist.
    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Networks"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .add, primaryAction: UIAction { [weak self] _ in self?.add() }
        )
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "network")
        // One button, two meanings — whichever state is on screen owns it. The empty state
        // and the failure state can't both be showing, so this can't be ambiguous.
        placeholderView.onAction = { [weak self] in
            guard let self else { return }
            if case .loaded = load { add() } else { reload() }
        }

        // Only the connection states, and only when they actually move. `statePublisher`
        // fires on every frame the store reduces — every message in every buffer — and this
        // screen cares about one dictionary's worth of it. Without the map and the dedupe,
        // an open networks screen would rebuild itself on the traffic of an idle channel.
        viewModel.statePublisher
            .map { state in state.networks.mapValues(\.state) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyLiveStatuses() }
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
        // ⚠⚠ Gated on "have we ever loaded", NOT on "is the list empty". Those differ on the
        // exact account this screen exists for: a fresh one, whose first load lands as
        // `.loaded([])`. Keyed on emptiness, every appearance replaced "No networks yet" with
        // the spinner and back — the flicker this guard is here to prevent — and, because
        // `load` had already been overwritten by the time the fetch returned, the
        // keep-what-we-had arm below could never match for it, so one dropped request told a
        // brand-new user "Couldn't load networks".
        if case .loaded = load {} else { load = .loading }
        // A refresh behind a list that exists doesn't blank it: the list stays true while we
        // re-ask.
        render()
        loadGeneration += 1
        let generation = loadGeneration
        Task { [weak self] in
            guard let self else { return }
            let fetched = await viewModel.networkConfigs()
            // ⚠ Two deletes in quick succession start two fetches, and nothing orders their
            // replies. Applying a stale one puts the network the user just deleted back on
            // screen as a row that can only answer with an error.
            guard generation == loadGeneration else { return }
            // ⚠ Nil is "we couldn't ask", never "no networks" — the client draws that
            // distinction deliberately, and collapsing it here would greet a failed request
            // with the empty state's welcome.
            //
            // ⚠⚠ So a failed *refresh* keeps whatever we already knew, an empty list
            // included: the configuration hasn't changed just because one request didn't
            // arrive, and the next appearance asks again. Only a screen that has never had an
            // answer shows the failure — which is the only one where there's nothing truer to
            // show instead.
            switch (fetched, load) {
            case (let fetched?, _): load = .loaded(fetched)
            case (nil, .loaded): break
            case (nil, _): load = .failed
            }
            render()
        }
    }

    private func render() {
        // A list that no longer holds a network shouldn't keep its refusal or its last status
        // around to attach to whatever takes its place.
        let live = Set(configs.map(\.id))
        shownRows = shownRows.filter { live.contains($0.key) }
        if let error = actionError, !live.contains(error.id) { actionError = nil }
        // ⚠⚠ Only when the list actually changed. `reloadData` replaces every visible cell and
        // dismisses an open action menu with it — the failure `applyLiveStatuses` below avoids
        // by reconfiguring, reintroduced here by the path that re-reads on every appearance.
        // Open a row's menu, and a re-read that lands half a second later on a slow link
        // closes it under your finger, having changed nothing.
        if configs != shownConfigs {
            shownConfigs = configs
            tableView.reloadData()
        }
        // Unconditional, unlike the reload above: this records what is drawn, and it has to
        // stay true on the pass that decided not to redraw. Covers the rows below the fold
        // too, which are drawn from the same data whether or not a cell exists for them yet.
        for config in configs { shownRows[config.id] = row(for: config) }
        updatePlaceholder()
    }

    /// Reconfigure the rows whose connection actually moved, rather than reloading the table.
    ///
    /// ⚠⚠ A blanket `reloadData` replaces every visible cell — including the one whose action
    /// menu is open under the user's finger, which UIKit then dismisses, and including a row
    /// with a swipe action revealed. A flapping `reconnecting` network somewhere else in the
    /// list is enough to do it. The buffer list learned this on its join button and wrote it
    /// down: rebuilding is the bug.
    private func applyLiveStatuses() {
        let moved = configs.enumerated().filter { shownRows[$0.element.id] != row(for: $0.element) }
        guard !moved.isEmpty else { return }
        // A row that moved on its own has retired whatever refusal was pinned under it — the
        // state it was describing is no longer the state.
        if let error = actionError, moved.contains(where: { $0.element.id == error.id }) {
            actionError = nil
        }
        for (_, config) in moved { shownRows[config.id] = row(for: config) }
        tableView.reconfigureRows(at: moved.map { IndexPath(row: $0.offset, section: 0) })
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
                    subtitle: "Add the IRC network you want to talk on.",
                    actionTitle: "Add Network"
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
        let row = row(for: config)

        var content = cell.defaultContentConfiguration()
        content.text = config.name
        // The subtitle is the row's one line of explanation, so a refusal takes it: what the
        // server said about the thing you just tried beats a host and port you can already
        // see in the row above it. It clears on the next state change, action or reload.
        if let error = actionError, error.id == config.id {
            content.secondaryText = error.message
            content.secondaryTextProperties.color = Palette.bad
        } else {
            content.secondaryText = Self.subtitle(for: config, row: row)
            content.secondaryTextProperties.color = .secondaryLabel
        }
        content.secondaryTextProperties.numberOfLines = 0
        // The dot carries the state; the words repeat it for anyone who can't use colour.
        content.image = UIImage(systemName: "circle.fill")
        content.imageProperties.tintColor = Palette.color(for: row.light)
        content.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 10)
        cell.contentConfiguration = content

        // The tap edits; the button is for everything that changes the connection rather than
        // the configuration. Splitting them this way is what lets the menu be a menu — the
        // primary action of a row in a list of things you configure is to configure it.
        //
        // ⚠⚠ The button is REUSED, never replaced. `reconfigureRows` re-runs this method for a
        // cell already on screen, and assigning a new `accessoryView` removes the old button
        // from the hierarchy — which dismisses its open menu. That is precisely the failure
        // the deferred menu below exists to prevent, reintroduced one line above it: a
        // `connecting` network reaching `connected` a second after you opened its menu would
        // close it under your finger. Only the id it points at changes.
        let button = (cell.accessoryView as? NetworkActionButton) ?? makeActionButton()
        button.networkID = config.id
        button.accessibilityLabel = "Actions for \(config.name)"
        cell.accessoryView = button
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

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        edit(configs[indexPath.row])
    }

    // MARK: - Actions

    /// Adding starts with "which network?", not with a blank hostname field — see
    /// `NetworkPickerViewController` for why that ordering is the point.
    private func add() {
        push(NetworkPickerViewController(viewModel: viewModel) { [weak self] draft in
            guard let self else { return }
            push(NetworkFormViewController(viewModel: viewModel, draft: draft) { [weak self] in
                self?.finished()
            })
        })
    }

    private func edit(_ config: NetworkConfig) {
        push(NetworkFormViewController(viewModel: viewModel, editing: config) { [weak self] in
            self?.finished()
        })
    }

    private func push(_ controller: UIViewController) {
        navigationController?.pushViewController(controller, animated: true)
    }

    /// Back to the list, with the change on it.
    ///
    /// ⚠ `popToViewController`, not `popViewController`: adding goes list → picker → form, so
    /// popping one screen would land on the picker — the step before the form, not the place
    /// the user started. The reload is separate from the store's own: the create's roster
    /// re-read updates the roster, and this screen's list is a different fetch of a different
    /// shape.
    private func finished() {
        reload()
        navigationController?.popToViewController(self, animated: true)
    }

    private func row(for config: NetworkConfig) -> NetworkRow {
        NetworkRow(
            connection: viewModel.state.networks[config.id]?.state ?? .disconnected,
            isBlocked: config.blocked
        )
    }

    /// A button that knows which network it is pointing at, so one instance can serve a cell
    /// for the life of that cell rather than being replaced whenever the row is redrawn.
    private final class NetworkActionButton: UIButton {
        var networkID = 0
    }

    private func makeActionButton() -> NetworkActionButton {
        let button = NetworkActionButton(type: .system)
        button.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
        // ⚠ Deferred, so which actions the menu offers is decided when it's opened rather
        // than when the cell was last drawn — and so this button never needs rebuilding to
        // stay correct. Same reasoning as the buffer list's join menu: a network that
        // transitions between those two moments would otherwise offer Connect on a connected
        // network, and rebuilding to fix that is what closes an open menu out from under
        // whoever is reading it. The id is read at open time for the same reason.
        button.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self, weak button] completion in
                guard let self, let id = button?.networkID,
                      let config = configs.first(where: { $0.id == id })
                else { return completion([]) }
                completion(row(for: config).actions.map { action in
                    UIAction(
                        title: action.title,
                        image: UIImage(systemName: action.symbolName),
                        attributes: action.isDestructive ? .destructive : []
                    ) { [weak self] _ in self?.perform(action, on: config) }
                })
            },
        ])
        button.showsMenuAsPrimaryAction = true
        button.sizeToFit()
        return button
    }

    private func perform(_ action: NetworkAction, on config: NetworkConfig) {
        switch action {
        case .delete:
            confirmDelete(config)
        case .connect:
            run(on: config.id) { [viewModel] in await viewModel.connectNetwork(id: config.id) }
        case .disconnect:
            run(on: config.id) { [viewModel] in await viewModel.disconnectNetwork(id: config.id) }
        case .reconnect:
            run(on: config.id) { [viewModel] in await viewModel.reconnectNetwork(id: config.id) }
        }
    }

    /// Run a verb that answers with an error message or nil, and pin the refusal under its row.
    ///
    /// Nothing is applied optimistically. Every one of these is answered by the server the
    /// long way round — the connection transitions arrive as `state` events, the delete by
    /// the roster it triggers — and a row that moved on its own would be claiming an outcome
    /// the server hasn't reached yet. On a paused account (#18) they are all refused, which
    /// is the case that makes the message worth showing rather than swallowing.
    ///
    /// The refusal lands in the row, not an alert, because it arrives on its own schedule:
    /// an alert competing with whatever the user opened during the round trip is an alert
    /// UIKit drops, and dropping it leaves a row that simply didn't change with no reason
    /// given. This is the settings screen's failed-write pattern, for the same reason.
    private func run(on id: Int, _ verb: @escaping () async -> String?) {
        // Whatever the last attempt said is now stale — a new attempt is under way.
        setActionError(nil)
        Task { [weak self] in
            guard let self, let message = await verb() else { return }
            setActionError((id: id, message: message))
        }
    }

    /// Move the single refusal slot, redrawing both the row losing it and the row gaining it.
    ///
    /// ⚠ Redrawing only the new row left the old one rendering a refusal the model no longer
    /// held: two errors on screen where one existed, the stale one surviving until that cell
    /// happened to be re-dequeued. Reachable in one gesture on a paused account (#18), where
    /// every action is refused — tap Connect on one network, then on another.
    private func setActionError(_ error: (id: Int, message: String)?) {
        let affected = Set([actionError?.id, error?.id].compactMap { $0 })
        actionError = error
        let paths = affected.compactMap { id in
            configs.firstIndex(where: { $0.id == id }).map { IndexPath(row: $0, section: 0) }
        }
        guard !paths.isEmpty else { return }
        tableView.reconfigureRows(at: paths)
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
                    setActionError((id: config.id, message: message))
                    return
                }
                // The roster re-read the delete triggers has already updated the store; this
                // screen's own list is a separate fetch and has to catch up on its own.
                reload()
            }
        })
        // ⚠⚠ An action sheet with no anchor is a hard crash at regular width, so the source
        // view is set unconditionally and only the *rect* is conditional. Matched on `id`,
        // not on the whole struct: `config` was captured when the cell was built, and any
        // field moving under a background refresh — a rename, a port edited from the web,
        // `blocked` flipping — makes whole-struct equality miss. Unreachable while this is
        // iPhone-only (`TARGETED_DEVICE_FAMILY = 1`), which is exactly why it would ship.
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = tableView
            if let index = configs.firstIndex(where: { $0.id == config.id }) {
                popover.sourceRect = tableView.rectForRow(at: IndexPath(row: index, section: 0))
            }
        }
        present(sheet, animated: true)
    }

    // MARK: - Copy

    /// `host:port · state`, plus the allowlist when it applies — appended rather than
    /// substituted, since a blocked network can be connected and the connection is the more
    /// urgent of the two facts.
    private static func subtitle(for config: NetworkConfig, row: NetworkRow) -> String {
        var parts = ["\(config.host):\(config.port)", row.connection.label]
        if row.isBlocked { parts.append("not allowed here") }
        return parts.joined(separator: " · ")
    }
}
