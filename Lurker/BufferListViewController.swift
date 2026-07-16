// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine
import LurkerKit
import UIKit

/// Screen 2: the buffer list, rendered from `ChatState`. Flat and only deterministically
/// ordered — grouping by network, unread badges, and pins are #8. Against a real account
/// this list will be long.
final class BufferListViewController: UITableViewController {
    private let viewModel: ChatViewModel
    private var cancellables = Set<AnyCancellable>()

    private var state = ChatState()
    private var buffers: [Buffer] = []

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
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "buffer")

        viewModel.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.apply(state) }
            .store(in: &cancellables)
        apply(viewModel.state)
    }

    private func apply(_ state: ChatState) {
        self.state = state
        // A stable order so the table doesn't flicker as frames arrive; the real grouping
        // by network is #8. System buffer (nil networkId) sorts last.
        buffers = state.buffers.values.sorted { lhs, rhs in
            (lhs.networkId ?? .max, lhs.target.lowercased()) < (rhs.networkId ?? .max, rhs.target.lowercased())
        }
        title = connectionTitle(for: state.connection)
        tableView.reloadData()
    }

    private func connectionTitle(for status: SocketStatus) -> String {
        switch status {
        case .connecting: return "Connecting…"
        case .connected: return "Buffers"
        case .reconnecting: return "Reconnecting…"
        }
    }

    private func subtitle(for buffer: Buffer) -> String {
        guard let networkId = buffer.networkId else { return "system" }
        return state.networks[networkId]?.name ?? "network"
    }

    @objc private func signOut() {
        // Revokes server-side + clears the Keychain; SceneDelegate returns us to sign-in.
        viewModel.logout()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        buffers.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "buffer", for: indexPath)
        let buffer = buffers[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = buffer.target
        content.secondaryText = subtitle(for: buffer)
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let buffer = buffers[indexPath.row]
        // Hydrate before pushing: channel/DM buffers arrive as empty shells, so without
        // this the chat screen would render blank until the first live message.
        viewModel.openBuffer(buffer.key)
        navigationController?.pushViewController(
            ChatViewController(viewModel: viewModel, buffer: buffer), animated: true
        )
    }
}
