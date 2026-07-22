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
            .removeDuplicates { $0.members[key] == $1.members[key] }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.apply(state) }
            .store(in: &cancellables)
        apply(viewModel.state)
    }

    private func apply(_ state: ChatState) {
        members = MemberPrefix.sorted(state.members[buffer.key.id] ?? [])
        title = members.isEmpty ? "Members" : "Members (\(members.count))"
        tableView.backgroundView = members.isEmpty ? emptyLabel : nil
        tableView.reloadData()
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
}
