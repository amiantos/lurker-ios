// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import UIKit

/// Screen 2: the buffer list, built from the `backlog` frames the server ships on
/// connect (one per buffer). Flat and unsorted on purpose — no grouping by network,
/// no unread badges, no pins. Against a real account this list will be long.
final class BufferListViewController: UITableViewController {
    private let client: LurkerClient

    init(client: LurkerClient) {
        self.client = client
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Connecting…"
        navigationItem.hidesBackButton = true
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "buffer")

        client.onBuffersChanged = { [weak self] in
            self?.tableView.reloadData()
        }
        client.onConnectionChanged = { [weak self] connected in
            self?.title = connected ? "Buffers" : "Disconnected"
        }
        client.onStatus = { [weak self] message in
            guard let message, let self else { return }
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            self.present(alert, animated: true)
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        client.buffers.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "buffer", for: indexPath)
        let buffer = client.buffers[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = buffer.target
        content.secondaryText = buffer.networkName
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let buffer = client.buffers[indexPath.row]
        // Hydrate before pushing: channel/DM buffers arrive as empty shells, so without
        // this the chat screen would render blank.
        client.open(buffer)
        navigationController?.pushViewController(
            ChatViewController(client: client, buffer: buffer), animated: true
        )
    }
}
