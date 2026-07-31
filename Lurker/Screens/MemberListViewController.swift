// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine
import LurkerKit
import UIKit

/// The nick list, summoned by a swipe in from the right edge.
///
/// Deliberately a placeholder for the real member list (#12): it shows who's here, ranked,
/// with away state — and nothing else. No whois, no per-member actions.
///
/// The list is live (#30): the store folds join/part/quit/kick/nick into
/// `ChatState.members` and applies the server's `names`/`member-update` broadcasts, so
/// what renders here tracks the channel, not the last connect. This view just observes.
final class MemberListViewController: UITableViewController {
    private let viewModel: ChatViewModel
    private let buffer: Buffer
    private var cancellables = Set<AnyCancellable>()

    private var members: [Member] = []

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
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "member")

        let key = buffer.key.id
        viewModel.statePublisher
            // The ignore set decides who's *listed*, not just who's in the room, so a rule
            // arriving from another device has to wake this screen the same way a join does.
            // Compared by identity: the store replaces it wholesale on every change and never
            // mutates one in place, so `===` is exactly "the rules are the same rules".
            .removeDuplicates { $0.members[key] == $1.members[key] && $0.ignores === $1.ignores }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.apply(state) }
            .store(in: &cancellables)
        apply(viewModel.state)
    }

    private func apply(_ state: ChatState) {
        members = MemberPrefix.sorted(Self.visibleMembers(state, buffer: buffer))
        title = members.isEmpty ? "Members" : "Members (\(members.count))"
        tableView.backgroundView = members.isEmpty ? emptyLabel : nil
        tableView.reloadData()
    }

    /// The channel's members minus anyone an ignore rule erases (lurker #301).
    ///
    /// Only a whole-identity `ALL` rule removes somebody — see `IgnoreMatch.isMemberHidden`.
    /// A content, level-scoped or `NOHIGHLIGHT` rule leaves them listed, because they are
    /// still in the channel and still talking, and a nicklist that disagreed with who is
    /// actually present would be lying about the room rather than filtering it.
    ///
    /// You are always visible. A hostmask rule can legitimately cover your own nick (a shared
    /// bouncer host, a wildcard on the network you're on), and disappearing yourself from your
    /// own nicklist is never what such a rule meant.
    private static func visibleMembers(_ state: ChatState, buffer: Buffer) -> [Member] {
        let members = state.members[buffer.key.id] ?? []
        guard !state.ignores.isEmpty(for: buffer.networkId) else { return members }
        let ownNick = buffer.networkId.flatMap { state.networks[$0]?.nick }?.lowercased()
        return members.filter { member in
            if let ownNick, member.nick.lowercased() == ownNick { return true }
            return !state.ignores.isMemberHidden(
                networkId: buffer.networkId,
                nick: member.nick,
                userhost: member.userhost,
                channel: buffer.target
            )
        }
    }

    /// Says which of the two reasons the list is empty, because they need different things
    /// from the user: a DM has nobody to list and never will, while a channel with no
    /// members means we haven't been told yet.
    ///
    /// Built once — the text depends only on this screen's buffer, and `apply` runs on
    /// every state change that reaches us.
    private lazy var emptyLabel: UILabel = {
        let label = UILabel()
        switch buffer.kind {
        case .channel: label.text = "No members yet."
        case .dm: label.text = "Direct messages have no member list."
        case .server, .system: label.text = "This buffer has no member list."
        }
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()

    // MARK: - Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        members.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "member", for: indexPath)
        let member = members[indexPath.row]
        var content = UIListContentConfiguration.cell()
        let prefix = MemberPrefix.of(member.modes)
        content.text = prefix + member.nick
        // Away members stay in place rather than sorting to the bottom — you look for a
        // nick where you last saw it — and are dimmed instead.
        content.textProperties.color = member.away ? .tertiaryLabel : .label
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }

    /// Long-press a member to add (or edit) them as a friend — the web client's primary way in,
    /// straight off a nick you're looking at. Only channels have a network to watch on.
    override func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let networkId = buffer.networkId, indexPath.row < members.count else { return nil }
        let nick = members[indexPath.row].nick
        // Edit the contact already watching this (network, nick), else add a new one prefilled.
        let existing = viewModel.contacts.first { contact in
            contact.targets.contains { $0.networkId == networkId && $0.nick.lowercased() == nick.lowercased() }
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let title = existing == nil ? "Add Friend…" : "Edit Friend…"
            return UIMenu(children: [
                UIAction(title: title, image: UIImage(systemName: "person.badge.plus")) { _ in
                    guard let self else { return }
                    ConfigureFriendViewController.present(
                        from: self,
                        viewModel: self.viewModel,
                        editing: existing,
                        prefill: existing == nil ? (networkId, nick) : nil
                    )
                },
            ])
        }
    }
}
