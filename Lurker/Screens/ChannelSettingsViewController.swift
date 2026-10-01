// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine
import LurkerKit
import UIKit

/// The table's identities, outside the screen's main-actor isolation: a diffable data source
/// requires them `Sendable`.
nonisolated private enum SectionID: Hashable {
    case topic
    case modes
    case other
}

nonisolated private enum ItemID: Hashable {
    case topicField
    case topicText
    case notice(String)
    /// A mode's switch, by letter.
    case toggle(String)
    /// A param mode's value, by letter — present while its switch is on.
    case value(String)
}

/// A channel's topic and modes (#187, the iOS half of lurker#727), pushed from the buffer info
/// sheet. Its lists — bans and the rest — are screens of their own (`ModeListViewController`).
///
/// Everything is drawn from the network's `modeSpec`, so a network's own modes all show up,
/// named where the letter means the same thing on every ircd and as `+X` where it doesn't.
/// Everyone can open it and read it; editing modes takes op or higher, the topic halfop or
/// higher under `+t`. The server has the last word, and its refusal shows here.
///
/// ⚠⚠ The form holds only what the user TOUCHED (`ChannelModeDrafts`), never a copy of the
/// channel taken on open. Every row reads live state, and Save diffs the edits against the live
/// state at that moment — so another op's change shows up while this is open, and Save never
/// reverts it. An edit goes when the channel answers it, never on the ack.
final class ChannelSettingsViewController: UITableViewController {
    private let viewModel: ChatViewModel
    private let key: BufferKey
    private var cancellables = Set<AnyCancellable>()

    private var drafts = ChannelModeDrafts()
    private var keyRevealed = false
    /// The key the server holds, as the network config said when this screen asked. Live `±k`
    /// rows seen since then outrank it — see `storedKey`.
    private var configKey: String?
    /// Whether the config has been asked for the key since the channel was last seen keyed.
    /// Asked whenever the channel IS keyed and this is false — not just on open, since the
    /// channel's modes may land after the screen does, or turn `+k` while it's up.
    private var keyAsked = false

    /// This channel's live `mode` rows since the screen opened (or the socket last reopened), off
    /// the socket rather than out of the buffer's log: a detached buffer holds live lines out of
    /// its log, and this screen still needs them — the newest `±k` names the key.
    private var modeRowsSeen: [Message] = []
    /// The channel's error rows, as answers to a Save.
    private var refusals = ChannelRefusals()

    private var saving = false
    private var saveError: String?

    private var dataSource: UITableViewDiffableDataSource<SectionID, ItemID>!
    private var sections: [Section] = []

    init(viewModel: ChatViewModel, key: BufferKey) {
        self.viewModel = viewModel
        self.key = key
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Channel Settings"
        tableView.keyboardDismissMode = .interactive
        tableView.register(FormSwitchCell.self, forCellReuseIdentifier: FormSwitchCell.reuseID)
        tableView.register(FormTextCell.self, forCellReuseIdentifier: FormTextCell.reuseID)
        tableView.register(FormTextViewCell.self, forCellReuseIdentifier: FormTextViewCell.reuseID)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "text")
        tableView.register(UITableViewHeaderFooterView.self, forHeaderFooterViewReuseIdentifier: "footer")
        tableView.register(UITableViewHeaderFooterView.self, forHeaderFooterViewReuseIdentifier: "header")

        dataSource = UITableViewDiffableDataSource(tableView: tableView) { [weak self] tableView, indexPath, id in
            self?.cell(tableView, indexPath, id) ?? UITableViewCell()
        }
        dataSource.defaultRowAnimation = .fade
        navigationItem.rightBarButtonItem = saveButton

        // Only this channel's slice: the state moves on every line in every buffer, and nothing
        // else changes what this screen draws.
        viewModel.statePublisher
            .map { [key] state in Slice(state, key) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)
        viewModel.channelEvents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.receive(event) }
            .store(in: &cancellables)
        render(animated: false)
    }

    /// What this screen draws from the store.
    private struct Slice: Equatable {
        let modes: ChannelModeState?
        let topic: String?
        let access: ChannelAccess

        init(_ state: ChatState, _ key: BufferKey) {
            modes = state.channelModes[key.id]
            topic = state.buffers[key.id]?.topic
            access = state.channelAccess(key)
        }
    }

    /// The key lives only in the network config, and the copy any other screen read is as old as
    /// that screen — so it's asked afresh, once per stretch of the channel being keyed.
    private func askForKeyIfKeyed(_ modes: String) {
        guard modes.contains("k") else {
            keyAsked = false
            configKey = nil
            return
        }
        guard !keyAsked else { return }
        keyAsked = true
        Task { [weak self, viewModel, key] in
            let stored = await viewModel.storedChannelKey(key)
            guard let self else { return }
            configKey = stored
            render()
        }
    }

    private lazy var saveButton = UIBarButtonItem(
        systemItem: .save, primaryAction: UIAction { [weak self] _ in self?.save() }
    )

    private func receive(_ event: ChatViewModel.ChannelEvent) {
        switch event {
        case .resynced:
            // Whatever changed in the gap came as backlog, not live rows, so a `±k` seen before it
            // may be stale: forget them, and ask the config again.
            modeRowsSeen.removeAll()
            configKey = nil
            keyAsked = false
        case .line(let lineKey, let message):
            guard lineKey.id == key.id else { return }
            switch message.type {
            case .mode: modeRowsSeen.append(message)
            case .error: refusals.note(message.text ?? "")
            default: return
            }
        }
        render()
    }

    // MARK: - State

    /// The channel's key: the newest `±k` seen since opening (a `-k` means there's none, so a key
    /// the config still remembers doesn't come back), else the config's copy.
    private var storedKey: String? {
        switch ChannelModeForm.lastKeyChange(modeRowsSeen) {
        case .set(let key): key
        case .removed: nil
        case .none: configKey
        }
    }

    private func live(_ state: ChatState) -> ChannelModeForm.Live {
        let held = state.channelModes[key.id]
        let modes = held?.modes ?? ""
        var params = held?.params ?? [:]
        // Only while the channel has a key: switching +k back on must start empty, not quietly
        // re-send an old one.
        if modes.contains("k"), let storedKey { params["k"] = storedKey }
        return ChannelModeForm.Live(modes: modes, params: params)
    }

    private func liveTopic(_ state: ChatState) -> String { state.buffers[key.id]?.topic ?? "" }

    /// What Save would send, or why it can't.
    private func pending(_ state: ChatState) -> (changes: [OutgoingModeChange], topic: String?, error: String?) {
        let access = state.channelAccess(key)
        var changes: [OutgoingModeChange] = []
        var error: String?
        if access.canEditModes, let spec = access.spec {
            switch ChannelModeForm.changes(spec: spec, live: live(state), draft: drafts.rows) {
            case .success(let found): changes = found
            case .failure(let problem): error = problem.message
            }
        }
        let topic = access.canSetTopic ? drafts.topicChange(live: liveTopic(state)) : nil
        if error == nil, let topic, let limit = access.spec?.topicLen, ChannelModeForm.topicBytes(topic) > limit {
            error = "The topic is over the network's \(limit)-byte limit."
        }
        return (changes, topic, error)
    }

    // MARK: - Save

    private func save() {
        guard !saving else { return }
        view.endEditing(true)
        let state = viewModel.state
        let (changes, topic, error) = pending(state)
        saveError = error
        guard error == nil, topic != nil || !changes.isEmpty else {
            render()
            return
        }
        // Decided now, before any await: the fields stay editable while the answer is out, and
        // what goes out is what the user saved. Each half is recorded as sent only as it goes —
        // the modes wait on the topic, and a topic that fails takes them with it.
        let sending = drafts.sending(changes, live: live(state))
        let topicWas = liveTopic(state)
        refusals.arm()
        saving = true
        render()
        Task { [weak self, viewModel, key] in
            var failure: ChatViewModel.ChannelSaveFailure?
            if let topic {
                self?.drafts.noteTopicSent(topic, liveTopic: topicWas)
                failure = await viewModel.setTopic(key, topic: topic)
                if failure?.certainlyUnsent == true { self?.drafts.noteTopicNotSent(topic) }
            }
            if failure == nil, !changes.isEmpty {
                self?.drafts.noteSent(sending)
                failure = await viewModel.setChannelModes(key, changes: changes)
                if failure?.certainlyUnsent == true { self?.drafts.noteNotSent(sending) }
            }
            guard let self else { return }
            saving = false
            saveError = failure?.message
            render()
        }
    }

    // MARK: - Model

    private enum Content: Equatable {
        case topicField(text: String)
        case topicText(String, muted: Bool)
        case notice(String)
        case toggle(label: String, on: Bool, enabled: Bool)
        case value(letter: String, label: String, value: String, isKey: Bool, placeholder: String, enabled: Bool)
    }

    private struct Footer: Equatable {
        var text: String
        var isError = false
    }

    private struct Section: Equatable {
        let id: SectionID
        let header: String?
        var footer: Footer?
        let items: [(id: ItemID, content: Content)]

        static func == (lhs: Section, rhs: Section) -> Bool {
            lhs.id == rhs.id && lhs.header == rhs.header && lhs.footer == rhs.footer
                && lhs.items.map(\.id) == rhs.items.map(\.id) && lhs.items.map(\.content) == rhs.items.map(\.content)
        }
    }

    private func build(_ state: ChatState) -> [Section] {
        let access = state.channelAccess(key)
        let live = live(state)
        let topic = liveTopic(state)
        let held = state.channelModes[key.id]
        var out: [Section] = []

        // Topic. Out of the channel we don't know it has no topic — or that it exists at all;
        // only what we last saw.
        let topicItem: (ItemID, Content)
        if access.canSetTopic {
            topicItem = (.topicField, .topicField(text: drafts.topic ?? topic))
        } else if !topic.isEmpty {
            topicItem = (.topicText, .topicText(topic, muted: false))
        } else {
            topicItem = (.topicText, .topicText(access.joined ? "No topic set." : "Join the channel to see its topic.", muted: true))
        }
        var topicNotes: [String] = []
        if !topic.isEmpty, let setter = held?.topicSetterLine { topicNotes.append(setter) }
        if access.canSetTopic, let limit = access.spec?.topicLen {
            let bytes = ChannelModeForm.topicBytes(ChannelModeForm.topicToSend(drafts.topic ?? topic))
            topicNotes.append("\(bytes) / \(limit) bytes")
        }
        out.append(Section(
            id: .topic, header: "Topic",
            footer: topicNotes.isEmpty ? nil : Footer(text: topicNotes.joined(separator: " · ")),
            items: [topicItem]
        ))

        // Modes.
        guard let spec = access.spec else {
            out.append(Section(id: .modes, header: "Modes", footer: nil,
                               items: [(.notice("spec"), .notice("Modes show once the network is connected."))]))
            return withErrors(out)
        }
        guard access.joined else {
            out.append(Section(id: .modes, header: "Modes", footer: nil,
                               items: [(.notice("parted"), .notice("Join the channel to see its modes."))]))
            return withErrors(out)
        }
        // Someone who can't change modes sees only the ones that are set.
        let rows = ChannelModeForm.rows(spec).filter { access.canEditModes || live.row($0.letter).on }
        let named = rows.filter { $0.name != nil }
        let other = rows.filter { $0.name == nil }
        let readOnly = access.canEditModes ? nil : Footer(text: "Only channel operators can change modes.")
        if named.isEmpty, other.isEmpty {
            out.append(Section(id: .modes, header: "Modes", footer: readOnly,
                               items: [(.notice("none"), .notice("No modes set."))]))
            return withErrors(out)
        }
        if !named.isEmpty {
            out.append(Section(id: .modes, header: "Modes", footer: other.isEmpty ? readOnly : nil,
                               items: named.flatMap { items(for: $0, live: live, access: access) }))
        }
        if !other.isEmpty {
            // Letters with no name we can vouch for, apart, so twenty of them don't bury the ones
            // that mean something.
            out.append(Section(id: .other, header: "Other Modes", footer: readOnly,
                               items: other.flatMap { items(for: $0, live: live, access: access) }))
        }
        return withErrors(out)
    }

    /// A row's switch, and — while it's on — its value.
    private func items(
        for row: ChannelModeForm.Row, live: ChannelModeForm.Live, access: ChannelAccess
    ) -> [(id: ItemID, content: Content)] {
        let shown = drafts.shown(row.letter, live: live)
        let label = row.name ?? "+\(row.letter)"
        var out: [(id: ItemID, content: Content)] = [
            (.toggle(row.letter), .toggle(label: label, on: shown.on, enabled: access.canEditModes)),
        ]
        guard row.kind != .flag, shown.on else { return out }
        let isKey = row.kind == .key
        out.append((.value(row.letter), .value(
            letter: row.letter,
            label: isKey ? "Key" : (row.letter == "l" ? "Limit" : "Value"),
            value: shown.value,
            isKey: isKey,
            // A +k channel whose key we never learned: the field is empty, and the channel still
            // has one. Typing replaces it; switching off removes it.
            placeholder: isKey && live.row("k").on ? "Key is set" : "Required",
            enabled: access.canEditModes
        )))
        return out
    }

    /// The Save's refusal under the last section, whichever that is.
    private func withErrors(_ sections: [Section]) -> [Section] {
        let errors = ([saveError].compactMap { $0 } + refusals.current)
        guard !errors.isEmpty, var last = sections.last else { return sections }
        let text = ([last.footer?.text].compactMap { $0 } + errors).joined(separator: "\n")
        last.footer = Footer(text: text, isError: true)
        return sections.dropLast() + [last]
    }

    // MARK: - Render

    private func render(animated: Bool = true) {
        guard isViewLoaded else { return }
        let state = viewModel.state
        askForKeyIfKeyed(state.channelModes[key.id]?.modes ?? "")
        drafts.reconcile(live: live(state), liveTopic: liveTopic(state))
        let access = state.channelAccess(key)
        let (changes, topic, error) = pending(state)
        saveButton.isEnabled = !saving && (error != nil || topic != nil || !changes.isEmpty)
        let button = access.canEditModes || access.canSetTopic ? saveButton : nil
        if navigationItem.rightBarButtonItem !== button { navigationItem.rightBarButtonItem = button }

        let next = build(state)
        guard next != sections else { return }
        let previous = sections
        sections = next

        var snapshot = NSDiffableDataSourceSnapshot<SectionID, ItemID>()
        for section in next {
            snapshot.appendSections([section.id])
            snapshot.appendItems(section.items.map(\.id), toSection: section.id)
        }
        // Rows that stayed but now read differently are reconfigured in place — never reloaded,
        // which would take the keyboard from a field being typed in. And never a row the user has
        // TYPED in while it has the keyboard: it shows their edit, and touching it mid-word moves
        // the caret. A focused field with no edit yet is still showing live state, so it follows
        // it — left alone, it would keep an old topic for them to edit and send back.
        let before = Dictionary(previous.flatMap(\.items).map { ($0.id, $0.content) }, uniquingKeysWith: { a, _ in a })
        let editing = editingItem.flatMap { hasEdit($0) ? $0 : nil }
        let changed = next.flatMap(\.items)
            .filter { before[$0.id] != nil && before[$0.id] != $0.content && $0.id != editing }
            .map(\.id)
        if !changed.isEmpty { snapshot.reconfigureItems(changed) }
        dataSource.apply(snapshot, animatingDifferences: animated && !previous.isEmpty)

        // Footers aren't the data source's: update the visible ones in place, then let the table
        // re-measure them.
        var footersMoved = false
        for (index, section) in next.enumerated() {
            let old = previous.first { $0.id == section.id }?.footer
            guard old != section.footer, let view = tableView.footerView(forSection: index) else { continue }
            configure(footer: view, section.footer)
            footersMoved = true
        }
        if footersMoved {
            UIView.performWithoutAnimation { tableView.performBatchUpdates(nil) }
        }
    }

    /// Whether the user has typed in this row since the channel last answered it.
    private func hasEdit(_ id: ItemID) -> Bool {
        switch id {
        case .topicField: drafts.topic != nil
        case .value(let letter): drafts.rows[letter] != nil
        case .topicText, .notice, .toggle: false
        }
    }

    /// The row whose field has the keyboard, if any.
    private var editingItem: ItemID? {
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            guard let cell = tableView.cellForRow(at: indexPath),
                  cell.contentView.firstResponderDescendant != nil
            else { continue }
            return dataSource.itemIdentifier(for: indexPath)
        }
        return nil
    }

    // MARK: - Table

    private func cell(_ tableView: UITableView, _ indexPath: IndexPath, _ id: ItemID) -> UITableViewCell {
        guard let content = sections.flatMap(\.items).first(where: { $0.id == id })?.content else {
            return UITableViewCell()
        }
        switch content {
        case .topicField(let text):
            let cell = tableView.dequeueReusableCell(withIdentifier: FormTextViewCell.reuseID, for: indexPath) as! FormTextViewCell
            cell.typedAsProse()
            cell.configure(label: "Topic", value: text, placeholder: "No topic set.")
            cell.onChange = { [weak self] text in
                self?.drafts.setTopic(text)
                self?.render()
            }
            cell.onHeightChange = { [weak tableView] in
                // Re-measure without reloading, which would resign the keyboard mid-typing.
                UIView.performWithoutAnimation { tableView?.performBatchUpdates(nil) }
            }
            return cell

        case .topicText(let text, let muted):
            let cell = tableView.dequeueReusableCell(withIdentifier: "text", for: indexPath)
            var config = UIListContentConfiguration.cell()
            config.text = text
            config.textProperties.numberOfLines = 0
            config.textProperties.color = muted ? .secondaryLabel : .label
            cell.contentConfiguration = config
            cell.selectionStyle = .none
            return cell

        case .notice(let text):
            let cell = tableView.dequeueReusableCell(withIdentifier: "text", for: indexPath)
            var config = UIListContentConfiguration.cell()
            config.text = text
            config.textProperties.numberOfLines = 0
            config.textProperties.color = .secondaryLabel
            cell.contentConfiguration = config
            cell.selectionStyle = .none
            return cell

        case .toggle(let label, let on, let enabled):
            let cell = tableView.dequeueReusableCell(withIdentifier: FormSwitchCell.reuseID, for: indexPath) as! FormSwitchCell
            cell.configure(label: label, isOn: on, isEnabled: enabled)
            guard case .toggle(let letter) = id else { return cell }
            cell.onChange = { [weak self] on in
                guard let self else { return }
                drafts.setOn(letter, on, live: live(viewModel.state))
                render()
            }
            return cell

        case .value(let letter, let label, let value, let isKey, let placeholder, let enabled):
            let cell = tableView.dequeueReusableCell(withIdentifier: FormTextCell.reuseID, for: indexPath) as! FormTextCell
            cell.configure(label: label, value: value, placeholder: placeholder)
            cell.typedAsIdentifier(keyboard: letter == "l" ? .numberPad : .asciiCapable)
            cell.field.isEnabled = enabled
            cell.onChange = { [weak self] text in
                guard let self else { return }
                drafts.setValue(letter, text, live: live(viewModel.state))
                render()
            }
            if isKey {
                cell.field.isSecureTextEntry = !keyRevealed
                // A secure field blanks itself on focus; put the draft back (see FormTextCell).
                cell.restoreOnFocus = { [weak self] in
                    guard let self else { return nil }
                    return drafts.shown("k", live: live(viewModel.state)).value
                }
                cell.field.rightView = revealButton()
                cell.field.rightViewMode = .always
            }
            return cell
        }
    }

    /// The eye that shows or hides the key. Only offered while there's a key in the field to show.
    private func revealButton() -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: keyRevealed ? "eye.slash" : "eye")
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 0)
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            keyRevealed.toggle()
            var snapshot = dataSource.snapshot()
            if snapshot.itemIdentifiers.contains(.value("k")) {
                snapshot.reconfigureItems([.value("k")])
                dataSource.apply(snapshot, animatingDifferences: false)
            }
        })
        button.accessibilityLabel = keyRevealed ? "Hide key" : "Show key"
        return button
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard sections.indices.contains(section), let header = sections[section].header,
              let view = tableView.dequeueReusableHeaderFooterView(withIdentifier: "header")
        else { return nil }
        var config = UIListContentConfiguration.groupedHeader()
        config.text = header
        view.contentConfiguration = config
        return view
    }

    override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        guard let view = tableView.dequeueReusableHeaderFooterView(withIdentifier: "footer") else { return nil }
        configure(footer: view, sections.indices.contains(section) ? sections[section].footer : nil)
        return view
    }

    private func configure(footer view: UITableViewHeaderFooterView, _ footer: Footer?) {
        var config = UIListContentConfiguration.groupedFooter()
        config.text = footer?.text
        if footer?.isError == true { config.textProperties.color = .systemRed }
        view.contentConfiguration = config
    }

    override func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool { false }
}

private extension UIView {
    var firstResponderDescendant: UIView? {
        if isFirstResponder { return self }
        for subview in subviews {
            if let found = subview.firstResponderDescendant { return found }
        }
        return nil
    }
}
