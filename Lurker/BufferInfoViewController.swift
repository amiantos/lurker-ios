// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine
import LurkerKit
import UIKit

/// What this buffer *is*, rather than what's been said in it — the title pill expands into
/// this. A channel gets its topic, a count of who's here, and how it notifies; a DM gets
/// the person and how it notifies.
///
/// The pill means the same thing on every buffer: "about this one". That's why a DM lands
/// here and not straight in a whois — whois is about a *person*, and a person is one of
/// the things a DM is about, not the whole of it. It gets a row that leads there (#12),
/// the same way a channel's members do, so the pill keeps one meaning and whois still has
/// somewhere to live.
///
/// Notification rows are placeholders and say so. The per-channel flag they'll drive
/// (`notify_always`) already exists server-side and already rides the snapshot, but the
/// client doesn't parse it yet — so there's no honest state to render, and a switch that
/// silently does nothing is worse than one that admits it.
final class BufferInfoViewController: UITableViewController {
    private let viewModel: ChatViewModel
    private let buffer: Buffer
    private var cancellables = Set<AnyCancellable>()

    /// Opening the member list is the chat screen's job — it owns the sheet-presentation
    /// rules (and the guard against stacking two sheets). This screen only knows the row
    /// was tapped.
    var onShowMembers: (() -> Void)?

    private var sections: [Section] = []

    init(viewModel: ChatViewModel, buffer: Buffer) {
        self.viewModel = viewModel
        self.buffer = buffer
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = buffer.displayName(networkName: viewModel.networks.first { $0.id == buffer.networkId }?.name)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            }
        )
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "info")

        let key = buffer.key.id
        // Both of the live things on this screen: the topic hangs off the buffer, the count
        // off the member list. Neither moves often, and a busy channel would otherwise
        // rebuild this table once per arriving message.
        viewModel.statePublisher
            .removeDuplicates {
                $0.buffers[key]?.topic == $1.buffers[key]?.topic
                    && $0.members[key]?.count == $1.members[key]?.count
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.apply(state) }
            .store(in: &cancellables)
        apply(viewModel.state)
    }

    // MARK: - Model

    private enum Row {
        case topic(String?)
        case members(Int)
        case whois
        case notifyPlaceholder(title: String)
    }

    private struct Section {
        var header: String?
        var footer: String?
        var rows: [Row]
    }

    /// Read the live copy out of state rather than trusting the buffer this screen was
    /// constructed with — that one is a value, snapshotted whenever the chat screen was
    /// built, so its topic is frozen at that moment.
    private func apply(_ state: ChatState) {
        let key = buffer.key.id
        let live = state.buffers[key] ?? buffer
        let memberCount = state.members[key]?.count ?? 0

        switch buffer.kind {
        case .channel:
            sections = [
                Section(header: "Topic", footer: nil, rows: [.topic(live.topic)]),
                Section(header: nil, footer: nil, rows: [.members(memberCount)]),
                notifications,
            ]
        case .dm:
            sections = [
                Section(header: nil, footer: nil, rows: [.whois]),
                notifications,
            ]
        case .server, .system:
            // Nothing here is a setting: a server log and the app's own buffer have no
            // topic, no members, and nothing to notify about.
            sections = []
        }
        tableView.backgroundView = sections.isEmpty ? emptyLabel : nil
        tableView.reloadData()
    }

    private var notifications: Section {
        Section(
            header: "Notifications",
            footer: "Not wired up yet — these don't change anything.",
            rows: [.notifyPlaceholder(title: "Notify me about every message")]
        )
    }

    private lazy var emptyLabel: UILabel = {
        let label = UILabel()
        label.text = "This buffer has no settings."
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
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
        let cell = tableView.dequeueReusableCell(withIdentifier: "info", for: indexPath)
        cell.accessoryType = .none
        cell.accessoryView = nil
        cell.selectionStyle = .none

        switch sections[indexPath.section].rows[indexPath.row] {
        case .topic(let topic):
            var content = UIListContentConfiguration.cell()
            // A topic is prose of arbitrary length, not a label — it wraps rather than
            // truncating, because a truncated topic is the half you don't need.
            content.textProperties.numberOfLines = 0
            content.text = topic?.isEmpty == false ? topic : "No topic set."
            content.textProperties.color = topic?.isEmpty == false ? .label : .secondaryLabel
            cell.contentConfiguration = content

        case .members(let count):
            var content = UIListContentConfiguration.valueCell()
            content.text = "Members"
            content.secondaryText = String(count)
            content.image = UIImage(systemName: "person.2")
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default

        case .whois:
            var content = UIListContentConfiguration.cell()
            // No nick alongside it — the title already says whose DM this is, and a "Whois
            // … amiantos" row under an "amiantos" title just says it twice.
            content.text = "Whois"
            content.image = UIImage(systemName: "person.crop.circle")
            // Dimmed and inert: the whois screen is #12. Shown anyway so the panel says
            // what a DM *is* about, rather than being one lonely placeholder switch.
            content.textProperties.color = .tertiaryLabel
            cell.contentConfiguration = content

        case .notifyPlaceholder(let title):
            var content = UIListContentConfiguration.cell()
            content.text = title
            content.textProperties.color = .tertiaryLabel
            cell.contentConfiguration = content
            let toggle = UISwitch()
            toggle.isOn = false
            toggle.isEnabled = false
            cell.accessoryView = toggle
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard case .members = sections[indexPath.section].rows[indexPath.row] else { return }
        // Dismiss first, then hand back: the chat screen presents the member list from
        // itself and refuses while it already has something presented, so opening from
        // under this sheet would silently no-op.
        dismiss(animated: true) { [onShowMembers] in onShowMembers?() }
    }
}
