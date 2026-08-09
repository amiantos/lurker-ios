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
    ]

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

    /// Suffix marking a choice this app reads but doesn't act on.
    ///
    /// The choice text itself comes from the registry (`SettingOption.label(forChoice:)`), so
    /// the phone says what the web says without a second copy to keep in step. What's local
    /// is this: `smart` renders as "no filter" here (see `EventMode.smart`), and it only ever
    /// appears in the picker when it is already the stored value, so the row has to report
    /// what is actually in force rather than quietly reading back as something else.
    private static let unsupportedChoiceSuffix = " (web only)"

    /// A row that's ready to render: the curated label plus the registry entry describing how
    /// to edit it. Resolved once per rebuild so the table isn't doing lookups per cell.
    private struct SettingRow {
        let label: String
        let option: SettingOption
    }

    private enum Section {
        case chat([SettingRow])
        case events([SettingRow])
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
        // partial Events section is normal and an absent one has to be too.
        // The device section is unconditional — it needs no registry, and it's the one part of
        // this screen that still works on a server too old (or too unreachable) to describe
        // itself.
        sections = rows.isEmpty
            ? [.unavailable, .device, .account, .about]
            : [.chat(rows)]
                + (eventRows.isEmpty ? [] : [.events(eventRows)])
                + (appearanceRows.isEmpty ? [] : [.appearance(appearanceRows)])
                + [.device, .account, .about]
        tableView.reloadData()
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .chat(let rows), .events(let rows), .appearance(let rows): rows.count
        case .device: DeviceSetting.allCases.count
        case .unavailable, .account, .about: 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .chat, .unavailable: "Chat"
        case .events: "Events"
        case .appearance: "Appearance"
        case .device: "This Device"
        case .account, .about: nil
        }
    }

    /// One footer, on the one section that needs to explain itself: the rest of this screen
    /// follows you between clients, and this doesn't.
    ///
    /// Phrased about this section alone rather than as "the settings above are shared" —
    /// which reads fine under a full screen and is a lie in the no-registry branch, where the
    /// only thing above it is the notice saying the settings couldn't be loaded.
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard case .device = sections[section] else { return nil }
        return "Applies to this device only — not shared with your other Lurker clients."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.selectionStyle = .none
        var content = cell.defaultContentConfiguration()

        switch sections[indexPath.section] {
        case .chat(let rows), .events(let rows), .appearance(let rows):
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
            // A pull-down button, not a segmented control: the choices are full phrases
            // ("Hide from quiet users"), and three of those never fit a compact-width segment
            // without truncating to uselessness. The button shows the current choice, which is
            // what the row needs to say when nothing is being touched.
            let current = viewModel.state.settings.effective(option.key)?.stringValue
                ?? option.default.stringValue ?? ""
            // Choice filtering and labels are the EVENT TIER's, so they're gated on its key.
            // This branch serves any `.enum` option; left ungated, the next enum setting
            // added here would silently lose a choice it happened to spell `smart` and get
            // `all`/`none` relabelled "Show all"/"Hide all".
            let isEventTier = option.key == EventFilter.modeKey
            let button = UIButton(type: .system)
            button.showsMenuAsPrimaryAction = true
            // Let UIKit track the selection so the checkmark follows a tap without a rebuild;
            // the write still goes through `write`, and the authoritative value arrives back
            // on the `settings` frame.
            button.changesSelectionAsPrimaryAction = true
            // A rung this app can't deliver is offered only when it's ALREADY the value —
            // the key is shared with the web, so a choice made at a desk has to stay visible
            // here, but the picker must not let you newly pick something we'd then ignore.
            let choices = option.choices.filter { choice in
                guard isEventTier else { return true }
                return choice == current
                    || EventMode(rawValue: choice).map(EventFilter.isSelectable) ?? true
            }
            let title = { (choice: String) -> String in
                let base = option.label(forChoice: choice)
                let unsupported =
                    isEventTier && !(EventMode(rawValue: choice).map(EventFilter.isSelectable) ?? true)
                return unsupported ? base + Self.unsupportedChoiceSuffix : base
            }
            button.menu = UIMenu(children: choices.map { choice in
                UIAction(title: title(choice), state: choice == current ? .on : .off) {
                    [weak self] _ in
                    self?.write(option.key, .string(choice))
                }
            })
            // Set the title before measuring. `changesSelectionAsPrimaryAction` derives it
            // from the `.on` menu child, but that propagates on the button's next
            // configuration-update pass — after this synchronous `sizeToFit()`, which would
            // leave `accessoryView` fitted to an empty button and the control clipped on the
            // first render of this screen. Same class of trap as the stack-view sizing above.
            button.setTitle(title(current), for: .normal)
            button.isEnabled = enabled
            button.sizeToFit()
            cell.accessoryView = button
        default:
            cell.accessoryType = .none
        }
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
        guard case .account = sections[indexPath.section] else { return }
        confirmSignOut()
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
