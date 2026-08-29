// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// Add or edit a network (#11). The screen that makes a fresh install usable without a
/// browser.
///
/// One class for both, because they are the same form: the differences are a title, a save
/// verb, one create-only section, and whether the secret rows offer to clear something. Two
/// classes would be two copies of fourteen fields, and the copies would drift.
///
/// **Nothing here is written to the draft at save time.** Every cell reports changes as they
/// happen, because a table dequeues cells that scroll out of view — a form that read its
/// values back from its cells would lose whatever was typed above the fold.
final class NetworkFormViewController: UITableViewController {

    private enum Row: Equatable {
        case name, host, port, tls
        case nick, realname
        case saslAccount, saslPassword, clearSaslPassword
        case serverPassword, clearServerPassword
        case defaultChannel
        case connectCommands, autoconnect, verifyCertificate
    }

    private struct Section {
        let header: String?
        let footer: String?
        let rows: [Row]
    }

    /// The network being edited, or nil when adding. Also the source of `has_password` — the
    /// only way to know a secret exists, since its value is never sent to us.
    ///
    /// Not named `editing`: `UIViewController` already has one, and shadowing it compiles as
    /// an override attempt rather than a new property.
    private let existing: NetworkConfig?
    private let viewModel: ChatViewModel
    private let onSaved: () -> Void
    private var draft: NetworkDraft
    private var sections: [Section] = []
    private var saving = false
    /// Why the last save was refused. The server's wording where it gave any — it knows about
    /// blocked hosts and paused accounts, and this client is guessing.
    private var error: String?

    /// A brand-new network, optionally prefilled from a preset (the picker is #11's last PR).
    init(viewModel: ChatViewModel, draft: NetworkDraft = NetworkDraft(), onSaved: @escaping () -> Void) {
        self.viewModel = viewModel
        self.existing = nil
        self.draft = draft
        self.onSaved = onSaved
        super.init(style: .insetGrouped)
    }

    init(viewModel: ChatViewModel, editing config: NetworkConfig, onSaved: @escaping () -> Void) {
        self.viewModel = viewModel
        self.existing = config
        self.draft = NetworkDraft(editing: config)
        self.onSaved = onSaved
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    private var isEditingNetwork: Bool { existing != nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = isEditingNetwork ? "Edit Network" : "Add Network"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: isEditingNetwork ? "Save" : "Add",
            primaryAction: UIAction { [weak self] _ in self?.save() }
        )
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.close() }
        )
        tableView.register(FormTextCell.self, forCellReuseIdentifier: FormTextCell.reuseID)
        tableView.register(FormSwitchCell.self, forCellReuseIdentifier: FormSwitchCell.reuseID)
        tableView.register(FormTextViewCell.self, forCellReuseIdentifier: FormTextViewCell.reuseID)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "plain")
        tableView.keyboardDismissMode = .interactive
        rebuild()
    }

    private func rebuild() {
        var authRows: [Row] = [.saslAccount, .saslPassword]
        // The clear rows exist only where there is something to clear. Adding a network has
        // no saved secret by definition, and offering to remove one that isn't there is a
        // control that can only be a no-op.
        if existing?.hasSaslPassword == true { authRows.append(.clearSaslPassword) }
        authRows.append(.serverPassword)
        if existing?.hasPassword == true { authRows.append(.clearServerPassword) }

        sections = [
            Section(
                header: "Connection",
                footer: error,
                rows: [.name, .host, .port, .tls]
            ),
            Section(header: "You", footer: nil, rows: [.nick, .realname]),
            Section(
                header: "Authentication",
                footer: "SASL logs you in during connection. Some networks require it.",
                rows: authRows
            ),
        ]
        if !isEditingNetwork {
            sections.append(Section(
                header: "Channels",
                // Said plainly because it's the difference between landing in a conversation
                // and landing in an empty server log — which is what a new user sees if this
                // is blank, with no idea that a channel is the thing they're missing.
                footer: "Joined automatically when you connect. Separate several with commas.",
                rows: [.defaultChannel]
            ))
        }
        sections.append(Section(
            header: "Advanced",
            footer: isEditingNetwork
                // The web says the same thing, and it's the question anyone editing a host or
                // a nick is about to have.
                ? "Changes apply the next time this network connects. Reconnect it to apply them now."
                : nil,
            rows: [.connectCommands, .autoconnect, .verifyCertificate]
        ))
        tableView.reloadData()
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

    override func tableView(
        _ tableView: UITableView, willDisplayFooterView view: UIView, forSection section: Int
    ) {
        // The save error rides in the first section's footer, so it has to look like an error
        // rather than like guidance. Colouring it here beats a custom footer view for one
        // line of red.
        guard let footer = view as? UITableViewHeaderFooterView else { return }
        footer.textLabel?.textColor = (section == 0 && error != nil) ? Palette.bad : .secondaryLabel
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch sections[indexPath.section].rows[indexPath.row] {
        case .name:
            return text(indexPath, "Name", draft.name, placeholder: "Libera") { [weak self] in
                self?.draft.name = $0
            }
        case .host:
            let cell = text(indexPath, "Server", draft.host, placeholder: "irc.libera.chat") { [weak self] in
                self?.draft.host = $0
            }
            cell.typedAsIdentifier(keyboard: .URL)
            return cell
        case .port:
            let cell = text(indexPath, "Port", String(draft.port)) { [weak self] in
                // A cleared field is 0, not the old value: an empty port is a port the user is
                // in the middle of retyping, and `validationError` refuses 0 if they stop
                // there. Silently keeping the previous number would save something they can't
                // see on screen.
                self?.draft.port = Int($0) ?? 0
            }
            cell.typedAsIdentifier(keyboard: .numberPad)
            return cell
        case .tls:
            return toggle(indexPath, "Use TLS", draft.tls) { [weak self] in self?.draft.tls = $0 }
        case .nick:
            let cell = text(indexPath, "Nickname", draft.nick) { [weak self] in self?.draft.nick = $0 }
            // ⚠ Autocapitalisation off matters here specifically: an autocapitalised nick
            // connects you as someone else's spelling of your name, and every highlight rule
            // keyed to the lowercase one goes quiet.
            cell.typedAsIdentifier()
            return cell
        case .realname:
            return text(indexPath, "Real name", draft.realname ?? "", placeholder: "Optional") {
                [weak self] in self?.draft.realname = $0
            }
        case .saslAccount:
            let cell = text(
                indexPath, "Account", draft.saslAccount ?? "",
                placeholder: draft.nick.isEmpty ? "Optional" : draft.nick
            ) { [weak self] in self?.draft.saslAccount = $0 }
            cell.typedAsIdentifier()
            return cell
        case .saslPassword:
            return secret(
                indexPath, "Password", saved: existing?.hasSaslPassword == true,
                edit: draft.saslPassword, clearRow: .clearSaslPassword
            ) { [weak self] in self?.draft.saslPassword = $0 }
        case .serverPassword:
            return secret(
                indexPath, "Server password", saved: existing?.hasPassword == true,
                edit: draft.password, clearRow: .clearServerPassword
            ) { [weak self] in self?.draft.password = $0 }
        case .clearSaslPassword:
            return clearRow(indexPath, isArmed: draft.saslPassword == .cleared, what: "SASL Password")
        case .clearServerPassword:
            return clearRow(indexPath, isArmed: draft.password == .cleared, what: "Server Password")
        case .defaultChannel:
            let cell = text(
                indexPath, "Channels", draft.defaultChannel ?? "", placeholder: "#lurker"
            ) { [weak self] in self?.draft.defaultChannel = $0 }
            cell.typedAsIdentifier()
            return cell
        case .connectCommands:
            let cell = tableView.dequeueReusableCell(
                withIdentifier: FormTextViewCell.reuseID, for: indexPath
            ) as! FormTextViewCell
            // Raw wire lines, not slash commands, and `WAIT` in context — a worked example
            // beats a sentence describing the format.
            cell.configure(
                value: draft.connectCommands ?? "",
                placeholder: "PRIVMSG NickServ :IDENTIFY hunter2\nWAIT 5\nOPER admin hunter2"
            )
            cell.onChange = { [weak self] in self?.draft.connectCommands = $0 }
            // Re-measure without reloading: a reload would rebuild the cell and resign the
            // keyboard on every newline typed.
            cell.onHeightChange = { [weak self] in
                self?.tableView.beginUpdates()
                self?.tableView.endUpdates()
            }
            return cell
        case .autoconnect:
            return toggle(indexPath, "Connect on startup", draft.autoconnect) { [weak self] in
                self?.draft.autoconnect = $0
            }
        case .verifyCertificate:
            // Named for what it does, not for the column it sets. `trusted_certificates`
            // reads like permission to accept anything and means the opposite.
            return toggle(indexPath, "Verify TLS certificate", draft.trustedCertificates) {
                [weak self] in self?.draft.trustedCertificates = $0
            }
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .clearSaslPassword:
            draft.saslPassword = draft.saslPassword == .cleared ? .unchanged : .cleared
        case .clearServerPassword:
            draft.password = draft.password == .cleared ? .unchanged : .cleared
        default:
            return
        }
        rebuild()
    }

    // MARK: - Cells

    private func text(
        _ indexPath: IndexPath, _ label: String, _ value: String,
        placeholder: String? = nil, onChange: @escaping (String) -> Void
    ) -> FormTextCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: FormTextCell.reuseID, for: indexPath
        ) as! FormTextCell
        cell.configure(label: label, value: value, placeholder: placeholder)
        cell.onChange = onChange
        return cell
    }

    private func toggle(
        _ indexPath: IndexPath, _ label: String, _ isOn: Bool, onChange: @escaping (Bool) -> Void
    ) -> FormSwitchCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: FormSwitchCell.reuseID, for: indexPath
        ) as! FormSwitchCell
        cell.configure(label: label, isOn: isOn)
        cell.onChange = onChange
        return cell
    }

    /// A password field. Blank never means "remove it" — see `SecretEdit` — so the placeholder
    /// has to say what a blank field is going to do.
    private func secret(
        _ indexPath: IndexPath, _ label: String, saved: Bool, edit: SecretEdit,
        clearRow: Row, onChange: @escaping (SecretEdit) -> Void
    ) -> FormTextCell {
        let value: String
        if case .set(let typed) = edit { value = typed } else { value = "" }
        let cell = text(
            indexPath, label, value,
            placeholder: {
                if edit == .cleared { return "Will be removed" }
                return saved ? "Saved — type to replace" : "Optional"
            }()
        ) { [weak self] text in
            // Typing supersedes an armed clear: the user is replacing the password now, not
            // removing it, and leaving the clear armed would throw the new value away on save.
            onChange(text.isEmpty ? .unchanged : .set(text))
            // So the clear row, which now says the wrong thing, is re-drawn. That row only —
            // a full rebuild would resign the keyboard on every keystroke.
            self?.reconfigure(clearRow)
        }
        cell.typedAsIdentifier()
        cell.field.isSecureTextEntry = true
        cell.field.textContentType = .password
        return cell
    }

    /// Redraw one row in place, leaving whatever is being typed into alone.
    private func reconfigure(_ kind: Row) {
        for (section, model) in sections.enumerated() {
            guard let row = model.rows.firstIndex(of: kind) else { continue }
            tableView.reconfigureRows(at: [IndexPath(row: row, section: section)])
            return
        }
    }

    private func clearRow(_ indexPath: IndexPath, isArmed: Bool, what: String) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "plain", for: indexPath)
        var content = cell.defaultContentConfiguration()
        // The label states what tapping does, and flips once armed so the row is also the way
        // back. Nothing is removed until Save — this only records the intent.
        content.text = isArmed ? "Keep Saved \(what)" : "Remove Saved \(what)"
        content.textProperties.color = isArmed ? .label : Palette.bad
        cell.contentConfiguration = content
        cell.selectionStyle = .default
        return cell
    }

    // MARK: - Saving

    private func save() {
        guard !saving else { return }
        view.endEditing(true) // land the field being typed into before reading the draft
        if let problem = draft.validationError {
            show(error: problem)
            return
        }
        saving = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            let result: NetworkSaveResult
            if let existing {
                result = await viewModel.updateNetwork(id: existing.id, draft: draft)
            } else {
                result = await viewModel.createNetwork(draft)
            }
            saving = false
            navigationItem.rightBarButtonItem?.isEnabled = true
            switch result {
            case .saved, .savedWithoutDetail:
                // ⚠ `savedWithoutDetail` closes too. The write landed; only its reply was
                // unreadable. Keeping the form open would invite the retry that creates the
                // network twice — see `NetworkSaveResult`.
                onSaved()
                close()
            case .failure(let message):
                show(error: message)
            }
        }
    }

    private func show(error message: String) {
        error = message
        rebuild()
        // The message lands under the first section, which is off screen if the user saved
        // from the bottom of a long form — so go to it rather than leaving them looking at an
        // unchanged screen wondering whether the button worked.
        tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: true)
    }

    private func close() {
        if let navigation = navigationController, navigation.viewControllers.first !== self {
            navigation.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }
}
