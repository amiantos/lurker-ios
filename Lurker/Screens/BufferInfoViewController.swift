// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine
import LurkerKit
import UIKit

/// What this buffer *is*, rather than what's been said in it — the title pill expands into
/// this. A channel gets its topic, a count of who's here, and how it notifies; a DM gets
/// the person and how it notifies; a server log gets the connection behind it and the
/// verbs that change it (#152).
///
/// The pill means the same thing on every buffer: "about this one". That's why a DM lands
/// here and not straight in a whois — whois is about a *person*, and a person is one of
/// the things a DM is about, not the whole of it. It gets a row that leads there (#12),
/// the same way a channel's members do, so the pill keeps one meaning and whois still has
/// somewhere to live. That row is live now.
///
/// Notification rows are placeholders and say so. The per-channel flag they'll drive
/// (`notify_always`) already exists server-side and already rides the snapshot, but the
/// client doesn't parse it yet — so there's no honest state to render, and a switch that
/// silently does nothing is worse than one that admits it.
final class BufferInfoViewController: UITableViewController {
    private let viewModel: ChatViewModel
    private let buffer: Buffer
    private var cancellables = Set<AnyCancellable>()

    /// Opening the member list is the chat screen's job — it owns the sheet-presentation
    /// rules (and the guard against stacking two sheets). This screen only knows the row
    /// was tapped.
    var onShowMembers: (() -> Void)?

    /// Search, scoped to this buffer. Handed back for the same reason members is: presenting
    /// belongs to the chat screen, which owns the one-sheet-at-a-time rule.
    var onSearchBuffer: ((String) -> Void)?

    /// Go to a conversation — what the profile pushed from the Whois row needs when its Send
    /// Message or a channel row is tapped. Passed straight through.
    var onOpenBuffer: ((BufferKey) -> Void)?

    /// What the table is showing. The next build is compared against it to decide whether
    /// there is anything to reload — see `render`.
    private var sections: [Section] = []

    /// The most recent refusal of a connection verb, shown under the Connection section.
    ///
    /// A footer rather than an alert, for the reason the networks screen uses the row's
    /// subtitle: the answer arrives on its own schedule, and an alert competing with whatever
    /// the user did during the round trip is one UIKit drops. It clears on the next attempt,
    /// and when the connection moves — see `render`.
    private var actionError: String?

    /// Which attempt may write `actionError`. Bumped per tap, so a slow earlier request
    /// can't answer for a later one — see `perform`.
    private var attempt = 0

    /// The connection as last rendered, so a state event that moves it retires a refusal
    /// that was about the old one.
    private var shownConnection: NetworkRow?

    init(viewModel: ChatViewModel, buffer: Buffer) {
        self.viewModel = viewModel
        self.buffer = buffer
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            }
        )
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "info")

        // Every emission, deduped on what this screen would DRAW rather than on a hand-kept
        // list of the inputs it draws from. The list drifted the moment it was written: it
        // compared the topic, the visible-member count and the connection, and missed the
        // network's name — which the search row reads for its `on:` half, and which arrives
        // late for a network the snapshot named before the roster did (#136). Building the
        // sections costs what the predicate cost (one `visibleMembers` count per emission, on
        // a busy channel), and comparing the result can't miss an input.
        viewModel.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.render(state) }
            .store(in: &cancellables)
        render(viewModel.state)

        // Connect is offered off `Network.blocked`, which the store learns from the roster —
        // read when the socket opens, and otherwise only when something writes a network. The
        // networks screen re-reads the roster on every appearance, so without this the two
        // could disagree about an allowlist change for the life of the socket: one offering
        // Connect, this sheet withholding it. Same cadence, then; the answer folds into state
        // and `render` picks it up.
        if buffer.kind == .server {
            Task { [viewModel] in await viewModel.refreshNetworks() }
        }
    }

    // MARK: - Model

    private enum Row: Equatable {
        case topic(String?)
        case members(Int)
        case whois
        /// Search pre-scoped to this buffer; the payload is the `in:`/`on:` prefix to seed the
        /// query field with.
        case search(scope: String)
        case notifyPlaceholder(title: String)
        /// The network's connection, as a status line.
        case connection(NetworkRow)
        /// One verb that changes it. Only the non-destructive ones reach this sheet — see
        /// `NetworkRow.connectionActions`.
        case networkAction(NetworkAction)
    }

    private struct Section: Equatable {
        var header: String?
        var footer: String?
        var rows: [Row]
    }

    /// Draw `state`, if it changes anything on screen.
    private func render(_ state: ChatState) {
        // The title follows state like everything else here, rather than being read once: a
        // network the snapshot named before the roster did has no name yet (#136), and now
        // that a server buffer's sheet re-reads the roster on open, the name can land while
        // this sheet is up — a title read in `viewDidLoad` would keep saying "Server".
        let name = buffer.displayName(networkName: buffer.networkId.flatMap { state.networks[$0]?.name })
        if title != name { title = name }
        // A refusal is about the connection as it was when the verb was sent. Once the
        // connection moves — the network's own retry succeeding under a failed Disconnect, say
        // — the footer would sit under rows that contradict it, with no way to clear it short
        // of another verb. The networks screen retires its refusal on a state change too.
        let connection = Self.connectionRow(in: state, networkId: buffer.networkId)
        if connection != shownConnection {
            shownConnection = connection
            actionError = nil
        }
        let next = sections(for: state)
        guard next != sections else { return }
        sections = next
        tableView.backgroundView = sections.isEmpty ? emptyLabel : nil
        tableView.reloadData()
    }

    /// Read the live copy out of state rather than trusting the buffer this screen was
    /// constructed with — that one is a value, snapshotted whenever the chat screen was
    /// built, so its topic is frozen at that moment.
    private func sections(for state: ChatState) -> [Section] {
        let key = buffer.key.id
        let live = state.buffers[key] ?? buffer
        // Visible members, not every member: this count sits one tap from the nicklist, and
        // the two disagreeing about how many people are in the channel reads as a bug in
        // whichever the reader looks at second.
        let memberCount = state.visibleMembers(in: buffer.key).count

        // The `on:` half needs the network's *name*, which only the roster has. Nil for a
        // buffer with no meaningful scope, and the row simply isn't offered then.
        let scopeRows: [Row] = SearchQuery.scope(
            for: live,
            networkName: live.networkId.flatMap { state.networks[$0]?.name }
        ).map { [.search(scope: $0)] } ?? []
        switch buffer.kind {
        case .channel:
            return [
                Section(header: "Topic", footer: nil, rows: [.topic(live.topic)]),
                Section(header: nil, footer: nil, rows: [.members(memberCount)] + scopeRows),
                notifications,
            ]
        case .dm:
            return [
                Section(header: nil, footer: nil, rows: [.whois] + scopeRows),
                notifications,
            ]
        case .server:
            // A server log has no topic or members; the one thing it is *about* is the
            // connection behind it, so this is where that connection is managed (#152) — the
            // same verbs as the networks screen, minus Delete, which belongs with the roster.
            return connectionSection(in: state).map { [$0] } ?? []
        case .system:
            // Nothing here is a setting: the app's own buffer has no topic, no members, no
            // connection of its own, and nothing to notify about.
            return []
        }
    }

    /// The connection behind a server log, and what can be done to it right now.
    ///
    /// Nil only when the store has no row for the network — a transient, since a server buffer
    /// belongs to a network the snapshot named. The sheet then shows `emptyLabel` rather than
    /// a Connect offer for a network it can't describe.
    private func connectionSection(in state: ChatState) -> Section? {
        guard let row = Self.connectionRow(in: state, networkId: buffer.networkId) else { return nil }
        // The refusal takes the footer, as it takes the subtitle on the networks screen: what
        // the server just said beats a standing note. Blocked gets the sentence that screen
        // uses, whether or not anything is offered — a connected-but-blocked network still
        // needs to say why Reconnect is missing.
        let footer = actionError ?? (row.isBlocked ? NetworkRow.blockedExplanation : nil)
        return Section(
            header: "Connection", footer: footer,
            rows: [.connection(row)] + row.connectionActions.map { .networkAction($0) }
        )
    }

    /// The network's connection as the model the networks screen draws, or nil when the store
    /// doesn't hold the network. `networkId` is optional because the system buffer has none.
    private static func connectionRow(in state: ChatState, networkId: Int?) -> NetworkRow? {
        guard let networkId, let network = state.networks[networkId] else { return nil }
        return NetworkRow(connection: network.state, isBlocked: network.blocked)
    }

    /// Shown instead of an empty table when there is nothing to list: the system buffer, which
    /// has no topic, no members, no connection of its own and nothing to notify about — and,
    /// for the moment before the store holds its network, a server log.
    ///
    /// The pill opens this sheet from every buffer — that consistency is the point of the pill —
    /// so the honest answer to "what is there to configure here" has to be a sentence rather than
    /// a blank sheet with a Done button.
    private lazy var emptyLabel: UILabel = {
        let label = UILabel()
        label.text = "This buffer has no settings."
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()

    private var notifications: Section {
        Section(
            header: "Notifications",
            footer: "Not wired up yet — these don't change anything.",
            rows: [.notifyPlaceholder(title: "Notify me about every message")]
        )
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].header
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sections[section].footer
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "info", for: indexPath)
        cell.accessoryType = .none
        cell.accessoryView = nil
        cell.selectionStyle = .none

        switch sections[indexPath.section].rows[indexPath.row] {
        case .topic(let topic):
            var content = UIListContentConfiguration.cell()
            // A topic is prose of arbitrary length, not a label — it wraps rather than
            // truncating, because a truncated topic is the half you don't need.
            content.textProperties.numberOfLines = 0
            content.text = topic?.isEmpty == false ? topic : "No topic set."
            content.textProperties.color = topic?.isEmpty == false ? .label : .secondaryLabel
            cell.contentConfiguration = content

        case .members(let count):
            var content = UIListContentConfiguration.valueCell()
            content.text = "Members"
            content.secondaryText = String(count)
            content.image = UIImage(systemName: "person.2")
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default

        case .whois:
            var content = UIListContentConfiguration.cell()
            // No nick alongside it — the title already says whose DM this is, and a "Whois
            // … amiantos" row under an "amiantos" title just says it twice.
            content.text = "Whois"
            content.image = UIImage(systemName: "person.crop.circle")
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default

        case .search:
            var content = UIListContentConfiguration.cell()
            // Named for the buffer rather than "Search in Buffer": the sheet's title already
            // says which one, and this is the panel *about* it.
            content.text = "Search This Conversation"
            content.image = UIImage(systemName: "magnifyingglass")
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default

        case .notifyPlaceholder(let title):
            var content = UIListContentConfiguration.cell()
            content.text = title
            content.textProperties.color = .tertiaryLabel
            cell.contentConfiguration = content
            let toggle = UISwitch()
            toggle.isOn = false
            toggle.isEnabled = false
            cell.accessoryView = toggle

        case .connection(let row):
            var content = UIListContentConfiguration.valueCell()
            content.text = "Status"
            content.secondaryText = row.connection.label
            // The networks screen's row in miniature, and the same light the pill behind this
            // sheet is showing.
            content.setStatusDot(row.light)
            cell.contentConfiguration = content

        case .networkAction(let action):
            var content = UIListContentConfiguration.cell()
            content.text = action.title
            content.image = UIImage(systemName: action.symbolName)
            cell.contentConfiguration = content
            cell.selectionStyle = .default
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        // Dismiss first, then hand back: the chat screen presents these from itself and
        // refuses while it already has something presented, so opening from under this sheet
        // would silently no-op.
        switch sections[indexPath.section].rows[indexPath.row] {
        case .members:
            dismiss(animated: true) { [onShowMembers] in onShowMembers?() }
        case .search(let scope):
            dismiss(animated: true) { [onSearchBuffer] in onSearchBuffer?(scope) }
        case .whois:
            // Pushed into this sheet rather than dismissing first, unlike Members and Search
            // above. Those two hand back to the chat screen because it owns presenting them;
            // a profile has no such owner and no reason to close the panel you opened it from,
            // so Back returns here.
            guard let networkId = buffer.networkId else { return }
            let profile = UserProfileViewController(
                viewModel: viewModel, networkId: networkId, nick: buffer.target
            )
            profile.onOpenBuffer = onOpenBuffer
            navigationController?.pushViewController(profile, animated: true)
        case .networkAction(let action):
            perform(action)
        case .topic, .notifyPlaceholder, .connection:
            break
        }
    }

    /// Run a connection verb and pin its refusal under the section.
    ///
    /// Nothing is applied optimistically, for the reason the networks screen applies nothing:
    /// the server acknowledges the instruction and the transition arrives separately as
    /// `state` events, so the rows move — Connect becoming Disconnect — when the store says
    /// they have, not when the tap did. The sheet stays up so that is visible.
    ///
    /// A refusal that arrives after Done was tapped goes nowhere: this sheet is what shows
    /// it, and the sheet is gone. The slash-command form of the same verb prints into the
    /// buffer instead; here, a pill light that didn't move is what's left to notice.
    private func perform(_ action: NetworkAction) {
        guard let networkId = buffer.networkId else { return }
        // Whatever the last attempt said is now stale — a new attempt is under way. The
        // counter keeps a SLOW earlier attempt from answering for this one: tap Disconnect,
        // watch the row flip to Connect on the state event, tap that, and the first request's
        // late refusal (a timeout, say) would otherwise land under the second.
        attempt += 1
        let mine = attempt
        let sentAgainst = shownConnection
        setActionError(nil)
        Task { [weak self, viewModel] in
            let refusal = await viewModel.perform(action, on: networkId)
            // `self` resolved after the await, not before: a sheet dismissed mid-round-trip is
            // released rather than kept alive to paint a footer nobody can see.
            //
            // The connection check is the other half of "a refusal is about the connection as
            // it was when the verb was sent". `render` retires a refusal when the connection
            // moves, but one that arrives AFTER the move would still land: a Disconnect whose
            // reply timed out after the server had already acted on it would print "Disconnect
            // failed" under a row that says Offline.
            guard let self, mine == attempt, shownConnection == sentAgainst, let refusal else { return }
            setActionError(refusal)
        }
    }

    private func setActionError(_ message: String?) {
        guard actionError != message else { return }
        actionError = message
        render(viewModel.state)
    }
}
