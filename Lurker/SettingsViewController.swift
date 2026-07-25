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
/// Visual customization stays out of 1.0 (`APP_1.0_SCOPE.md`); these are behavior knobs the
/// app already implements.
final class SettingsViewController: UITableViewController {
    private let viewModel: ChatViewModel
    private var cancellables = Set<AnyCancellable>()

    /// The server settings this screen offers, in display order, with the label to show.
    ///
    /// **Add a key here only when the app honors it.** Each one is wired to real behavior:
    /// typing to `ChatViewController.emitTyping`, both consolidation keys to `buildRows`. The
    /// rest of the registry is deliberately absent — the web is where you configure the things
    /// the phone doesn't implement, and a control for a setting the app ignores is worse than
    /// no control at all.
    private static let chatSettings: [(key: String, label: String)] = [
        ("chat.send_typing_notifications", "Send typing notifications"),
        ("chat.consolidate_joins", "Consolidate events"),
        ("chat.consolidate_max_names", "Max consolidated nicks"),
    ]

    /// Keys whose control is dead unless another setting is on — a max-nicks stepper means
    /// nothing with consolidation switched off.
    private static let dependencies = ["chat.consolidate_max_names": "chat.consolidate_joins"]

    /// A row that's ready to render: the curated label plus the registry entry describing how
    /// to edit it. Resolved once per rebuild so the table isn't doing lookups per cell.
    private struct SettingRow {
        let label: String
        let option: SettingOption
    }

    private enum Section {
        case chat([SettingRow])
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
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
        rebuild()
    }

    private func rebuild() {
        let registry = viewModel.state.settings.registry
        // Only what this server actually knows about. A self-hosted instance can legitimately
        // be older than the app (`APP_1.0_SCOPE.md`), so a key it's never heard of gets no row
        // rather than a control whose write would be rejected.
        let rows = Self.chatSettings.compactMap { entry in
            registry[entry.key].map { SettingRow(label: entry.label, option: $0) }
        }
        sections = rows.isEmpty ? [.account, .about] : [.chat(rows), .account, .about]
        tableView.reloadData()
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .chat(let rows): rows.count
        case .account, .about: 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .chat: "Chat"
        case .account, .about: nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch sections[section] {
        // The one piece of explanation that stays: it isn't obvious that a switch here moves
        // the same switch in your browser, and that's a property worth stating rather than
        // leaving someone to discover. Everything else the registry would say is reference
        // material, and the web has room for it.
        case .chat: "Saved to your account and applied on every device."
        case .account, .about: nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.selectionStyle = .none
        var content = cell.defaultContentConfiguration()

        switch sections[indexPath.section] {
        case .chat(let rows):
            let row = rows[indexPath.row]
            content.text = row.label
            // The subtitle slot is otherwise unused, so a failed write can say why right under
            // the control that failed.
            if let error = writeError, error.key == row.option.key {
                content.secondaryText = error.message
                content.secondaryTextProperties.color = .systemRed
                content.secondaryTextProperties.numberOfLines = 0
            }
            configure(cell, for: row.option)
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
            stepper.addAction(UIAction { [weak self, weak stepper] _ in
                guard let self, let stepper else { return }
                write(option.key, .int(Int(stepper.value)))
            }, for: .valueChanged)
            // The number itself, next to the stepper — a stepper alone shows you nothing.
            let label = UILabel()
            label.text = String(value)
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
        default:
            cell.accessoryType = .none
        }
    }

    /// Whether this row's control is live — false when it depends on a setting that's off.
    private func isEnabled(_ key: String) -> Bool {
        guard let parent = Self.dependencies[key] else { return true }
        return viewModel.state.settings.bool(parent, default: true)
    }

    /// Write one setting. The store isn't touched here: the server validates, stores, and fans
    /// a `settings` frame back, which is what actually moves the control. So a rejected write
    /// leaves the UI where it was — the switch springs back on the rebuild — rather than
    /// showing a state the server never accepted.
    private func write(_ key: String, _ value: SettingValue) {
        Task { [weak self] in
            guard let self else { return }
            let failure = await viewModel.updateSettings([key: value])
            writeError = failure.map { (key, $0) }
            // Rebuild either way: on success the echo has landed, on failure this puts the
            // control back to the value the server still holds and surfaces why.
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
            self?.dismiss(animated: true) { self?.viewModel.logout() }
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = tableView
            popover.sourceRect = tableView.rectForRow(at: IndexPath(row: 0, section: sections.count - 2))
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
