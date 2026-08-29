// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// "Which network?" — the first step of adding one (#11).
///
/// It exists because the alternative first step is a blank field asking for a hostname and a
/// port, and the person most likely to be adding their first network is exactly the person
/// who doesn't know that `irc.libera.chat` listens on 6697. Picking a row fills in everything
/// but the nick.
///
/// **No tags, no popularity sort, no filter chips** — the web's picker has them and a phone
/// has the least room for them. The list is already ordered usefully (networks with a #lurker
/// channel first, then by size) and a search field beats a facet row at reaching one of 95
/// names on a screen this size.
final class NetworkPickerViewController: UITableViewController, UISearchResultsUpdating {

    private enum Row {
        case preset(NetworkPreset)
        /// The manual path. Absent entirely on a locked-down instance — see `apply`.
        case custom
    }

    private let viewModel: ChatViewModel
    private let onPicked: (NetworkDraft) -> Void
    /// Set only when this screen is the root of its own presentation, where there is no back
    /// button and it would otherwise be a sheet with no way out. Pushed, it goes unset and
    /// the navigation controller's own Back does the job.
    private let onCancel: (() -> Void)?
    /// Every preset on offer, before the search field narrows it.
    private var offered: [NetworkPreset] = BuiltinNetworks.all
    private var allowsCustom = true
    private var rows: [Row] = []
    private var query = ""
    private let placeholderView = StateView()
    private var shownPlaceholder: StateView.Model?

    init(
        viewModel: ChatViewModel,
        onCancel: (() -> Void)? = nil,
        onPicked: @escaping (NetworkDraft) -> Void
    ) {
        self.viewModel = viewModel
        self.onCancel = onCancel
        self.onPicked = onPicked
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Add Network"
        if let onCancel {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                systemItem: .cancel, primaryAction: UIAction { _ in onCancel() }
            )
        }
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "preset")

        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Search networks"
        search.searchBar.autocapitalizationType = .none
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false

        // The bundled catalogue is already on the device, so this never needs a spinner: the
        // fetch only adds this instance's own networks and its policy, and on failure we keep
        // what we shipped with, because a request that didn't arrive is no reason to refuse
        // to add a network. (It can still come back EMPTY — see `updatePlaceholder`.)
        rebuild()
        Task { [weak self] in
            guard let self, let presets = await viewModel.networkPresets() else { return }
            offered = presets.offered
            allowsCustom = presets.allowUserDefined
            rebuild()
        }
    }

    private func rebuild() {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = needle.isEmpty
            ? offered
            // Host as well as name: someone who knows they want OFTC may well type
            // "oftc.net", and someone pasting a hostname from a wiki should find it.
            : offered.filter {
                $0.name.lowercased().contains(needle) || $0.host.lowercased().contains(needle)
            }
        rows = matches.map(Row.preset)
        // ⚠⚠ Only where the instance allows it. With `allowUserDefined` off, the enabled
        // presets are the entire allowed host set, so a custom server would be a form whose
        // save can only 403 — and offering it would be promising something the server has
        // already said no to.
        if allowsCustom { rows.append(.custom) }
        tableView.reloadData()
        updatePlaceholder(matched: !matches.isEmpty)
    }

    /// ⚠ The list CAN be empty, despite the catalogue being on the device: a locked-down
    /// instance (`allowUserDefined: false`) offers its own networks and nothing else, so an
    /// admin who has enabled none leaves nothing to show — and the custom-server row is
    /// suppressed too, because a network the allowlist excludes can only 403. A blank screen
    /// is the one answer that explains nothing, and it's reachable on a configuration that
    /// means "nobody may add a network here", which is exactly when a user needs telling.
    private func updatePlaceholder(matched: Bool) {
        let model: StateView.Model? = {
            guard rows.isEmpty else { return nil }
            // Two different blanks: nothing on offer at all, versus a search that missed.
            guard matched || query.trimmingCharacters(in: .whitespaces).isEmpty else {
                return .init(symbol: "magnifyingglass", title: "No matches")
            }
            return .init(
                symbol: "network.slash",
                title: "No networks available",
                subtitle: "This server's administrator chooses which networks can be added."
            )
        }()
        guard model != shownPlaceholder else { return }
        shownPlaceholder = model
        if let model {
            placeholderView.configure(model)
            tableView.backgroundView = placeholderView
        } else {
            tableView.backgroundView = nil
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        query = searchController.searchBar.text ?? ""
        rebuild()
    }

    // MARK: - Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        // Nothing to footnote when there are no rows — the placeholder is saying it instead,
        // and both at once is the same sentence twice.
        guard !allowsCustom, !rows.isEmpty else { return nil }
        // Said once, at the bottom, rather than leaving the absence of a "custom" row to be
        // noticed: a user hunting for the network they use needs to know it isn't missing by
        // accident.
        return "This server's administrator chooses which networks can be added."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "preset", for: indexPath)
        var content = cell.defaultContentConfiguration()
        switch rows[indexPath.row] {
        case .preset(let preset):
            content.text = preset.name
            content.secondaryText = preset.isInstance
                // The admin's own networks say so, because "why is this one at the top" is
                // otherwise a mystery, and on a locked-down instance it's the whole answer.
                ? "\(preset.host) · offered by this server"
                : preset.host
            content.secondaryTextProperties.color = .secondaryLabel
            cell.accessoryType = .disclosureIndicator
        case .custom:
            content.text = "Other Server…"
            content.image = UIImage(systemName: "server.rack")
            cell.accessoryType = .disclosureIndicator
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch rows[indexPath.row] {
        case .preset(let preset): onPicked(preset.draft())
        // A blank draft, not a half-filled one: "other" means the user is going to type a
        // hostname, and leaving a previous pick's name in the field would be a form that
        // starts out lying about which server it's for.
        case .custom: onPicked(NetworkDraft())
        }
    }
}
