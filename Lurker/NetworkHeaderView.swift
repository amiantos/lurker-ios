// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// A network's section header in the buffer switcher: its name, and a "+" to join a channel
/// on it.
///
/// The button sits here rather than on the navigation bar because a header already states
/// which network it belongs to. A "+" anywhere else has to establish that itself — with a
/// menu of networks, or a form with a picker — and both are machinery for a question this
/// position answers for free. It's the web client's `net-add`, in the same place.
///
/// The title keeps the system's own header styling by going through
/// `defaultContentConfiguration()`, so it stays in step with the plain-string headers in the
/// same table rather than being a hand-matched imitation that drifts.
final class NetworkHeaderView: UITableViewHeaderFooterView {

    private let addButton = UIButton(type: .system)
    private var onAdd: (() -> Void)?

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)

        addButton.setImage(UIImage(systemName: "plus"), for: .normal)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.addAction(UIAction { [weak self] _ in self?.onAdd?() }, for: .touchUpInside)
        // A bare glyph in a header is a small target; this brings it up toward the 44pt
        // minimum without making the header itself taller.
        addButton.configuration = {
            var config = UIButton.Configuration.plain()
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
            return config
        }()
        // Added to the header itself, NOT to `contentView`: setting `contentConfiguration`
        // hands `contentView` over to the configuration, and anything already in there is
        // simply not drawn. (Verified — the button rendered nowhere at all.) Living outside
        // it also puts the button above the configuration's view, so it takes its own taps.
        addSubview(addButton)

        NSLayoutConstraint.activate([
            addButton.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    func configure(title: String, network: Network, onAdd: @escaping () -> Void) {
        var content = defaultContentConfiguration()
        content.text = title
        // Keep the label clear of the button: a long "libera — reconnecting…" would
        // otherwise run underneath it.
        content.directionalLayoutMargins.trailing += 44
        contentConfiguration = content

        // Disabled off the connected state, matching the web's `net-add`. A JOIN sent with
        // no socket to travel down goes nowhere, and nothing comes back to say so — the
        // channel would simply never appear.
        let connected = network.state == .connected
        addButton.isEnabled = connected
        addButton.accessibilityLabel = connected
            ? "Join a channel on \(network.name)"
            : "Join a channel on \(network.name) — not connected"
        self.onAdd = onAdd
    }
}
