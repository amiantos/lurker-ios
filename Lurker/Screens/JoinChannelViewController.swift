// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine
import LurkerKit
import UIKit

/// Join a channel: type its name, pick the network.
///
/// It replaces a `+` menu that listed every network and an alert per network. That shape put
/// the *rarer* half of the decision first — which network, a thing most accounts answer the
/// same way every time — and made it a menu you had to read before you could start typing the
/// thing you actually came to say. Worse, it grew with the account: five networks meant five
/// menu rows to scan past on the way to one text field.
///
/// Here the channel name is the first field and the keyboard is already up, and the network is
/// a picker sitting under it with a sensible default. A one-network account never touches it.
final class JoinChannelViewController: UITableViewController {

    private let viewModel: ChatViewModel
    private let onJoin: (Network, String) -> Void
    private var cancellables = Set<AnyCancellable>()
    private var networks: [Network] = []
    private var selected: Int?
    private var channel = ""

    init(viewModel: ChatViewModel, onJoin: @escaping (Network, String) -> Void) {
        self.viewModel = viewModel
        self.onJoin = onJoin
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Join Channel"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Join", primaryAction: UIAction { [weak self] _ in self?.join() }
        )
        tableView.register(FormTextCell.self, forCellReuseIdentifier: FormTextCell.reuseID)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "network")

        networks = BufferOrder.networks(viewModel.state.networks)
        // The first connected one, since a JOIN needs a socket to travel down. Falling back to
        // the first of any kind rather than nothing: the picker should always show a
        // selection, and Join stays disabled to say why it can't be used yet.
        selected = (networks.first { $0.state == .connected } ?? networks.first)?.id
        updateJoinButton()

        // A network finishing its connect while this sheet is open makes it selectable, so the
        // list follows the socket rather than a snapshot taken when the sheet opened.
        //
        // ⚠ Reloads the network SECTION only. A whole-table reload would rebuild the text
        // field above it and take the keyboard down mid-word — the same trap the network form
        // works around when a clear row changes.
        viewModel.statePublisher
            .map(\.networks)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                networks = BufferOrder.networks(state)
                if let selected, !networks.contains(where: { $0.id == selected }) { self.selected = nil }
                updateJoinButton()
                tableView.reloadSections(IndexSet(integer: 1), with: .none)
            }
            .store(in: &cancellables)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The name is what you came here to type, so the keyboard is up before you decide
        // anything else. The picker below has a default and can be ignored entirely.
        (tableView.cellForRow(at: IndexPath(row: 0, section: 0)) as? FormTextCell)?
            .field.becomeFirstResponder()
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 1 : networks.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? nil : "Network"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        // Said where it applies, because "#" is the part people leave off — and a channel is
        // any of the four sigils, so a name that already carries one is left alone.
        section == 0 ? "A # is added if you leave it off." : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            let cell = tableView.dequeueReusableCell(
                withIdentifier: FormTextCell.reuseID, for: indexPath
            ) as! FormTextCell
            cell.configure(label: "Channel", value: channel, placeholder: "#lurker")
            cell.typedAsIdentifier()
            cell.field.returnKeyType = .join
            cell.field.delegate = self
            cell.onChange = { [weak self] text in
                self?.channel = text
                self?.updateJoinButton()
            }
            return cell
        }

        let cell = tableView.dequeueReusableCell(withIdentifier: "network", for: indexPath)
        let network = networks[indexPath.row]
        let connected = network.state == .connected
        var content = cell.defaultContentConfiguration()
        content.text = network.displayName
        // Not disabled-looking-but-tappable: a JOIN with no socket to travel down goes
        // nowhere and nothing comes back to say so, which is the failure the old menu
        // prevented by greying these out. Shown rather than hidden because the network is
        // still yours, and a list that silently omits it just looks wrong.
        content.textProperties.color = connected ? .label : .secondaryLabel
        if !connected { content.secondaryText = "not connected" }
        cell.contentConfiguration = content
        cell.accessoryType = network.id == selected ? .checkmark : .none
        cell.selectionStyle = connected ? .default : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1 else { return }
        let network = networks[indexPath.row]
        guard network.state == .connected else { return }
        selected = network.id
        updateJoinButton()
        tableView.reloadSections(IndexSet(integer: 1), with: .none)
    }

    // MARK: - Joining

    /// The network this would join on, when there is one that could actually carry it.
    private var target: Network? {
        guard let selected, let network = networks.first(where: { $0.id == selected }),
              network.state == .connected
        else { return nil }
        return network
    }

    private func updateJoinButton() {
        // A bare sigil is not a name — `fold` strips one and lowercases, so "#" folds to
        // empty. Same test the join itself makes, so the button can't offer what the action
        // would refuse.
        navigationItem.rightBarButtonItem?.isEnabled =
            target != nil && !ChannelName.fold(channel.trimmingCharacters(in: .whitespaces)).isEmpty
    }

    private func join() {
        guard let target else { return }
        let typed = channel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ChannelName.fold(typed).isEmpty else { return }
        // Dismiss first, then hand over: the caller navigates to the new buffer, and pushing
        // a screen out from under a sheet that is still on its way down lands the reader on
        // an animation fighting itself.
        dismiss(animated: true) { [onJoin] in onJoin(target, typed) }
    }
}

extension JoinChannelViewController: UITextFieldDelegate {
    /// Return joins, when there's something to join. The keyboard's own key says "join", so
    /// it has to do what it says.
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if navigationItem.rightBarButtonItem?.isEnabled == true { join() }
        return false
    }
}
