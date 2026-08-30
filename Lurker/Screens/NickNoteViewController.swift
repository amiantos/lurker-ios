// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// Write what you know about someone (#12) — "lives in Berlin", "spouse: Pat".
///
/// The account's own memory aid, not a profile field: nobody else can see it, it is scoped to
/// one network (the same nick elsewhere may be a different person), and it follows the account
/// to the browser.
///
/// **Nothing is written locally.** Save asks, and the note changes when `nick-note-updated`
/// comes back — the same route a note written on the web takes to get here. So a save the
/// server refuses simply never appears, rather than showing here and quietly not existing.
final class NickNoteViewController: UITableViewController {
    private let viewModel: ChatViewModel
    private let networkId: Int
    private let nick: String

    /// The note as typed. Seeded once from the store and then owned by the editor — a live
    /// subscription here would rewrite the field under someone mid-sentence if another device
    /// saved while they were typing.
    private var draft: String

    /// What was there when the screen opened, so Save can tell "no change" from "cleared".
    private let original: String

    init(viewModel: ChatViewModel, networkId: Int, nick: String) {
        self.viewModel = viewModel
        self.networkId = networkId
        self.nick = nick
        let existing = viewModel.state.nickNotes.note(networkId: networkId, nick: nick)?.note ?? ""
        self.draft = existing
        self.original = existing
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Note"
        tableView.register(FormTextViewCell.self, forCellReuseIdentifier: FormTextViewCell.reuseID)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "action")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .save,
            primaryAction: UIAction { [weak self] _ in self?.save() }
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // A screen whose only content is one text field should not need a tap to start typing.
        (tableView.cellForRow(at: IndexPath(row: 0, section: 0)) as? FormTextViewCell)?.focus()
    }

    private func save() {
        // ⚠ Sent verbatim; the server trims and decides. A whitespace-only note is a DELETE
        // there, so pre-trimming here would only hide which of the two happened — the
        // `nick-note-updated` echo is what settles it either way.
        viewModel.setNickNote(networkId: networkId, nick: nick, note: draft)
        navigationController?.popViewController(animated: true)
    }

    // MARK: - Table

    /// The field, and — only once there is something to delete — a row that does it.
    ///
    /// Clearing has its own row rather than being "save an empty field", because an empty
    /// field is also what you see a moment after tapping Add Note, and a Save that sometimes
    /// deletes is a button whose meaning depends on state the user can't see.
    override func numberOfSections(in tableView: UITableView) -> Int {
        original.isEmpty ? 1 : 2
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? "Only you can see this. It syncs to your other devices." : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard indexPath.section == 0 else {
            let cell = tableView.dequeueReusableCell(withIdentifier: "action", for: indexPath)
            var content = UIListContentConfiguration.cell()
            content.text = "Delete Note"
            content.textProperties.color = .systemRed
            cell.contentConfiguration = content
            return cell
        }
        let cell = tableView.dequeueReusableCell(
            withIdentifier: FormTextViewCell.reuseID, for: indexPath
        ) as! FormTextViewCell
        cell.configure(label: "Note about \(nick)", value: draft, placeholder: "Anything worth remembering.")
        cell.onChange = { [weak self] text in self?.draft = text }
        cell.onHeightChange = { [weak tableView] in
            // Re-measure without reloading, which would resign the keyboard mid-typing.
            tableView?.beginUpdates()
            tableView?.endUpdates()
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1 else { return }
        let confirm = UIAlertController(
            title: "Delete this note?",
            message: "Your note about \(nick) will be removed from all your devices.",
            preferredStyle: .alert
        )
        confirm.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        confirm.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self else { return }
            // An empty note IS the delete verb — one frame shape for both, which is the
            // server's own encoding rather than a convention chosen here.
            viewModel.setNickNote(networkId: networkId, nick: nick, note: "")
            navigationController?.popViewController(animated: true)
        })
        present(confirm, animated: true)
    }
}
