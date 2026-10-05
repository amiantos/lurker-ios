// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine
import LurkerKit
import UIKit

/// One of a channel's list modes — bans, exceptions, invite exceptions or quiets (#187) —
/// fetched from the IRC server when the screen opens, with who set each entry and when. An op
/// can add an entry with + and remove one with a swipe.
///
/// ⚠⚠ Fetched ONCE, then kept current by patching it from live `MODE ±letter` rows — another
/// op's ban or our own. Never refetched after an add or a remove: a fetch on the wire claims a
/// 482 aimed at the MODE just sent (`server/services/modeList.ts`), and the list would read
/// "Only channel operators can see this list" because a ban was refused. Pull to refresh is the
/// user's own ask, and a reconnect or a rejoin refetches, since the gap never arrives as live rows.
final class ModeListViewController: UITableViewController {
    private let viewModel: ChatViewModel
    private let key: BufferKey
    private let letter: String
    private var cancellables = Set<AnyCancellable>()

    private enum Status: Equatable {
        case loading
        case ready([ModeListEntry])
        case failed(String)
    }

    private var status = Status.loading
    /// Mode rows seen since the latest fetch went out; they patch what it brought back.
    private var rowsSinceFetch: [Message] = []
    /// The latest fetch. A refresh while one is out starts a newer one, which owns the screen.
    private var fetch = 0

    /// The refusal of the last add or remove: the verb's own, or the channel's error rows (482,
    /// 478 for a full list …) soon after it.
    private var actionError: String?
    private var refusals = ChannelRefusals()

    /// A fetch is owed once the link is up: a new socket resynced (the gap arrived as backlog,
    /// so the list can't be patched up to date) while the network wasn't ready, the last fetch
    /// found it down, or a fetched list lost readiness (a rejoin or an IRC-level reconnect).
    ///
    /// ⚠ Paid on the link's RISING edge — connected and in the channel, after not being. Never
    /// straight off a resync whose network is still registering (after a server restart): that
    /// fetch is refused `not-connected` and nothing would ask again. The edge also stops a retry
    /// loop while the store says connected and the server says otherwise.
    private var fetchOwed = false
    private var lastSlice: Slice?
    /// One change at a time: a double tap must not send the ban twice.
    private var busy = false

    private var shown: [ModeListEntry] = []
    private var canEdit = false

    /// Everything the screen draws, as last drawn. Compared before redrawing because a busy
    /// channel's state moves on every message, and a reload mid-swipe snaps the Remove button
    /// shut under the user's thumb.
    private struct Drawn: Equatable {
        let status: Status
        let shown: [ModeListEntry]
        let canEdit: Bool
        let busy: Bool
        let footer: String?
    }

    private var drawn: Drawn?

    init(viewModel: ChatViewModel, key: BufferKey, letter: String, name: String) {
        self.viewModel = viewModel
        self.key = key
        self.letter = letter
        super.init(style: .insetGrouped)
        title = name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "entry")
        refreshControl = UIRefreshControl()
        refreshControl?.addAction(UIAction { [weak self] _ in self?.load() }, for: .valueChanged)

        // Only what this screen reads: the state moves on every line in every buffer.
        viewModel.statePublisher
            .map { [key, letter] state in
                let access = state.channelAccess(key)
                return Slice(
                    access: access,
                    linkUp: key.networkId.flatMap { state.networks[$0] }?.state == .connected,
                    listed: access.spec?.list.contains(letter) == true
                )
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] slice in self?.linkMoved(slice) }
            .store(in: &cancellables)
        viewModel.channelEvents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.receive(event) }
            .store(in: &cancellables)
        load()
    }

    private struct Slice: Equatable {
        let access: ChannelAccess
        let linkUp: Bool
        /// The network's vocabulary has arrived and says this letter is a list. ⚠ Part of
        /// readiness, not just of editing: a snapshot with a null `modeSpec` is a connected,
        /// joined channel whose fetch can still fail — and when the spec lands, that is the edge
        /// that pays the owed fetch.
        let listed: Bool
        var ready: Bool { linkUp && access.joined && listed }
    }

    private func linkMoved(_ slice: Slice) {
        let wasReady = lastSlice?.ready ?? false
        lastSlice = slice
        // A fetched list stops being kept current the moment readiness is lost — a part, or an IRC
        // reconnect under a live socket, neither of which is a new snapshot — since the changes in
        // the gap won't arrive as live rows. So is one still LOADING: its answer may describe the
        // channel from before. A REFUSED fetch isn't owed again: losing readiness is no reason to
        // ask a server that said no. (Android's ModeListModel.linkMoved, plus the loading case.)
        if wasReady, !slice.ready {
            if case .failed = status {} else { fetchOwed = true }
        }
        if fetchOwed, slice.ready, !wasReady {
            fetchOwed = false
            load()
        } else {
            render()
        }
    }

    private lazy var addButton = UIBarButtonItem(
        systemItem: .add, primaryAction: UIAction { [weak self] _ in self?.promptForEntry() }
    )

    private func receive(_ event: ChatViewModel.ChannelEvent) {
        switch event {
        case .resynced:
            // The store's word on the link is this socket's now: ask at once if it's up, else
            // when it comes up.
            if lastSlice?.ready == true {
                load()
            } else {
                fetchOwed = true
            }
        case .line(let lineKey, let message):
            guard lineKey.id == key.id else { return }
            switch message.type {
            case .mode: rowsSinceFetch.append(message)
            case .error: refusals.note(message.text ?? "")
            default: return
            }
            render()
        }
    }

    private func load() {
        fetch += 1
        let mine = fetch
        status = .loading
        rowsSinceFetch = []
        render()
        Task { [weak self, viewModel, key, letter] in
            let result = await viewModel.fetchModeList(key, letter: letter)
            guard let self, mine == fetch else { return }
            refreshControl?.endRefreshing()
            switch result {
            case .entries(let entries): status = .ready(entries)
            case .offline:
                status = .failed("Not connected.")
                // Asked again when the link comes up.
                fetchOwed = true
            case .failed(let message):
                status = .failed(message)
                // Asked before the link was ready (the vocabulary hadn't arrived, say): ask again
                // when it is. A refusal from a ready link stands until the user refreshes.
                if lastSlice?.ready != true { fetchOwed = true }
            }
            render()
        }
    }

    // MARK: - Changes

    private func promptForEntry() {
        let alert = UIAlertController(title: "Add to \(title ?? "List")", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "nick!user@host"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.spellCheckingType = .no
            field.keyboardType = .asciiCapable
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self, weak alert] _ in
            let mask = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !mask.isEmpty else { return }
            self?.change("+", mask)
        })
        present(alert, animated: true)
    }

    /// Send one `±letter mask`. The entry appears or goes when the channel's MODE line comes
    /// back — nothing is applied here.
    private func change(_ sign: Character, _ mask: String) {
        guard !busy else { return }
        // Checked now, not when the button was drawn: a reconnect can bring a vocabulary in which
        // this letter isn't a list — or is an owner grant (`q`) — and a stale button would send it.
        guard viewModel.state.networks[key.networkId ?? -1]?.modeSpec?.list.contains(letter) == true else {
            actionError = "This network doesn't have this list right now."
            render()
            return
        }
        // …and whether we may still change it: an Add alert or a context menu can outlive a deop
        // or a part, and sending from one would ask for a 482.
        guard viewModel.state.channelAccess(key).canEditModes else {
            actionError = "Only channel operators can change this list."
            render()
            return
        }
        // One IRC parameter: the server refuses a mask with a space in it, so say so here.
        if mask.contains(where: \.isWhitespace) {
            actionError = "A mask can't contain spaces."
            render()
            return
        }
        busy = true
        actionError = nil
        refusals.arm()
        render()
        Task { [weak self, viewModel, key, letter] in
            let failure = await viewModel.setChannelModes(
                key, changes: [OutgoingModeChange(sign: sign, letter: letter, param: mask)]
            )
            guard let self else { return }
            busy = false
            actionError = failure?.message
            render()
        }
    }

    // MARK: - Render

    private func render() {
        guard isViewLoaded else { return }
        let next: [ModeListEntry]
        switch status {
        case .ready(let entries): next = ChannelModeForm.patch(entries, with: rowsSinceFetch, letter: letter)
        case .loading, .failed: next = []
        }
        let errors = [actionError].compactMap { $0 } + refusals.current
        let drawing = Drawn(
            status: status, shown: next, canEdit: lastSlice.map { $0.access.canEditModes && $0.listed } ?? false,
            busy: busy, footer: errors.isEmpty ? nil : errors.joined(separator: "\n")
        )
        guard drawing != drawn else { return }
        drawn = drawing
        shown = drawing.shown
        canEdit = drawing.canEdit
        navigationItem.rightBarButtonItem = canEdit ? addButton : nil
        addButton.isEnabled = !busy
        tableView.backgroundView = backgroundLabel()
        tableView.reloadData()
    }

    /// Loading, the fetch's refusal, or an empty list — said in place of rows.
    private func backgroundLabel() -> UIView? {
        let text: String
        switch status {
        case .loading:
            guard refreshControl?.isRefreshing != true else { return nil }
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            return spinner
        case .failed(let message): text = message
        case .ready: guard shown.isEmpty else { return nil }; text = "Nothing here."
        }
        let label = UILabel()
        label.text = text
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { shown.count }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        drawn?.footer
    }

    override func tableView(_ tableView: UITableView, willDisplayFooterView view: UIView, forSection section: Int) {
        // The footer only ever carries a refusal.
        (view as? UITableViewHeaderFooterView)?.textLabel?.textColor = .systemRed
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "entry", for: indexPath)
        let entry = shown[indexPath.row]
        var config = UIListContentConfiguration.subtitleCell()
        config.text = entry.mask
        config.textProperties.font = .monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular
        )
        config.textProperties.numberOfLines = 0
        config.secondaryText = Self.meta(entry)
        config.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = config
        cell.selectionStyle = .none
        return cell
    }

    /// "by alice · 1 Sep 2026 at 10:00", from what the server knew.
    private static func meta(_ entry: ModeListEntry) -> String? {
        let parts = [
            entry.setBy.map { "by \(ChannelModeForm.setterNick($0))" },
            entry.setAt?.formatted(date: .abbreviated, time: .shortened),
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    override func tableView(
        _ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard canEdit, shown.indices.contains(indexPath.row) else { return nil }
        let entry = shown[indexPath.row]
        let remove = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, done in
            // Not deleted from the table here: the entry goes when the channel's -letter comes back.
            self?.change("-", entry.mask)
            done(false)
        }
        let configuration = UISwipeActionsConfiguration(actions: [remove])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard shown.indices.contains(indexPath.row) else { return nil }
        let entry = shown[indexPath.row]
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            var actions: [UIMenuElement] = [
                UIAction(title: "Copy Mask", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = entry.mask
                },
            ]
            if self?.canEdit == true {
                actions.append(UIAction(title: "Remove", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                    self?.change("-", entry.mask)
                })
            }
            return UIMenu(children: actions)
        })
    }
}
