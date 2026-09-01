// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine
import LurkerKit
import UIKit

/// The settings screen (#20).
///
/// Two kinds of thing live here and they behave differently, which is the whole design.
///
/// **Server settings** — the ones that change how the app behaves — are stored on the server
/// and shared with every other client. A change here writes through `PATCH /api/settings` and
/// comes back as a `settings` frame, so the phone and the browser can never disagree about
/// what the rules are. They're listed because *if a server setting applies to the phone, it
/// should be changeable from the phone*: honoring a rule you can't see or reach makes the
/// app's behavior unexplainable from the device it's happening on.
///
/// **Device actions** — sign out, the version — belong to this install and don't sync.
///
/// Labels are ours, not the registry's, and there is no help text. The registry's `label` and
/// `description` are written for a desktop settings pane with room to explain itself — full
/// sentences, sometimes a worked example — and on a phone that buries three switches under a
/// wall of prose. A short label a person can scan beats an accurate one they won't read. What
/// still comes from the registry is everything a *control* needs to be correct: the type, the
/// default, and an int's bounds, so a stepper can't offer a value the server would reject.
///
/// Behavior and appearance are separate sections — what the app *does* with a message is a
/// different question from what the message looks like, and mixing them makes both lists
/// harder to scan. A key earns a row in either only once the app actually honors it.
final class SettingsViewController: UITableViewController {
    private let viewModel: ChatViewModel
    private var cancellables = Set<AnyCancellable>()

    /// The server settings this screen offers, in display order, with the label to show.
    ///
    /// **Add a key here only when the app honors it.** Each one is wired to real behavior:
    /// typing to `ChatViewController.emitTyping`, the consolidation keys and the two event
    /// suffixes to `MessageRows`/`MessageRenderer`, the mode prefix to the bubble caption, the
    /// scroll rule to `ChatViewController.keepsPositionWhileReading`. The rest of the registry
    /// is deliberately absent — the web is where you configure the things the phone doesn't
    /// implement, and a control for a setting the app ignores is worse than no control at all.
    private static let chatSettings: [(key: String, label: String)] = [
        ("chat.send_typing_notifications", "Send typing notifications"),
        ("chat.keep_position_on_send", "Stay put when you send"),
        // Composing rather than reading, which is the one row here that isn't about what the
        // app does with a message that ARRIVES. It sits under Chat anyway: one row is not a
        // section, and an "Input" header over a single pull-down would be filing for its own
        // sake. It earns the row under this screen's rule now that both the @ picker and Reply
        // honour it (#133).
        ("input.completion.nick_suffix", "Address nicks with"),
    ]

    /// Curated choices for a `string` key the phone offers as a pull-down.
    ///
    /// A `string` setting is free-form on the web, where `/set` takes any value; the phone has
    /// no `/set` and a text field in a table row that rebuilds on every settings echo would
    /// fight the finger holding it. Offering the values people actually pick — with the label
    /// this screen writes, like every other row — is the phone-shaped half of a free-form key,
    /// and a value from outside the list is still shown honestly (see `menuButton`) rather
    /// than reported as one of these.
    ///
    /// `normalize` is how the FEATURE reads the stored value, so a control can match it the
    /// same way. Without it a suffix the web stored as `", "` — the trailing space is dropped
    /// at apply time, not at write time — would show as a custom value next to the identical
    /// `","` choice.
    private struct StringChoices {
        let values: [(value: String, label: String)]
        let normalize: (String) -> String
        /// How VoiceOver reads a value of this key — every value, including one set from the
        /// web that isn't offered here. A function rather than a name per row, so the value
        /// this control can't otherwise explain is the one value it can't fail to read.
        let spoken: (String) -> String
    }

    private static let stringChoices: [String: StringChoices] = [
        // Labelled as the form each one produces rather than by naming the punctuation
        // ("Colon", "Comma"): the question is what your line will look like, and the sample
        // answers it without the user having to picture it.
        //
        // Which is exactly why the key needs a `spoken`. The four differ ONLY by a trailing
        // mark, and VoiceOver does not speak trailing punctuation at its default verbosity —
        // read aloud, the sample labels are four identical "nick"s and a row whose value never
        // changes however it is set. `spokenPunctuation` names the mark instead.
        "input.completion.nick_suffix": StringChoices(
            values: [(":", "nick:"), (",", "nick,"), (";", "nick;"), ("", "nick")],
            normalize: NickCompletion.addressPunctuation,
            spoken: NickCompletion.spokenPunctuation
        )
    ]

    /// One value a pull-down offers: what it stores, what the row shows, and what VoiceOver
    /// says when the visible label can't be read aloud.
    private struct MenuChoice {
        let value: String
        let label: String
        /// nil when `label` speaks for itself — the event tier's choices are full phrases, and
        /// a second copy of "Hide from quiet users" would only be one more thing to keep in
        /// step with the registry.
        var spoken: String?
    }

    /// Join/part/quit/nick/host-change/mode lines: whether you see them, how they're folded,
    /// and how much detail each carries. Its own section, mirroring the web's Events category
    /// (#666) — the filter turned a handful of loosely-related toggles into one subject with a
    /// single primary control, and that subject stopped being a tail on Chat.
    ///
    /// Ordered as they narrow: the filter, then how the survivors are folded, then what each
    /// surviving line shows.
    ///
    /// The filter reads the MOBILE key — it is split by device class, and this device is never
    /// the desktop case.
    ///
    /// The settings under it do NOT grey out when this phone is set to "Hide all", and that is
    /// deliberate. Their registry `dependsOn` is ORed across both device classes, so the
    /// desktop clause — a key this screen doesn't list — keeps them live. They are shared
    /// settings, not per-device ones: disabling them here would stop you managing your
    /// desktop's consolidation from your phone, to save you editing a value this screen
    /// happens not to be using. What `dependsOn` does buy is the transitive case
    /// (`consolidate_max_names` follows `consolidate_joins`) with no table maintained here.
    private static let eventSettings: [(key: String, label: String)] = [
        (EventFilter.modeKey, "Event filter"),
        ("chat.consolidate_joins", "Consolidate events"),
        ("chat.consolidate_max_names", "Max consolidated nicks"),
        ("chat.show_event_host", "Show user@host on events"),
        ("chat.show_join_account", "Show account on joins"),
    ]

    /// The `smart` rung's tuning (#63): its own section under Events, because these answer
    /// a question the section above doesn't ask. Events is "what do I see and how is it folded",
    /// and every row of it applies whatever the filter is set to; these apply on ONE rung, and
    /// left in that list they read as more general event options — a phone-sized list where
    /// half the rows are conditional on the first one is a list you have to already understand
    /// to scan.
    ///
    /// Ordered as the feature is explained rather than as the registry stores it: WHAT it hides
    /// first, then HOW LONG it remembers someone. (The web keeps one flat Events category, so
    /// there is no ordering to match — only the labels, which stay curated as everywhere here.)
    ///
    /// Greying follows the registry's `dependsOn` like everything else on this screen, which
    /// per the note above stays live while *either* device class is on `smart`. These are shared
    /// settings, so a phone on "Show all" can still tune the desktop's filter — which is also
    /// why the section carries a footer instead of relying on the rows being dimmed to say it.
    private static let smartFilterSettings: [(key: String, label: String)] = [
        ("chat.smart_filter_join", "Filter joins"),
        ("chat.smart_filter_quit", "Filter parts and quits"),
        ("chat.smart_filter_nick", "Filter nick changes"),
        // Reads as one of the "what does it hide" rows, so it sits with them rather than
        // with the two windows below. Its shorter label is deliberate: the registry's
        // description carries the rule that a ban riding along shows the whole line.
        ("chat.smart_filter_mode", "Filter op and voice changes"),
        ("chat.smart_filter_delay", "\"Recently spoke\" window (min)"),
        ("chat.smart_filter_join_unmask", "Reveal join on speaking (min)"),
    ]

    /// Settings that change how the conversation *looks* rather than what the app does with a
    /// message. Its own section, so the behavior list above stays a list of behaviors.
    ///
    /// The two preview toggles live here and not under Chat because they change what a message
    /// *looks like*, not what the app does with it — and they're two rather than one because
    /// wanting your friends' screenshots to show is a different appetite from wanting every
    /// article to sprout a card. Both default off.
    /// Keys that only mean anything when the instance has link previews enabled
    /// (`LURKER_LINK_PREVIEWS`). Held as a set here rather than read off the registry because the
    /// curated lists in this file already name their keys by hand, and the server doesn't send
    /// the flag on the wire — the Swift `SettingOption` carries no `requiresFeature`.
    private static let requiresLinkPreviews: Set<String> = [
        "chat.inline_media.enabled",
        "chat.link_previews.enabled",
    ]

    private static let appearanceSettings: [(key: String, label: String)] = [
        ("look.nick.show_mode_prefix", "Show mode prefix on nicks"),
        ("chat.inline_media.enabled", "Inline media"),
        ("chat.link_previews.enabled", "Link previews"),
    ]

    /// Preferences that belong to this install rather than to the account.
    ///
    /// The rule above — a server setting the phone honors should be changeable from the phone
    /// — has a converse: a preference the *server* has no say in doesn't belong in the
    /// registry, and pretending otherwise would ship a key the web could show and not honor.
    /// Autocapitalization is that: it configures the iOS keyboard, and Safari can't offer the
    /// choice at all (it re-applies sentence caps whenever autocorrect is on, so the browser
    /// couples the two). Its own section with its own footer, so nothing here reads as an
    /// account setting that mysteriously failed to follow you to the desktop.
    private enum DeviceSetting: CaseIterable {
        case autocapitalize

        var label: String {
            switch self {
            case .autocapitalize: "Autocapitalize messages"
            }
        }

        var isOn: Bool {
            switch self {
            case .autocapitalize: UserPreferences.standard.composerAutocapitalizes
            }
        }

        func write(_ isOn: Bool) {
            switch self {
            case .autocapitalize: UserPreferences.standard.set(composerAutocapitalizes: isOn)
            }
        }
    }

    /// A row that's ready to render: the curated label plus the registry entry describing how
    /// to edit it. Resolved once per rebuild so the table isn't doing lookups per cell.
    private struct SettingRow {
        let label: String
        let option: SettingOption
    }

    private enum Section {
        /// The account's IRC networks (#11) — a push, not a control.
        ///
        /// First, above every preference: it is the only thing on this screen that decides
        /// whether the app can do anything at all, and the rest are adjustments to an app
        /// that is already working. Unconditional, like `device`, because it needs no
        /// registry — a server too old to describe its settings still has networks.
        case networks
        case chat([SettingRow])
        case events([SettingRow])
        case smartFilter([SettingRow])
        case appearance([SettingRow])
        /// Bootstrap hasn't landed, so there's no registry to build controls from.
        case unavailable
        case device
        case account
        case about
    }

    private var sections: [Section] = []
    /// The most recent failed write, shown under the offending row: the server explains itself
    /// ("must be one of…", "out of range") and that wording is more use than a generic alert,
    /// which would also cover the control the user is trying to fix.
    private var writeError: (key: String, message: String)?

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")

        // Rebuild when the settings themselves change — including the echo of our own write,
        // which is what actually moves a switch to its new position, and a change made on
        // another device, which should move it here too.
        viewModel.statePublisher
            .map(\.settings)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // A settings change from anywhere retires a previous rejection: the value on
                // screen is now the server's, so a red "out of range" pinned under a control
                // that's since become correct is just a lie that never expires.
                self?.writeError = nil
                self?.rebuild()
            }
            .store(in: &cancellables)
        rebuild()
    }

    private func rebuild() {
        let registry = viewModel.state.settings.registry
        // Only what this server actually knows about. A self-hosted instance updates on its
        // owner's schedule and can legitimately be older than the app, so a key it has never
        // heard of gets no row rather than a control whose write would be rejected.
        func resolve(_ entries: [(key: String, label: String)]) -> [SettingRow] {
            entries.compactMap { entry in
                // A setting belonging to a disabled instance feature gets no row at all, rather
                // than a switch whose write the server has no route to act on. Link previews are
                // gated by an operator env flag (LURKER_LINK_PREVIEWS): when it's off the routes
                // aren't even mounted, so offering the toggles would be offering nothing.
                guard let option = registry[entry.key],
                    !Self.requiresLinkPreviews.contains(entry.key)
                        || viewModel.features.linkPreviews
                else { return nil }
                return SettingRow(label: entry.label, option: option)
            }
        }
        let rows = resolve(Self.chatSettings)
        let eventRows = resolve(Self.eventSettings)
        let smartFilterRows = resolve(Self.smartFilterSettings)
        let appearanceRows = resolve(Self.appearanceSettings)
        // No registry means the bootstrap fetch hasn't landed (or failed). Say so, rather than
        // silently rendering a Settings screen whose only contents are Sign Out and a version
        // number — which reads as "this app has no settings" instead of "we couldn't load them".
        // `loaded` distinguishes the two: cached *values* are already in force either way, but
        // only a real bootstrap brings the registry the controls are built from.
        // `rows` is the test for a usable registry, not `appearanceRows`: an older server may
        // legitimately not know an appearance key yet, and an empty section is worse than none.
        // Each optional section is dropped when empty rather than rendered blank — a server
        // predating the event filter knows the consolidation keys but not `chat.events`, so a
        // partial Events section is normal and an absent one has to be too. Smart Filter is the
        // sharpest case of that: a server from before #63 has every other event key and none of
        // these, and a "Smart Filter" header over nothing would advertise a rung it can't serve.
        // The device section is unconditional — it needs no registry, and it's the one part of
        // this screen that still works on a server too old (or too unreachable) to describe
        // itself.
        sections = rows.isEmpty
            ? [.networks, .unavailable, .device, .account, .about]
            : [.networks, .chat(rows)]
                + (eventRows.isEmpty ? [] : [.events(eventRows)])
                + (smartFilterRows.isEmpty ? [] : [.smartFilter(smartFilterRows)])
                + (appearanceRows.isEmpty ? [] : [.appearance(appearanceRows)])
                + [.device, .account, .about]
        tableView.reloadData()
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .chat(let rows), .events(let rows), .smartFilter(let rows), .appearance(let rows):
            rows.count
        case .device: DeviceSetting.allCases.count
        case .networks, .unavailable, .account, .about: 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .networks: nil
        case .chat, .unavailable: "Chat"
        case .events: "Events"
        case .smartFilter: "Smart Filter"
        case .appearance: "Appearance"
        case .device: "This Device"
        case .account, .about: nil
        }
    }

    /// Footers, on the two sections that can't be understood from their rows alone.
    ///
    /// **This Device** — the rest of this screen follows you between clients and this doesn't.
    /// Phrased about its own section rather than as "the settings above are shared", which reads
    /// fine under a full screen and is a lie in the no-registry branch, where the only thing
    /// above it is the notice saying the settings couldn't be loaded.
    ///
    /// **Smart Filter** — ⚠ its rows do nothing on the other two rungs, and nothing on screen
    /// says so. Dimming can't carry it: `dependsOn` is ORed across device classes, so with a
    /// desktop on Smart these rows stay live on a phone set to Show all — correctly, since they
    /// are shared settings and that phone is editing the desktop's filter. A section that is
    /// live, editable, and inert on the device you are holding is exactly a section that has to
    /// explain itself.
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch sections[section] {
        case .device: "Applies to this device only — not shared with your other Lurker clients."
        case .smartFilter: "Used when Event filter is set to Smart."
        default: nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.selectionStyle = .none
        var content = cell.defaultContentConfiguration()

        switch sections[indexPath.section] {
        case .networks:
            content.text = "Networks"
            content.image = UIImage(systemName: "network")
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        case .chat(let rows), .events(let rows), .smartFilter(let rows), .appearance(let rows):
            let row = rows[indexPath.row]
            content.text = row.label
            // The subtitle slot is otherwise unused, so a failed write can say why right under
            // the control that failed.
            if let error = writeError, error.key == row.option.key {
                content.secondaryText = error.message
                content.secondaryTextProperties.color = Palette.bad
                content.secondaryTextProperties.numberOfLines = 0
            }
            configure(cell, for: row.option)
        case .device:
            let setting = DeviceSetting.allCases[indexPath.row]
            content.text = setting.label
            let toggle = UISwitch()
            toggle.isOn = setting.isOn
            // No write error to report and no echo to wait for: this lands in UserDefaults
            // synchronously, so the switch is already telling the truth and the table needn't
            // rebuild around it.
            toggle.addAction(UIAction { [weak toggle] _ in
                guard let toggle else { return }
                setting.write(toggle.isOn)
            }, for: .valueChanged)
            cell.accessoryView = toggle
        case .unavailable:
            content.text = viewModel.state.settings.loaded
                ? "No chat settings available on this server"
                : "Couldn't load settings"
            content.textProperties.color = .secondaryLabel
            content.secondaryText = viewModel.state.settings.loaded
                // A server older than the app genuinely may not have these keys.
                ? "This server doesn't offer the settings this app can change."
                : "Check your connection and reopen Settings."
            content.secondaryTextProperties.numberOfLines = 0
        case .account:
            content.text = "Sign Out"
            content.textProperties.color = .systemRed
            cell.selectionStyle = .default
        case .about:
            content.text = "Lurker"
            content.secondaryText = Self.versionString
        }

        cell.contentConfiguration = content
        return cell
    }

    /// Attach the right control for the option's type. Only the types the curated key list
    /// actually uses are built; anything else renders as a plain row rather than a control
    /// that silently does nothing.
    private func configure(_ cell: UITableViewCell, for option: SettingOption) {
        let enabled = isEnabled(option.key)
        switch option.type {
        case .bool:
            let toggle = UISwitch()
            toggle.isOn = viewModel.state.settings.effective(option.key)?.boolValue
                ?? option.default.boolValue ?? false
            toggle.isEnabled = enabled
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                guard let self, let toggle else { return }
                write(option.key, .bool(toggle.isOn))
            }, for: .valueChanged)
            cell.accessoryView = toggle
        case .int:
            let value = viewModel.state.settings.effective(option.key)?.intValue
                ?? option.default.intValue ?? 0
            let stepper = UIStepper()
            // Bounds come from the registry, so the control can't offer a value the server
            // will reject.
            stepper.minimumValue = Double(option.min ?? 0)
            stepper.maximumValue = Double(option.max ?? 100)
            stepper.value = Double(value)
            stepper.isEnabled = enabled
            // The number itself, next to the stepper — a stepper alone shows you nothing.
            let label = UILabel()
            label.text = String(value)
            stepper.addAction(UIAction { [weak self, weak stepper, weak label] _ in
                guard let self, let stepper else { return }
                let next = Int(stepper.value)
                // Echo locally and immediately. Without this the number never moves until a
                // write lands, so the control reads one value while the stepper holds another.
                label?.text = String(next)
                scheduleWrite(option.key, .int(next))
            }, for: .valueChanged)
            label.font = .preferredFont(forTextStyle: .body)
            label.textColor = enabled ? .secondaryLabel : .tertiaryLabel
            label.adjustsFontForContentSizeCategory = true
            let stack = UIStackView(arrangedSubviews: [label, stepper])
            stack.spacing = 8
            stack.alignment = .center
            // `accessoryView` is positioned from the view's own frame, and `sizeToFit()` on a
            // stack view doesn't set one — it leaves the frame at zero, which UIKit lays out in
            // the cell's top-left corner on top of the label. Ask for the real fitting size and
            // assign it.
            stack.frame = CGRect(
                origin: .zero,
                size: stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            )
            cell.accessoryView = stack
        case .enum:
            // Every choice is offered, with the registry's own wording — this app implements
            // all three rungs of the event tier (#63 closed the last one), and nothing else
            // here is device-specific. Choice labels come from the registry
            // (`SettingOption.label(forChoice:)`), so the phone says what the web says without
            // a second copy to keep in step.
            let current = viewModel.state.settings.effective(option.key)?.stringValue
                ?? option.default.stringValue ?? ""
            cell.accessoryView = menuButton(
                current: current,
                choices: option.choices.map {
                    MenuChoice(value: $0, label: option.label(forChoice: $0), spoken: nil)
                },
                enabled: enabled
            ) { [weak self] choice in self?.write(option.key, .string(choice)) }
        case .string:
            // Only a key this screen has curated choices for. A `string` with no list gets a
            // plain row rather than a control that can't offer anything — the same rule the
            // `default` arm applies to the types no row uses.
            guard let curated = Self.stringChoices[option.key] else {
                cell.accessoryType = .none
                return
            }
            let stored = viewModel.state.settings.effective(option.key)?.stringValue
                ?? option.default.stringValue ?? ""
            let current = curated.normalize(stored)
            var values = curated.values
            // A value the web set that isn't one of ours is shown as itself and checked,
            // never silently rounded to a neighbour: the row has to say what is actually in
            // force, and picking one of the offered forms is how you leave it. It is dropped
            // from the list again as soon as it is, because it is only ever the stored value.
            if !values.contains(where: { $0.value == current }) {
                values.append((current, "nick\(current)"))
            }
            // Read aloud through the SAME function as the four, so the one value this control
            // can't otherwise explain is not the one it declines to name.
            let choices = values.map {
                MenuChoice(value: $0.value, label: $0.label, spoken: curated.spoken($0.value))
            }
            cell.accessoryView = menuButton(
                current: current, choices: choices, enabled: enabled
            ) { [weak self] choice in self?.write(option.key, .string(choice)) }
        default:
            cell.accessoryType = .none
        }
    }

    /// A pull-down showing the value in force, offering `choices`.
    ///
    /// A button, not a segmented control: the event tier's choices are full phrases ("Hide
    /// from quiet users"), and three of those never fit a compact-width segment without
    /// truncating to uselessness. The button shows the current choice, which is what the row
    /// needs to say when nothing is being touched.
    private func menuButton(
        current: String,
        choices: [MenuChoice],
        enabled: Bool,
        onPick: @escaping (String) -> Void
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.showsMenuAsPrimaryAction = true
        // Let UIKit track the selection so the checkmark follows a tap without a rebuild;
        // the write still goes through `write`, and the authoritative value arrives back
        // on the `settings` frame.
        button.changesSelectionAsPrimaryAction = true
        button.menu = UIMenu(children: choices.map { choice in
            let action = UIAction(
                title: choice.label, state: choice.value == current ? .on : .off
            ) { _ in onPick(choice.value) }
            action.accessibilityLabel = choice.spoken
            return action
        })
        // Set the title before measuring. `changesSelectionAsPrimaryAction` derives it from
        // the `.on` menu child, but that propagates on the button's next configuration-update
        // pass — after this synchronous `sizeToFit()`, which would leave `accessoryView`
        // fitted to an empty button and the control clipped on the first render of this
        // screen. Same class of trap as the stack-view sizing above.
        let selected = choices.first { $0.value == current }
        button.setTitle(selected?.label ?? current, for: .normal)
        // The button announces the value in force the same way its menu row does, or the row
        // reads as "nick" whatever it is set to.
        button.accessibilityLabel = selected?.spoken
        button.isEnabled = enabled
        button.sizeToFit()
        return button
    }

    /// Whether this row's control is live.
    ///
    /// Answered from the registry's own `dependsOn` (#666) rather than a table maintained
    /// here, so the phone greys out exactly what the web does and a new dependency needs no
    /// iOS change at all.
    private func isEnabled(_ key: String) -> Bool {
        viewModel.state.settings.isActive(key)
    }

    /// Pending debounced writes, keyed by setting.
    private var writeTimers: [String: Timer] = [:]

    /// How long a stepper run is allowed to settle before it's sent.
    private static let stepperDebounce: TimeInterval = 0.4

    /// Coalesce a run of taps into one write.
    ///
    /// A stepper held down (or tapped quickly) would otherwise fire a `PATCH` per increment,
    /// and every response rebuilds the table — which destroys the very `UIStepper` the finger
    /// is on, so a continuous press dies after one step and a fast double-tap sends the same
    /// value twice. Waiting for the run to settle sends one request carrying the final value,
    /// and no rebuild lands mid-gesture.
    private func scheduleWrite(_ key: String, _ value: SettingValue) {
        writeTimers[key]?.invalidate()
        // `.common`, so the run still settles while the table is being scrolled.
        let timer = Timer(timeInterval: Self.stepperDebounce, repeats: false) { [weak self] _ in
            guard let self else { return }
            writeTimers[key] = nil
            write(key, value)
        }
        RunLoop.main.add(timer, forMode: .common)
        writeTimers[key] = timer
    }

    /// Write one setting.
    ///
    /// The store is updated from the server's reply (`LurkerClient.updateSettings` applies the
    /// returned values), so a rejected write leaves the control exactly where the server still
    /// holds it rather than showing a state it never accepted.
    private func write(_ key: String, _ value: SettingValue) {
        Task { [weak self] in
            guard let self else { return }
            guard let failure = await viewModel.updateSettings([key: value]) else {
                // Success: the client applied the reply's values, so the store changed and the
                // subscription has already rebuilt (and cleared any error). Rebuilding again
                // here would just be a second table reload for the same event.
                //
                // The exception is a write that changed nothing — setting a value it already
                // held. The store doesn't move, `removeDuplicates` swallows it, and nothing
                // clears a rejection left over from last time.
                if writeError != nil {
                    writeError = nil
                    rebuild()
                }
                return
            }
            // Rejected. Show the server's reason and put the control back to the value it
            // still holds.
            writeError = (key, failure)
            rebuild()
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section] {
        case .networks:
            // Pushed, not presented: this is a place you go *inside* Settings and come back
            // from. Note the sheet's Done goes with it — it lives on this screen's own
            // `navigationItem` — so the way out is Back and then Done, which is the standard
            // pattern and not something the pushed screen should paper over with a Done of
            // its own.
            navigationController?.pushViewController(
                NetworksViewController(viewModel: viewModel), animated: true
            )
        case .account:
            confirmSignOut()
        default:
            break
        }
    }

    /// Sign-out asks first. It's one tap from a settings list, it ends the session on the
    /// server, and the way back in is a password the user may not have to hand.
    private func confirmSignOut() {
        let sheet = UIAlertController(
            title: "Sign out of Lurker?",
            message: "You'll need your password to sign back in.",
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Sign Out", style: .destructive) { [weak self] _ in
            // `presentingViewController`, not `self`: `self.dismiss` sent while UIKit is still
            // tearing down the alert dismisses the ALERT and leaves this sheet on screen — a
            // stranded Settings sheet floating over the sign-in root. Naming the presenter is
            // unambiguous whichever order those two finish in.
            guard let self else { return }
            let presenter = presentingViewController
            presenter?.dismiss(animated: true) { [weak self] in self?.viewModel.logout() }
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = tableView
            // Found by identity rather than counted back from the end, which silently pointed
            // at the wrong section the moment the section list changed shape.
            let accountSection = sections.firstIndex { if case .account = $0 { return true }; return false }
            popover.sourceRect = tableView.rectForRow(
                at: IndexPath(row: 0, section: accountSection ?? 0)
            )
        }
        present(sheet, animated: true)
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Version \(version) (\(build))"
    }
}
