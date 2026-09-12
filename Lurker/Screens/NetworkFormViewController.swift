// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit
import UniformTypeIdentifiers

/// Add or edit a network (#11). The screen that makes a fresh install usable without a
/// browser.
///
/// One class for both, because they are the same form: the differences are a title, a save
/// verb, the create-only rows, and whether the secret rows offer to clear something. Two
/// classes would be two copies of every field, and the copies would drift.
///
/// **Nothing here is written to the draft at save time.** Every cell reports changes as they
/// happen, because a table dequeues cells that scroll out of view — a form that read its
/// values back from its cells would lose whatever was typed above the fold.
///
/// **The certificate rows don't wait for Save** (#459). Editing, they write through the
/// server's certificate routes when tapped: a certificate isn't a column the PATCH sets, it's a
/// pair the server validates on a route of its own. Adding, there is no network to write to
/// yet, so the choice waits in the draft and rides the create request.
final class NetworkFormViewController: UITableViewController {

    private enum Row: Equatable {
        /// Why the last save was refused, when there was one.
        ///
        /// ⚠ A row rather than the section footer it started as. Colouring a footer means
        /// reaching for `UITableViewHeaderFooterView.textLabel`, which is deprecated and nil
        /// for a UIKit-configured footer — so the refusal could silently render in the same
        /// grey as the guidance footer two sections down, which is exactly what it must not
        /// look like. A row's appearance is ours.
        case error
        case name, host, port, tls
        case nick, realname
        case saslAccount, saslPassword, clearSaslPassword
        case serverPassword, clearServerPassword
        /// What the certificate is: when it expires, that it's waiting on the create, or that it
        /// can't be read.
        case certificateStatus
        /// Why the last certificate action didn't work. The `error` row's look, in this section:
        /// it's about these rows, and the top row is Save's.
        case certificateError
        case generateCertificate, importCertificate
        case copyFingerprint, exportCertificate, removeCertificate
        /// Drop a certificate waiting on the create.
        case undoCertificate
        case defaultChannel
        case proxyEnabled, proxyType, proxyHost, proxyPort, proxyUsername, proxyPassword, clearProxyPassword
        case connectCommands, autoconnect, verifyCertificate
    }

    private enum SectionID {
        case connection, you, authentication, certificate, channels, proxy, advanced
    }

    private struct Section: Equatable {
        let id: SectionID
        let header: String?
        let footer: String?
        let rows: [Row]
    }

    /// What to do once the write has landed. The form doesn't navigate itself: it is always
    /// pushed — onto the picker when adding, onto the list when editing — and where you
    /// should end up afterwards is the list's business, not the form's. It certainly isn't
    /// "back to the picker", which is what popping one screen would give.
    ///
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
    /// The network's certificate as the server last described it.
    ///
    /// Not read from `existing`: the certificate rows write immediately and answer with the new
    /// description, and `existing` is the row as it was when the form opened.
    private var certificate: ClientCertificate?
    /// A certificate request is out. Save waits for it, because the server checks TLS on each
    /// side separately: an attach landing alongside a save that turns TLS off would leave a
    /// certificate on a network with no handshake to present it in, which can never connect.
    private var certificateBusy = false
    private var certificateError: String?
    /// An export is being fetched, so a second tap doesn't queue a second share sheet.
    private var exporting = false

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
        self.certificate = config.clientCertificate
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
        tableView.register(FormTextCell.self, forCellReuseIdentifier: FormTextCell.reuseID)
        tableView.register(FormSwitchCell.self, forCellReuseIdentifier: FormSwitchCell.reuseID)
        tableView.register(FormTextViewCell.self, forCellReuseIdentifier: FormTextViewCell.reuseID)
        tableView.register(FormMenuCell.self, forCellReuseIdentifier: FormMenuCell.reuseID)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "plain")
        // Its own identifier, so the button trait an action row sets never rides a reused cell
        // into a row that isn't one.
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "action")
        tableView.keyboardDismissMode = .interactive
        rebuild()
    }

    private func rebuild() {
        buildSections()
        tableView.reloadData()
    }

    /// Rebuild, redrawing only one section.
    ///
    /// ⚠ For changes made while a field elsewhere may have the keyboard. `reloadData` replaces
    /// every cell, the focused one included, and takes the keyboard with it — flipping TLS
    /// with the server field still focused would dismiss it. Falls back to a full reload if
    /// anything outside the section moved, rather than hand UIKit a stale row count.
    private func rebuild(section id: SectionID, animation: UITableView.RowAnimation = .none) {
        let before = sections
        buildSections()
        guard before.count == sections.count,
              zip(before, sections).allSatisfy({ old, new in old.id == id || old == new }),
              let index = sections.firstIndex(where: { $0.id == id })
        else { return tableView.reloadData() }
        tableView.reloadSections(IndexSet(integer: index), with: animation)
    }

    private func buildSections() {
        var authRows: [Row] = [.saslAccount, .saslPassword]
        // The clear rows exist only where there is something to clear. Adding a network has
        // no saved secret by definition, and offering to remove one that isn't there is a
        // control that can only be a no-op.
        if existing?.hasSaslPassword == true { authRows.append(.clearSaslPassword) }
        authRows.append(.serverPassword)
        if existing?.hasPassword == true { authRows.append(.clearServerPassword) }

        sections = [
            Section(
                id: .connection,
                header: "Connection",
                footer: nil,
                rows: (error == nil ? [] : [.error]) + [.name, .host, .port, .tls]
            ),
            Section(id: .you, header: "You", footer: nil, rows: [.nick, .realname]),
            Section(
                id: .authentication,
                header: "Authentication",
                footer: "SASL logs you in during connection. Some networks require it.",
                rows: authRows
            ),
            certificateSection(),
        ]
        if !isEditingNetwork {
            sections.append(Section(
                id: .channels,
                header: "Channels",
                // Said plainly because it's the difference between landing in a conversation
                // and landing in an empty server log — which is what a new user sees if this
                // is blank, with no idea that a channel is the thing they're missing.
                footer: "Joined automatically when you connect. Separate several with commas.",
                rows: [.defaultChannel]
            ))
        }
        sections.append(proxySection())
        sections.append(Section(
            id: .advanced,
            header: "Advanced",
            footer: isEditingNetwork
                // The web says the same thing, and it's the question anyone editing a host or
                // a nick is about to have.
                ? "Changes apply the next time this network connects. Reconnect it to apply them now."
                : nil,
            rows: [.connectCommands, .autoconnect, .verifyCertificate]
        ))
    }

    /// CertFP (#459). No fingerprints on screen and no explanation — the rows are the verbs,
    /// which is where the web settled after several rounds.
    private func certificateSection() -> Section {
        var rows: [Row] = certificateError == nil ? [] : [.certificateError]
        var footer: String?
        if let certificate {
            switch certificate {
            case .usable(let fingerprints, _):
                rows.append(.certificateStatus)
                if !fingerprints.all.isEmpty { rows.append(.copyFingerprint) }
                rows += [.exportCertificate, .removeCertificate]
            case .unusable:
                rows += [.certificateStatus, .removeCertificate]
            }
            // The server refuses to save TLS off while a certificate is attached. Say so before
            // Save rather than after it.
            if !draft.tls { footer = "Remove the certificate before turning TLS off." }
        } else if draft.certificate != nil {
            rows += [.certificateStatus, .undoCertificate]
            if !draft.tls { footer = "Client certificates need TLS." }
        } else {
            rows += [.generateCertificate, .importCertificate]
            if !draft.tls {
                footer = "Client certificates need TLS."
            } else if existing?.tls == false {
                // ⚠ The certificate routes check the SAVED row, not this form, so TLS switched
                // on here and not yet saved would still be refused.
                footer = "Save with TLS on first, then add a certificate."
            }
        }
        return Section(id: .certificate, header: "Client Certificate", footer: footer, rows: rows)
    }

    /// Whether Generate and Import can be used right now. The footer says why when they can't.
    private var canAddCertificate: Bool {
        draft.tls && existing?.tls != false && !certificateBusy && !saving
    }

    /// The proxy (#303). Its details show only while it's switched on, and only what's shown is
    /// sent — see `NetworkDraft.applyProxy`.
    private func proxySection() -> Section {
        guard draft.proxy.enabled else {
            return Section(id: .proxy, header: "Proxy", footer: nil, rows: [.proxyEnabled])
        }
        var rows: [Row] = [.proxyEnabled, .proxyType, .proxyHost, .proxyPort, .proxyUsername, .proxyPassword]
        if existing?.proxy?.hasPassword == true { rows.append(.clearProxyPassword) }
        return Section(
            id: .proxy,
            header: "Proxy",
            // Tor is why most people turn this on. The name lookup is worth saying because it's
            // what makes `.onion` work.
            footer: "For Tor, use 127.0.0.1 port 9050. The proxy looks up the server's address, so .onion works.",
            rows: rows
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
        switch sections[indexPath.section].rows[indexPath.row] {
        case .error:
            return errorRow(indexPath, error)
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
            // Zero renders as empty, not as a literal "0" the user has to delete: a cleared
            // field parses to 0, and after a failed save the rebuild would otherwise hand
            // back a field they have to clear again before retyping.
            let cell = text(
                indexPath, "Port", draft.port == 0 ? "" : String(draft.port), placeholder: "6697"
            ) { [weak self] in
                // A cleared field is 0, not the old value: an empty port is a port the user is
                // in the middle of retyping, and `validationError` refuses 0 if they stop
                // there. Silently keeping the previous number would save something they can't
                // see on screen.
                self?.draft.port = Int($0) ?? 0
            }
            cell.typedAsIdentifier(keyboard: .numberPad)
            return cell
        case .tls:
            return toggle(indexPath, "Use TLS", draft.tls) { [weak self] in
                self?.draft.tls = $0
                // A certificate needs TLS, so that section's rows and footer follow this switch.
                self?.rebuild(section: .certificate)
            }
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
                edit: draft.saslPassword, clearRow: .clearSaslPassword,
                current: { [weak self] in self?.draft.saslPassword ?? .unchanged }
            ) { [weak self] in self?.draft.saslPassword = $0 }
        case .serverPassword:
            return secret(
                indexPath, "Server password", saved: existing?.hasPassword == true,
                edit: draft.password, clearRow: .clearServerPassword,
                current: { [weak self] in self?.draft.password ?? .unchanged }
            ) { [weak self] in self?.draft.password = $0 }
        case .clearSaslPassword:
            return clearRow(indexPath, isArmed: draft.saslPassword == .cleared, what: "SASL Password")
        case .clearServerPassword:
            return clearRow(indexPath, isArmed: draft.password == .cleared, what: "Server Password")
        case .certificateStatus:
            return certificateStatusRow(indexPath)
        case .certificateError:
            return errorRow(indexPath, certificateError)
        case .generateCertificate:
            return actionRow(indexPath, "Generate Certificate", enabled: canAddCertificate)
        case .importCertificate:
            // A file, not a paste box: every CertFP guide hands you a .pem, and it's what Export
            // writes.
            return actionRow(indexPath, "Import Certificate…", enabled: canAddCertificate)
        case .copyFingerprint:
            return fingerprintRow(indexPath)
        case .exportCertificate:
            return actionRow(indexPath, "Export Certificate…")
        case .removeCertificate:
            return actionRow(indexPath, "Remove Certificate", destructive: true, enabled: !certificateBusy)
        case .undoCertificate:
            return actionRow(indexPath, "Undo")
        case .defaultChannel:
            let cell = text(
                indexPath, "Channels", draft.defaultChannel ?? "", placeholder: "#lurker"
            ) { [weak self] in self?.draft.defaultChannel = $0 }
            cell.typedAsIdentifier()
            return cell
        case .proxyEnabled:
            return toggle(indexPath, "Connect through a proxy", draft.proxy.enabled) { [weak self] in
                self?.draft.proxy.enabled = $0
                self?.rebuild(section: .proxy, animation: .fade)
            }
        case .proxyType:
            let cell = tableView.dequeueReusableCell(
                withIdentifier: FormMenuCell.reuseID, for: indexPath
            ) as! FormMenuCell
            let current = draft.proxy.type
            cell.configure(
                label: "Type",
                value: Self.title(for: current),
                menu: UIMenu(children: ProxyType.allCases.map { type in
                    UIAction(title: Self.title(for: type), state: type == current ? .on : .off) {
                        [weak self] _ in
                        self?.draft.proxy.setType(type)
                        // An untouched default port follows the type, so that row may have
                        // changed too.
                        self?.reconfigure(.proxyType)
                        self?.reconfigure(.proxyPort)
                    }
                })
            )
            return cell
        case .proxyHost:
            let cell = text(indexPath, "Address", draft.proxy.host, placeholder: "127.0.0.1") {
                [weak self] in self?.draft.proxy.host = $0
            }
            cell.typedAsIdentifier(keyboard: .URL)
            return cell
        case .proxyPort:
            // Empty for 0, and 0 for a cleared field, for the reasons the server's port gives.
            let cell = text(
                indexPath, "Port", draft.proxy.port == 0 ? "" : String(draft.proxy.port),
                placeholder: String(draft.proxy.type.defaultPort)
            ) { [weak self] in self?.draft.proxy.port = Int($0) ?? 0 }
            cell.typedAsIdentifier(keyboard: .numberPad)
            return cell
        case .proxyUsername:
            let cell = text(indexPath, "Username", draft.proxy.username ?? "", placeholder: "Optional") {
                [weak self] in self?.draft.proxy.username = $0
            }
            cell.typedAsIdentifier()
            return cell
        case .proxyPassword:
            return secret(
                indexPath, "Password", saved: existing?.proxy?.hasPassword == true,
                edit: draft.proxy.password, clearRow: .clearProxyPassword,
                current: { [weak self] in self?.draft.proxy.password ?? .unchanged }
            ) { [weak self] in self?.draft.proxy.password = $0 }
        case .clearProxyPassword:
            return clearRow(indexPath, isArmed: draft.proxy.password == .cleared, what: "Proxy Password")
        case .connectCommands:
            let cell = tableView.dequeueReusableCell(
                withIdentifier: FormTextViewCell.reuseID, for: indexPath
            ) as! FormTextViewCell
            // Raw wire lines, not slash commands, and `WAIT` in context — a worked example
            // beats a sentence describing the format.
            cell.configure(
                label: "Connect commands",
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
            rebuild()
        case .clearServerPassword:
            draft.password = draft.password == .cleared ? .unchanged : .cleared
            rebuild()
        case .clearProxyPassword:
            draft.proxy.password = draft.proxy.password == .cleared ? .unchanged : .cleared
            rebuild(section: .proxy)
        case .generateCertificate where canAddCertificate:
            addCertificate(.generate)
        case .importCertificate where canAddCertificate:
            pickCertificateFiles()
        case .undoCertificate:
            draft.certificate = nil
            rebuild(section: .certificate, animation: .fade)
        case .exportCertificate where !exporting:
            exportCertificate()
        case .removeCertificate where !certificateBusy && !saving:
            confirmRemoveCertificate()
        default:
            return
        }
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
        clearRow: Row, current: @escaping () -> SecretEdit, onChange: @escaping (SecretEdit) -> Void
    ) -> FormTextCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: FormTextCell.reuseID, for: indexPath
        ) as! FormTextCell
        if case .set(let typed) = edit {
            cell.configure(label: label, value: typed, placeholder: Self.placeholder(for: edit, saved: saved))
        } else {
            cell.configure(label: label, value: "", placeholder: Self.placeholder(for: edit, saved: saved))
        }
        cell.onChange = { [weak self, weak cell] text in
            // Typing supersedes an armed clear: the user is replacing the password now, not
            // removing it, and leaving the clear armed would throw the new value away on save.
            onChange(text.isEmpty ? .unchanged : .set(text))
            // ⚠⚠ The placeholder is updated IN PLACE, not by reconfiguring this row — that
            // would rebuild the cell the user is typing into and resign the keyboard. Without
            // it, un-arming a clear by typing and then deleting left the field still saying
            // "Will be removed" over a password Save was about to keep: the screen stating
            // the opposite of what would happen, which is the divergence `restoreOnFocus`
            // exists to prevent one field over.
            cell?.field.placeholder = Self.placeholder(for: current(), saved: saved)
            // The clear row, which now says the wrong thing too. That one isn't being typed
            // into, so a reconfigure is safe.
            self?.reconfigure(clearRow)
        }
        cell.typedAsIdentifier()
        cell.field.isSecureTextEntry = true
        cell.field.textContentType = .password
        // UIKit blanks a secure field on every focus and reports no change for it. Put the
        // typed value back, so what the field shows and what Save will send stay the same
        // thing — see `FormTextCell.restoreOnFocus`.
        cell.restoreOnFocus = { if case .set(let typed) = current() { return typed } else { return nil } }
        return cell
    }

    /// What an empty password field means right now — the one thing a blank secure field
    /// cannot say for itself.
    private static func placeholder(for edit: SecretEdit, saved: Bool) -> String {
        if edit == .cleared { return "Will be removed" }
        return saved ? "Saved — type to replace" : "Optional"
    }

    private func indexPath(of kind: Row) -> IndexPath? {
        for (section, model) in sections.enumerated() {
            if let row = model.rows.firstIndex(of: kind) { return IndexPath(row: row, section: section) }
        }
        return nil
    }

    /// Redraw one row in place, leaving whatever is being typed into alone.
    private func reconfigure(_ kind: Row) {
        guard let path = indexPath(of: kind) else { return }
        tableView.reconfigureRows(at: [path])
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

    private func errorRow(_ indexPath: IndexPath, _ message: String?) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "plain", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = message
        content.textProperties.color = Palette.bad
        content.textProperties.numberOfLines = 0
        content.image = UIImage(systemName: "exclamationmark.triangle.fill")
        content.imageProperties.tintColor = Palette.bad
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }

    /// A row that does something, drawn the way a button in a grouped form is: tinted, red when
    /// it destroys something, dimmed when it can't be used right now.
    private func actionRow(
        _ indexPath: IndexPath, _ title: String, destructive: Bool = false, enabled: Bool = true
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "action", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = title
        content.textProperties.color = !enabled ? .tertiaryLabel : destructive ? Palette.bad : .tintColor
        cell.contentConfiguration = content
        cell.selectionStyle = enabled ? .default : .none
        cell.accessibilityTraits = enabled ? .button : [.button, .notEnabled]
        return cell
    }

    private func certificateStatusRow(_ indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "plain", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.textProperties.numberOfLines = 0
        switch (certificate, draft.certificate) {
        case (.usable(_, let expires?), _):
            content = .valueCell()
            // Past tense once the date has gone by, rather than "Expires" over a date in the past.
            content.text = expires < Date() ? "Expired" : "Expires"
            content.secondaryText = expires.formatted(date: .abbreviated, time: .omitted)
        case (.usable(_, nil), _):
            content = .valueCell()
            content.text = "Certificate"
            content.secondaryText = "Attached"
        case (.unusable, _):
            content.text = "This certificate can't be read, and the network won't connect while it's attached."
            content.textProperties.color = Palette.bad
        case (nil, .generate?):
            content.text = "A certificate will be created with this network."
        case (nil, .imported?):
            content.text = "Your certificate will be attached to this network."
        case (nil, nil):
            break // no status row is built without a certificate
        }
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }

    /// Copy, never show. On the web, `CERT ADD` with no argument (which reads the fingerprint off
    /// the live connection) covers nearly every network, and `/network cert` covers the rest. This
    /// app has no `/network`, so without this row a network that needs the digest typed in, like
    /// ergo, couldn't be set up from the phone.
    private func fingerprintRow(_ indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: FormMenuCell.reuseID, for: indexPath
        ) as! FormMenuCell
        var digests: [(name: String, value: String)] = []
        if case .usable(let fingerprints, _) = certificate { digests = fingerprints.all }
        cell.configure(label: "Fingerprint", value: "Copy", menu: UIMenu(children: digests.map { digest in
            UIAction(title: digest.name) { [weak self] _ in
                UIPasteboard.general.string = digest.value
                guard let self else { return }
                ToastView.show("Fingerprint Copied", symbol: "doc.on.doc", over: view)
            }
        }))
        return cell
    }

    private static func title(for type: ProxyType) -> String {
        switch type {
        case .socks5: "SOCKS5"
        case .http: "HTTP CONNECT"
        }
    }

    /// ⚠⚠ Set unconditionally: an action sheet or share sheet with no anchor is a hard crash at
    /// regular width, and the app runs on iPad. The row when it's on screen, the middle of the
    /// form when it isn't.
    private func anchor(_ popover: UIPopoverPresentationController?, to row: Row) {
        guard let popover else { return }
        if let path = indexPath(of: row), let cell = tableView.cellForRow(at: path) {
            popover.sourceView = cell
            popover.sourceRect = cell.bounds
        } else {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        }
    }

    // MARK: - Certificates

    /// Generate or import. Adding, the choice waits in the draft for the create request, which
    /// attaches it before the first dial. Editing, it's written now.
    private func addCertificate(_ source: CertificateSource) {
        certificateError = nil
        guard let existing else {
            draft.certificate = source
            rebuild(section: .certificate, animation: .fade)
            return
        }
        runCertificate { [viewModel] in await viewModel.attachCertificate(networkId: existing.id, source) }
    }

    private func runCertificate(_ request: @escaping () async -> CertificateResult) {
        certificateBusy = true
        certificateError = nil
        updateSaveButton()
        rebuild(section: .certificate)
        Task { [weak self] in
            let result = await request()
            guard let self else { return }
            certificateBusy = false
            switch result {
            case .updated(let next): certificate = next
            case .failure(let message): certificateError = message
            }
            updateSaveButton()
            rebuild(section: .certificate, animation: .fade)
        }
    }

    private func pickCertificateFiles() {
        // ⚠ Every type rather than a list of certificate ones: a type left off greys the file out
        // in Files with no way around it (#125), and `.key`, the extension these files often
        // wear, is Keynote's as far as the system is concerned.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
        // The pair often lives in two files.
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    private func confirmRemoveCertificate() {
        guard let existing, presentedViewController == nil else { return }
        let sheet = UIAlertController(
            title: "Remove Certificate?",
            // Only a readable certificate can be exported, so only that one gets the advice.
            message: certificate == .unusable
                ? nil
                : "Anywhere you've registered it won't recognize a new one. Export it first to keep a copy.",
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
            guard let self else { return }
            runCertificate { [viewModel] in await viewModel.removeCertificate(networkId: existing.id) }
        })
        anchor(sheet.popoverPresentationController, to: .removeCertificate)
        present(sheet, animated: true)
    }

    private func exportCertificate() {
        guard let existing else { return }
        exporting = true
        Task { [weak self] in
            guard let self else { return }
            let result = await viewModel.exportCertificate(networkId: existing.id)
            exporting = false
            switch result {
            case .pem(let pem):
                // The server's own file name, so it matches what the web downloads.
                share(pem, named: "lurker-\(existing.id)-client.pem")
            case .failure(let message):
                certificateError = message
                rebuild(section: .certificate, animation: .fade)
            }
        }
    }

    /// Hand the pair to the share sheet as a file — Save to Files, AirDrop — for keeping, or for
    /// another client.
    private func share(_ pem: String, named name: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        // ⚠ The file holds an unencrypted private key: written with full protection, and deleted
        // as soon as the sheet is done with it, whichever way it closes.
        do {
            try Data(pem.utf8).write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            certificateError = "Couldn't prepare the certificate file."
            rebuild(section: .certificate, animation: .fade)
            return
        }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: url) }
        anchor(sheet.popoverPresentationController, to: .exportCertificate)
        present(sheet, animated: true)
    }

    // MARK: - Saving

    private func save() {
        // Not while a certificate request is out — see `certificateBusy`.
        guard !saving, !certificateBusy else { return }
        view.endEditing(true) // land the field being typed into before reading the draft
        // Whatever the last attempt was refused for is now stale — the user has had a chance
        // to fix it, and leaving it up next to a disabled Add button tells them a field they
        // just corrected is still wrong for the length of the round trip.
        if error != nil {
            error = nil
            rebuild()
        }
        if let problem = draft.validationError {
            show(error: problem)
            return
        }
        saving = true
        updateSaveButton()
        Task { [weak self] in
            guard let self else { return }
            let result: NetworkSaveResult
            if let existing {
                result = await viewModel.updateNetwork(id: existing.id, draft: draft)
            } else {
                result = await viewModel.createNetwork(draft)
            }
            saving = false
            updateSaveButton()
            switch result {
            case .saved, .savedWithoutDetail:
                // ⚠ `savedWithoutDetail` leaves too. The write landed; only its reply was
                // unreadable. Keeping the form open would invite the retry that creates the
                // network twice — see `NetworkSaveResult`.
                onSaved()
            case .failure(let message):
                show(error: message)
            }
        }
    }

    private func updateSaveButton() {
        navigationItem.rightBarButtonItem?.isEnabled = !saving && !certificateBusy
    }

    private func show(error message: String) {
        error = message
        rebuild()
        // The message lands under the first section, which is off screen if the user saved
        // from the bottom of a long form — so go to it rather than leaving them looking at an
        // unchanged screen wondering whether the button worked.
        tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: true)
    }

}

// MARK: - Importing a certificate

extension NetworkFormViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        switch ClientCertificatePEM.reading(urls.map(Self.readPickedFile).joined(separator: "\n")) {
        case .ready(let source):
            addCertificate(source)
        case .refused(let message):
            certificateError = message
            rebuild(section: .certificate, animation: .fade)
        }
    }

    /// A picked file's text, or "" for one that can't be read — which then gets the message for
    /// a file holding no certificate, the one a user can act on.
    nonisolated private static func readPickedFile(_ url: URL) -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // A PEM pair is a few kilobytes, and the picker offers every file: without a bound, a video
        // picked by mistake is read whole into memory to be told it isn't a certificate.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= 1 << 20, let data = try? Data(contentsOf: url) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
