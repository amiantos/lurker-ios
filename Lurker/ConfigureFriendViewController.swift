// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// Add or edit a friend — the iOS take on the web's Configure Friend modal.
///
/// A friend is a display name plus a set of watch nicks: (network, nick) pairs, one flagged
/// *primary* (the DM that opens when you tap the friend). The same person can be followed
/// under alts across networks, so this is a small repeater, not a single field. Presence is
/// server-derived off those nicks; this screen only edits the identity.
///
/// Presented modally in its own nav stack via `present(from:viewModel:editing:)`. It talks to
/// the server through `ChatViewModel.saveContact` / `deleteContact` and dismisses itself; the
/// list updates when the server's `contact-updated` / `contact-deleted` echo lands.
final class ConfigureFriendViewController: UITableViewController {
    private let viewModel: ChatViewModel
    private let editingContact: Contact?
    private let networks: [Network]

    private var displayName: String
    private var notifyOnline: Bool
    private var targets: [TargetDraft]

    /// One editable watch row. `id` is stable across add/remove so the network menu and the
    /// primary flag stay pinned to their row while the list shifts around them.
    private struct TargetDraft {
        let id = UUID()
        var networkId: Int
        var nick: String
        var isPrimary: Bool
    }

    private enum SectionKind {
        case name
        case targets
        case notify
        case remove
    }

    /// Present the editor in a modal nav stack. `editing` nil = add; `prefill` seeds a new
    /// friend from a nick you're looking at (a member row, a DM).
    static func present(
        from presenter: UIViewController,
        viewModel: ChatViewModel,
        editing: Contact?,
        prefill: (networkId: Int, nick: String)? = nil
    ) {
        let vc = ConfigureFriendViewController(viewModel: viewModel, editing: editing, prefill: prefill)
        presenter.present(UINavigationController(rootViewController: vc), animated: true)
    }

    init(viewModel: ChatViewModel, editing: Contact?, prefill: (networkId: Int, nick: String)?) {
        self.viewModel = viewModel
        self.editingContact = editing
        let sorted = viewModel.networks.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        self.networks = sorted

        var seededTargets: [TargetDraft]
        if let editing {
            self.displayName = editing.displayName
            self.notifyOnline = editing.notifyOnline
            seededTargets = editing.targets.map {
                TargetDraft(networkId: $0.networkId, nick: $0.nick, isPrimary: $0.isPrimary)
            }
        } else if let prefill {
            self.displayName = prefill.nick
            self.notifyOnline = false
            seededTargets = [TargetDraft(networkId: prefill.networkId, nick: prefill.nick, isPrimary: true)]
        } else {
            self.displayName = ""
            self.notifyOnline = false
            seededTargets = sorted.first.map { [TargetDraft(networkId: $0.id, nick: "", isPrimary: true)] } ?? []
        }
        // A friend must have exactly one primary. Keep the first flagged target (promote the
        // first if none is flagged) and clear the rest, so a seed carrying none OR several never
        // shows multiple selected radios or sends multiple primaries back to the server.
        let primaryIndex = seededTargets.firstIndex(where: { $0.isPrimary })
            ?? (seededTargets.isEmpty ? nil : 0)
        for i in seededTargets.indices { seededTargets[i].isPrimary = (i == primaryIndex) }
        self.targets = seededTargets

        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = editingContact == nil ? "Add Friend" : "Edit Friend"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .save, primaryAction: UIAction { [weak self] _ in self?.save() }
        )
        tableView.register(FriendTargetCell.self, forCellReuseIdentifier: FriendTargetCell.reuseID)
        tableView.keyboardDismissMode = .interactive
        updateSaveButton()
    }

    // MARK: - Layout

    /// Remove only exists when editing an existing friend.
    private var layout: [SectionKind] {
        editingContact == nil ? [.name, .targets, .notify] : [.name, .targets, .notify, .remove]
    }

    private var canSave: Bool {
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return targets.contains { validTarget($0) }
    }

    /// A row that would actually be saved: a non-blank nick on a network the account still has.
    private func validTarget(_ draft: TargetDraft) -> Bool {
        !draft.nick.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && networks.contains { $0.id == draft.networkId }
    }

    private func updateSaveButton() {
        navigationItem.rightBarButtonItem?.isEnabled = canSave
    }

    // MARK: - Save / delete

    private func save() {
        guard canSave else { return }
        let valid = targets.filter(validTarget)
        // If the row the user flagged primary was left blank it's filtered out here, leaving no
        // primary. Rather than let the server pick a fallback, promote the first valid target so
        // the saved friend's primary DM is deterministic and matches what's about to show.
        let hasPrimary = valid.contains { $0.isPrimary }
        let saveTargets = valid.enumerated().map { index, draft in
            ContactTarget(
                networkId: draft.networkId,
                nick: draft.nick.trimmingCharacters(in: .whitespacesAndNewlines),
                isPrimary: hasPrimary ? draft.isPrimary : index == 0
            )
        }
        viewModel.saveContact(
            id: editingContact?.id,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            notifyOnline: notifyOnline,
            targets: saveTargets
        )
        dismiss(animated: true)
    }

    private func confirmDelete() {
        guard let contact = editingContact else { return }
        let sheet = UIAlertController(
            title: "Remove \(contact.displayName)?",
            message: "This stops watching their nicks. Your DM history is kept.",
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Remove Friend", style: .destructive) { [weak self] _ in
            self?.viewModel.deleteContact(id: contact.id)
            self?.dismiss(animated: true)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        // On iPad an action sheet needs an anchor; the Remove row is the natural one.
        if let remove = layout.firstIndex(of: .remove) {
            let cell = tableView.cellForRow(at: IndexPath(row: 0, section: remove))
            sheet.popoverPresentationController?.sourceView = cell
            sheet.popoverPresentationController?.sourceRect = cell?.bounds ?? .zero
        }
        present(sheet, animated: true)
    }

    // MARK: - Target mutations (resolved by stable id, robust to row shifts)

    private func setNick(_ text: String, id: UUID) {
        guard let index = targets.firstIndex(where: { $0.id == id }) else { return }
        targets[index].nick = text
        updateSaveButton()
    }

    private func setPrimary(id: UUID) {
        guard let targetSection = layout.firstIndex(of: .targets) else { return }
        for i in targets.indices { targets[i].isPrimary = targets[i].id == id }
        // Patch each visible row's radio in place rather than reloading the section, so tapping
        // one row's primary radio doesn't drop the keyboard from a nick field being edited.
        for i in targets.indices {
            let cell = tableView.cellForRow(at: IndexPath(row: i, section: targetSection)) as? FriendTargetCell
            cell?.setPrimary(targets[i].isPrimary)
        }
        updateSaveButton()
    }

    private func addTarget() {
        guard let firstNetworkId = networks.first?.id else { return }
        targets.append(TargetDraft(networkId: firstNetworkId, nick: "", isPrimary: targets.isEmpty))
        if let targetSection = layout.firstIndex(of: .targets) {
            tableView.reloadSections(IndexSet(integer: targetSection), with: .automatic)
        }
        updateSaveButton()
    }

    private func deleteTarget(at row: Int) {
        guard row < targets.count else { return }
        let wasPrimary = targets[row].isPrimary
        targets.remove(at: row)
        // Losing the primary re-promotes the first survivor so a friend always has one.
        if wasPrimary, !targets.contains(where: { $0.isPrimary }), !targets.isEmpty {
            targets[0].isPrimary = true
        }
        if let targetSection = layout.firstIndex(of: .targets) {
            tableView.reloadSections(IndexSet(integer: targetSection), with: .automatic)
        }
        updateSaveButton()
    }

    private func setNetwork(_ networkId: Int, id: UUID) {
        guard let index = targets.firstIndex(where: { $0.id == id }) else { return }
        targets[index].networkId = networkId
        // Patch the chooser in place (no reload) so a nick being typed keeps its keyboard.
        if let targetSection = layout.firstIndex(of: .targets),
           let cell = tableView.cellForRow(at: IndexPath(row: index, section: targetSection)) as? FriendTargetCell {
            cell.setNetwork(title: networkName(networkId), menu: networkMenu(for: id))
        }
        updateSaveButton()
    }

    private func networkName(_ id: Int) -> String {
        networks.first { $0.id == id }?.name ?? "network"
    }

    /// The per-row network chooser. Actions look the draft up by id at tap time, so a menu
    /// built for one row still targets the right draft after rows above it are deleted.
    private func networkMenu(for id: UUID) -> UIMenu {
        let current = targets.first { $0.id == id }?.networkId
        return UIMenu(children: networks.map { network in
            UIAction(title: network.name, state: network.id == current ? .on : .off) { [weak self] _ in
                self?.setNetwork(network.id, id: id)
            }
        })
    }

    // MARK: - Table data source

    override func numberOfSections(in tableView: UITableView) -> Int { layout.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch layout[section] {
        case .name, .notify, .remove: return 1
        // The extra row is "Add nick"; with no networks there's nothing to add, so just the note.
        case .targets: return networks.isEmpty ? 1 : targets.count + 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch layout[section] {
        case .name: return nil
        case .targets: return "Watch nicks"
        case .notify: return nil
        case .remove: return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch layout[section] {
        case .targets:
            return networks.isEmpty
                ? nil
                : "The primary nick is the DM that opens when you tap the friend."
        case .notify:
            return "Presence depends on each network's MONITOR/away support, so it may be "
                + "unreliable."
        case .name, .remove:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch layout[indexPath.section] {
        case .name:
            return nameCell()
        case .targets:
            return targetSectionCell(at: indexPath.row)
        case .notify:
            return notifyCell()
        case .remove:
            return removeCell()
        }
    }

    // MARK: - Cells

    private func nameCell() -> UITableViewCell {
        let cell = UITableViewCell()
        let field = UITextField()
        field.placeholder = "Display name"
        field.text = displayName
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .done
        field.autocapitalizationType = .words
        field.translatesAutoresizingMaskIntoConstraints = false
        field.addAction(UIAction { [weak self, weak field] _ in
            self?.displayName = field?.text ?? ""
            self?.updateSaveButton()
        }, for: .editingChanged)
        field.addAction(UIAction { [weak field] _ in field?.resignFirstResponder() }, for: .editingDidEndOnExit)
        cell.contentView.addSubview(field)
        let margins = cell.contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            field.topAnchor.constraint(equalTo: margins.topAnchor),
            field.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
        ])
        cell.selectionStyle = .none
        return cell
    }

    private func targetSectionCell(at row: Int) -> UITableViewCell {
        if networks.isEmpty {
            let cell = UITableViewCell()
            var content = UIListContentConfiguration.cell()
            content.text = "Add a network first to watch a friend."
            content.textProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
        }
        if row == targets.count {
            let cell = UITableViewCell()
            var content = UIListContentConfiguration.cell()
            content.text = "Add nick"
            content.image = UIImage(systemName: "plus")
            content.textProperties.color = view.tintColor
            content.imageProperties.tintColor = view.tintColor
            cell.contentConfiguration = content
            return cell
        }
        let draft = targets[row]
        let cell = tableView.dequeueReusableCell(withIdentifier: FriendTargetCell.reuseID) as! FriendTargetCell
        cell.configure(
            networkTitle: networkName(draft.networkId),
            networkMenu: networkMenu(for: draft.id),
            nick: draft.nick,
            isPrimary: draft.isPrimary,
            onNickChanged: { [weak self] text in self?.setNick(text, id: draft.id) },
            onPrimaryTapped: { [weak self] in self?.setPrimary(id: draft.id) }
        )
        return cell
    }

    private func notifyCell() -> UITableViewCell {
        let cell = UITableViewCell()
        var content = UIListContentConfiguration.cell()
        content.text = "Notify me when they come online"
        cell.contentConfiguration = content
        let toggle = UISwitch()
        toggle.isOn = notifyOnline
        toggle.addAction(UIAction { [weak self, weak toggle] _ in
            self?.notifyOnline = toggle?.isOn ?? false
        }, for: .valueChanged)
        cell.accessoryView = toggle
        cell.selectionStyle = .none
        return cell
    }

    private func removeCell() -> UITableViewCell {
        let cell = UITableViewCell()
        var content = UIListContentConfiguration.cell()
        content.text = "Remove Friend"
        content.textProperties.color = .systemRed
        content.textProperties.alignment = .center
        cell.contentConfiguration = content
        return cell
    }

    // MARK: - Table delegate

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch layout[indexPath.section] {
        case .targets:
            if !networks.isEmpty, indexPath.row == targets.count { addTarget() }
        case .remove:
            confirmDelete()
        case .name, .notify:
            break
        }
    }

    override func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        // Only real target rows delete — never the "Add nick" row or the other sections. Keep
        // at least one row so the editor always offers a nick to fill.
        guard layout[indexPath.section] == .targets, !networks.isEmpty,
              indexPath.row < targets.count, targets.count > 1
        else { return nil }
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
            self?.deleteTarget(at: indexPath.row)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }
}

/// One watch-nick row: a network chooser, the nick field, and a "primary" radio. The two
/// controls report edits through closures the view controller wires to the draft by id.
private final class FriendTargetCell: UITableViewCell {
    static let reuseID = "FriendTargetCell"

    private let networkButton = UIButton(type: .system)
    private let nickField = UITextField()
    private let primaryButton = UIButton(type: .system)
    private var onNickChanged: ((String) -> Void)?
    private var onPrimaryTapped: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        networkButton.showsMenuAsPrimaryAction = true
        networkButton.contentHorizontalAlignment = .leading
        networkButton.titleLabel?.adjustsFontForContentSizeCategory = true
        networkButton.titleLabel?.lineBreakMode = .byTruncatingTail
        // The network label keeps its intrinsic width and truncates last; the nick field is
        // what stretches to fill the row.
        networkButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        networkButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        nickField.placeholder = "nick"
        nickField.autocapitalizationType = .none
        nickField.autocorrectionType = .no
        nickField.spellCheckingType = .no
        nickField.returnKeyType = .done
        nickField.adjustsFontForContentSizeCategory = true
        nickField.font = .preferredFont(forTextStyle: .body)
        nickField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nickField.addTarget(self, action: #selector(nickEditingChanged), for: .editingChanged)
        nickField.addTarget(self, action: #selector(nickEditingDidEndOnExit), for: .editingDidEndOnExit)

        primaryButton.setContentHuggingPriority(.required, for: .horizontal)
        primaryButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        primaryButton.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)
        primaryButton.accessibilityLabel = "Primary nick"

        let stack = UIStackView(arrangedSubviews: [networkButton, nickField, primaryButton])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            stack.topAnchor.constraint(equalTo: margins.topAnchor),
            stack.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
        ])
        selectionStyle = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    func configure(
        networkTitle: String,
        networkMenu: UIMenu,
        nick: String,
        isPrimary: Bool,
        onNickChanged: @escaping (String) -> Void,
        onPrimaryTapped: @escaping () -> Void
    ) {
        setNetwork(title: networkTitle, menu: networkMenu)
        nickField.text = nick
        setPrimary(isPrimary)
        self.onNickChanged = onNickChanged
        self.onPrimaryTapped = onPrimaryTapped
    }

    /// Patch just the network chooser in place — no cell reload, so a nick field being edited in
    /// another row keeps its keyboard when the network changes.
    func setNetwork(title: String, menu: UIMenu) {
        networkButton.setTitle(title, for: .normal)
        networkButton.menu = menu
        networkButton.accessibilityLabel = "Network, \(title)"
    }

    /// Patch just the primary radio in place, for the same reason.
    func setPrimary(_ isPrimary: Bool) {
        let symbol = isPrimary ? "largecircle.fill.circle" : "circle"
        primaryButton.setImage(UIImage(systemName: symbol), for: .normal)
        primaryButton.tintColor = isPrimary ? tintColor : .tertiaryLabel
        primaryButton.accessibilityValue = isPrimary ? "on" : "off"
    }

    @objc private func nickEditingChanged() { onNickChanged?(nickField.text ?? "") }
    @objc private func nickEditingDidEndOnExit() { nickField.resignFirstResponder() }
    @objc private func primaryTapped() { onPrimaryTapped?() }
}
