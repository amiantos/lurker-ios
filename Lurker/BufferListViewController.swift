// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine
import LurkerKit
import UIKit

/// Screen 2: the buffer list, grouped by network, with unread + highlight badges. DMs are
/// first-class rows alongside channels (not a sub-list). Swipe a row to close it; "+" joins
/// a channel.
final class BufferListViewController: UITableViewController {
    private let viewModel: ChatViewModel
    private var cancellables = Set<AnyCancellable>()

    private struct Section {
        let title: String
        let buffers: [Buffer]
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
        title = "Connecting…"
        navigationItem.hidesBackButton = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Sign Out", style: .plain, target: self, action: #selector(signOut)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add, target: self, action: #selector(promptJoin)
        )
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "buffer")

        // The list only depends on networks, buffers, and connection state — a message
        // arriving in some channel shouldn't rebuild the whole list (badge counts arrive
        // as read-state updates, which do change `buffers`).
        viewModel.statePublisher
            .removeDuplicates {
                $0.networks == $1.networks && $0.buffers == $1.buffers && $0.connection == $1.connection
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.apply(state) }
            .store(in: &cancellables)
        apply(viewModel.state)
    }

    private func apply(_ state: ChatState) {
        self.state = state
        sections = buildSections(state)
        title = connectionTitle(for: state.connection)
        tableView.reloadData()
    }

    // MARK: - Sections

    private func buildSections(_ state: ChatState) -> [Section] {
        var byNetwork: [Int: [Buffer]] = [:]
        var systemBuffers: [Buffer] = []
        for buffer in state.buffers.values {
            if let networkId = buffer.networkId {
                byNetwork[networkId, default: []].append(buffer)
            } else {
                systemBuffers.append(buffer)
            }
        }

        var sections: [Section] = []
        let networks = state.networks.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
        var seen = Set<Int>()
        for network in networks {
            seen.insert(network.id)
            let buffers = (byNetwork[network.id] ?? []).sorted(by: Self.order)
            guard !buffers.isEmpty else { continue }
            sections.append(Section(title: header(for: network), buffers: buffers))
        }
        // Buffers whose network isn't in the roster yet (snapshot race).
        for (networkId, buffers) in byNetwork where !seen.contains(networkId) {
            sections.append(Section(title: "network", buffers: buffers.sorted(by: Self.order)))
        }
        if !systemBuffers.isEmpty {
            sections.append(Section(title: "System", buffers: systemBuffers.sorted(by: Self.order)))
        }
        return sections
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

    private func displayName(_ buffer: Buffer) -> String {
        switch buffer.kind {
        case .server: return "Server"
        case .system: return "System"
        default: return buffer.target
        }
    }

    // MARK: - Actions

    @objc private func signOut() {
        // Revokes server-side + clears the Keychain; SceneDelegate returns us to sign-in.
        viewModel.logout()
    }

    @objc private func promptJoin() {
        let networks = viewModel.networks.sorted { $0.name.lowercased() < $1.name.lowercased() }
        guard !networks.isEmpty else { return }
        guard networks.count > 1 else { return presentJoinAlert(network: networks[0]) }
        let sheet = UIAlertController(title: "Join a channel on…", message: nil, preferredStyle: .actionSheet)
        for network in networks {
            sheet.addAction(UIAlertAction(title: network.name, style: .default) { [weak self] _ in
                self?.presentJoinAlert(network: network)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(sheet, animated: true)
    }

    private func presentJoinAlert(network: Network) {
        let alert = UIAlertController(title: "Join channel", message: "on \(network.name)", preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = "#channel"
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Join", style: .default) { [weak self, weak alert] _ in
            self?.viewModel.joinChannel(networkId: network.id, channel: alert?.textFields?.first?.text ?? "")
        })
        present(alert, animated: true)
    }

    private func connectionTitle(for status: SocketStatus) -> String {
        switch status {
        case .connecting: return "Connecting…"
        case .connected: return "Lurker"
        case .reconnecting: return "Reconnecting…"
        }
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].buffers.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "buffer", for: indexPath)
        let buffer = sections[indexPath.section].buffers[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = displayName(buffer)
        cell.contentConfiguration = content
        cell.accessoryView = badge(unread: buffer.unread, highlights: buffer.highlights)
        cell.accessoryType = cell.accessoryView == nil ? .disclosureIndicator : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let buffer = sections[indexPath.section].buffers[indexPath.row]
        // Hydrate before pushing: channel/DM buffers arrive as empty shells.
        viewModel.openBuffer(buffer.key)
        navigationController?.pushViewController(
            ChatViewController(viewModel: viewModel, buffer: buffer), animated: true
        )
    }

    override func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let buffer = sections[indexPath.section].buffers[indexPath.row]
        // The server log and the system buffer can't be closed.
        guard buffer.kind != .server, buffer.kind != .system else { return nil }
        let title = buffer.kind == .channel ? "Leave" : "Close"
        let close = UIContextualAction(style: .destructive, title: title) { [weak self] _, _, done in
            self?.viewModel.closeBuffer(buffer.key)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [close])
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
