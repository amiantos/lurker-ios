// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine
import LurkerKit
import UIKit

/// Who someone is (#12) — the screen behind every nick in the app.
///
/// This is what made the member list stop being a placeholder: its rows had nowhere to go, so
/// they didn't go anywhere. Four things open this now — a member row, a DM's "Whois" row,
/// `/whois`, and a message's action sheet — and they all mean the same question.
///
/// **The whois is asked on open, every time.** Presence, idle time and channel list go stale
/// within minutes, so the cached reply is here to render *immediately* while the round trip is
/// out, not to save it. `ChatViewModel.requestWhois` owns the in-flight bookkeeping that keeps
/// a reopen from spamming the server without leaving a failed lookup un-retryable.
///
/// Nothing here writes to the store. The note is server-authoritative like every other list in
/// this app: the editor asks, and the note changes when `nick-note-updated` comes back — from
/// this device or a browser, by the identical route.
final class UserProfileViewController: UITableViewController {
    private let viewModel: ChatViewModel
    private let networkId: Int
    private let nick: String
    private var cancellables = Set<AnyCancellable>()

    /// Go to a conversation. Handed back rather than done here for the same reason
    /// `BufferInfoViewController` hands back its rows: this screen may be inside a sheet, and
    /// the presenter owns dismissing itself before anything replaces the stack behind it.
    var onOpenBuffer: ((BufferKey) -> Void)?

    private var sections: [Section] = []
    private var status: ProfileStatus = .resolve(
        peer: .unknown, whois: nil, isLookingUp: false, isSelf: false
    )

    init(viewModel: ChatViewModel, networkId: Int, nick: String) {
        self.viewModel = viewModel
        self.networkId = networkId
        self.nick = nick
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = nick
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "profile")
        tableView.tableHeaderView = header

        // A pushed profile keeps the stack's own back button; a presented one is the root of
        // its sheet and needs a way out.
        if navigationController?.viewControllers.first === self {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                systemItem: .done, primaryAction: UIAction { [weak self] _ in
                    self?.dismiss(animated: true)
                }
            )
        }

        viewModel.statePublisher
            .removeDuplicates { [networkId, nick] old, new in
                // Every input this screen draws from, and nothing else — a profile open over a
                // busy channel would otherwise rebuild on every arriving message.
                //
                // `nickNotes` compares by identity, which is valid because the set is only ever
                // replaced (see `NickNoteSet`), and is what keeps this from walking every note
                // on every frame.
                old.whoisResult(networkId: networkId, nick: nick)
                    == new.whoisResult(networkId: networkId, nick: nick)
                    && old.isWhoisPending(networkId: networkId, nick: nick)
                        == new.isWhoisPending(networkId: networkId, nick: nick)
                    && old.nickNotes === new.nickNotes
                    && old.presence(networkId: networkId, nick: nick)
                        == new.presence(networkId: networkId, nick: nick)
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.apply(state) }
            .store(in: &cancellables)
        apply(viewModel.state)

        // After the first render, so the cached reply (if any) is already on screen when the
        // request goes out rather than a frame behind it.
        viewModel.requestWhois(networkId: networkId, nick: nick)
    }

    // MARK: - Model

    private enum Row {
        case status(ProfileStatus.StatusLine)
        /// A labelled fact. `copyable` rows put their value on the pasteboard when tapped —
        /// a hostmask is the one thing here people actually retype elsewhere.
        case detail(title: String, value: String, copyable: Bool)
        /// A standing fact about the account rather than a value: TLS, bot, operator.
        case flag(title: String, symbol: String)
        case channel(WhoisResult.ChannelEntry)
        case note(String)
        case editNote(hasNote: Bool)
        case sendDirectMessage
        case refresh
    }

    private struct Section {
        var header: String?
        var footer: String?
        var rows: [Row]
    }

    private func apply(_ state: ChatState) {
        let whois = state.whoisResult(networkId: networkId, nick: nick)
        let selfNick = state.networks[networkId]?.nick ?? ""
        status = ProfileStatus.resolve(
            peer: state.presence(networkId: networkId, nick: nick),
            whois: whois,
            isLookingUp: state.isWhoisPending(networkId: networkId, nick: nick),
            isSelf: !selfNick.isEmpty && selfNick.lowercased() == nick.lowercased()
        )

        var built: [Section] = []
        if let line = status.statusLine {
            built.append(Section(header: nil, footer: nil, rows: [.status(line)]))
        }
        if !details(whois).isEmpty {
            built.append(Section(header: nil, footer: nil, rows: details(whois)))
        }
        if !flags(whois, state: state).isEmpty {
            built.append(Section(header: nil, footer: nil, rows: flags(whois, state: state)))
        }
        let channels = whois?.channels ?? []
        if !channels.isEmpty {
            built.append(
                Section(header: "Channels", footer: nil, rows: channels.map { .channel($0) })
            )
        }
        built.append(noteSection(state))
        built.append(actionsSection)

        sections = built
        updateHeader()
        tableView.reloadData()
    }

    private func details(_ whois: WhoisResult?) -> [Row] {
        guard let whois else { return [] }
        var rows: [Row] = []
        func add(_ title: String, _ value: String?, copyable: Bool = false) {
            guard let value, !value.isEmpty else { return }
            rows.append(.detail(title: title, value: value, copyable: copyable))
        }
        add("Real name", whois.realName)
        add("Hostmask", whois.hostmask, copyable: true)
        // Only opers and the account itself are told this, so it's absent far more often than
        // present — which is why it's a row that appears rather than one that says "unknown".
        add(
            "Connected from",
            [whois.actualHostname, whois.actualIP].compactMap(\.self).joined(separator: " ")
        )
        add("Account", whois.account)
        add(
            "Server",
            whois.serverInfo.map { "\(whois.server ?? "") (\($0))" } ?? whois.server
        )
        add("Idle", whois.idleSeconds.flatMap(Self.duration))
        add("Signed on", whois.signedOn.map(Self.dateTime.string(from:)))
        return rows
    }

    /// The standing facts, each carrying the server's own wording where it gave us one —
    /// "is an IRC Operator" says more than a chip reading "Operator", and it costs nothing to
    /// keep since the numeric's trailing text is what the field holds.
    private func flags(_ whois: WhoisResult?, state: ChatState) -> [Row] {
        var rows: [Row] = []
        if let whois {
            if whois.isSecure {
                rows.append(.flag(title: "Connected over TLS", symbol: "lock"))
            }
            if let text = whois.registeredNick {
                rows.append(.flag(title: text, symbol: "checkmark.seal"))
            }
            if let text = whois.isOperator {
                rows.append(.flag(title: text, symbol: "shield.lefthalf.filled"))
            }
            if let text = whois.helpop {
                rows.append(.flag(title: text, symbol: "questionmark.circle"))
            }
            if let text = whois.bot {
                rows.append(.flag(title: text, symbol: "gearshape.2"))
            }
        }
        // A local mark rather than a whois fact, so it shows even with no reply in — including
        // for a bot that is currently offline, which is exactly when you'd come looking.
        if state.relayBots.isRelay(networkId: networkId, nick: nick) {
            rows.append(.flag(title: "Marked as a relay bot", symbol: "antenna.radiowaves.left.and.right"))
        }
        return rows
    }

    private func noteSection(_ state: ChatState) -> Section {
        let note = state.nickNotes.note(networkId: networkId, nick: nick)
        var rows: [Row] = []
        if let note, !note.note.isEmpty { rows.append(.note(note.note)) }
        rows.append(.editNote(hasNote: note != nil))
        return Section(
            header: "Your note",
            // Said once, here, rather than left for someone to discover: a note is the
            // account's, not the channel's, and it follows them to the browser.
            footer: note?.updatedAt.map { "Updated \(Self.dateTime.string(from: $0))" }
                ?? "Only you can see this. It syncs to your other devices.",
            rows: rows
        )
    }

    private var actionsSection: Section {
        var rows: [Row] = []
        if status.canSendDirectMessage { rows.append(.sendDirectMessage) }
        rows.append(.refresh)
        return Section(header: nil, footer: nil, rows: rows)
    }

    // MARK: - Header

    private let dot = UIView()
    private let nameLabel = UILabel()
    private let statusLabel = UILabel()

    /// Nick over status, centred, with the presence dot beside the nick — the same shape the
    /// message action sheet uses, because this is the same kind of object: a subject, then what
    /// you can do about it.
    private lazy var header: UIView = {
        nameLabel.font = .preferredFont(forTextStyle: .title2)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.numberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.text = nick

        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalTo: dot.widthAnchor),
        ])
        dot.layer.cornerRadius = 5
        // The dot is decoration for a fact the status line under it already states in words;
        // announcing it too would read the status twice.
        dot.isAccessibilityElement = false

        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2

        let name = UIStackView(arrangedSubviews: [dot, nameLabel])
        name.axis = .horizontal
        name.spacing = 8
        name.alignment = .center
        let stack = UIStackView(arrangedSubviews: [name, statusLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 4
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 20, leading: 24, bottom: 16, trailing: 24
        )
        return stack
    }()

    private func updateHeader() {
        dot.backgroundColor = status.presence.dotColor
        statusLabel.text = status.awayMessage.map { "\(status.presence.title) — \($0)" }
            ?? status.presence.title
        nameLabel.accessibilityLabel = "\(nick), \(status.presence.accessibilityLabel)"
        sizeHeader()
    }

    /// A `tableHeaderView` does not self-size; without this it keeps the zero height it was
    /// given and the header is invisible.
    private func sizeHeader() {
        guard let header = tableView.tableHeaderView, tableView.bounds.width > 0 else { return }
        let width = tableView.bounds.width
        let height = header.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        guard abs(header.frame.height - height) > 0.5 || abs(header.frame.width - width) > 0.5
        else { return }
        header.frame = CGRect(x: 0, y: 0, width: width, height: height)
        tableView.tableHeaderView = header // reassignment is what commits the new height
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sizeHeader()
    }

    // MARK: - Formatting

    /// Idle time. `DateComponentsFormatter` rather than a hand-rolled ladder so the units are
    /// localized, capped at two so a long idle reads "3d 4h" instead of counting seconds.
    private static let idleFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    private static func duration(_ seconds: Int) -> String? {
        // Zero is "active right now", which reads better than "0s".
        guard seconds > 0 else { return "Active now" }
        return idleFormatter.string(from: TimeInterval(seconds))
    }

    private static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

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
        let cell = tableView.dequeueReusableCell(withIdentifier: "profile", for: indexPath)
        cell.accessoryType = .none
        cell.selectionStyle = .none
        var content = UIListContentConfiguration.cell()

        switch sections[indexPath.section].rows[indexPath.row] {
        case .status(let line):
            switch line {
            case .notFound:
                content.text = "\(nick) isn't on this network."
                content.image = UIImage(systemName: "questionmark.circle")
            case .waiting:
                content.text = "Looking up \(nick)…"
                content.image = UIImage(systemName: "ellipsis.circle")
            }
            content.textProperties.color = .secondaryLabel
            content.imageProperties.tintColor = .secondaryLabel

        case .detail(let title, let value, let copyable):
            content = UIListContentConfiguration.valueCell()
            content.text = title
            content.secondaryText = value
            // A hostmask is long and the row is narrow, so let it take the width it needs
            // rather than truncating the half that identifies them.
            content.secondaryTextProperties.numberOfLines = 0
            if copyable {
                cell.selectionStyle = .default
                cell.accessoryView = UIImageView(image: UIImage(systemName: "doc.on.doc"))
                cell.accessoryView?.tintColor = .secondaryLabel
            }

        case .flag(let title, let symbol):
            content.text = title
            content.image = UIImage(systemName: symbol)
            content.imageProperties.tintColor = .secondaryLabel

        case .channel(let entry):
            content.text = entry.prefix + entry.name
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default

        case .note(let text):
            // Prose of arbitrary length, so it wraps rather than truncating — the truncated
            // half of a note is the half you wrote it for.
            content.text = text
            content.textProperties.numberOfLines = 0

        case .editNote(let hasNote):
            content.text = hasNote ? "Edit Note" : "Add Note"
            content.image = UIImage(systemName: hasNote ? "square.and.pencil" : "plus")
            content.textProperties.color = .tintColor
            content.imageProperties.tintColor = .tintColor
            cell.selectionStyle = .default

        case .sendDirectMessage:
            content.text = "Send Message"
            content.image = UIImage(systemName: "bubble.left")
            content.textProperties.color = .tintColor
            content.imageProperties.tintColor = .tintColor
            cell.selectionStyle = .default

        case .refresh:
            content.text = "Refresh"
            content.image = UIImage(systemName: "arrow.clockwise")
            content.textProperties.color = .tintColor
            content.imageProperties.tintColor = .tintColor
            cell.selectionStyle = .default
        }

        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .detail(_, let value, let copyable):
            guard copyable else { return }
            UIPasteboard.general.string = value

        case .channel(let entry):
            // Join rather than "switch to": the server answers a JOIN for a channel you are
            // already in by confirming it, so one verb covers both and neither client has to
            // guess which case this is.
            viewModel.joinChannel(networkId: networkId, channel: entry.name)
            onOpenBuffer?(BufferKey(networkId: networkId, target: entry.name))

        case .editNote:
            let editor = NickNoteViewController(
                viewModel: viewModel, networkId: networkId, nick: nick
            )
            navigationController?.pushViewController(editor, animated: true)

        case .sendDirectMessage:
            // Mint or reopen the DM row first — the server refuses to activate a buffer that
            // doesn't exist, and the same socket delivers the row before we ask to show it.
            let key = BufferKey(networkId: networkId, target: nick)
            viewModel.openBuffer(key)
            onOpenBuffer?(key)

        case .refresh:
            // A no-op while a lookup is already out, which is `requestWhois`'s own rule — so
            // an impatient double tap can't queue a second WHOIS.
            viewModel.requestWhois(networkId: networkId, nick: nick)

        case .status, .flag, .note:
            break
        }
    }
}
