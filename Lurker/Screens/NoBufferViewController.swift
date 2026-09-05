// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import UIKit

/// What the detail column shows before a buffer is picked.
///
/// An iPad-only screen, and deliberately so: it exists because a two-column layout has a second
/// column that has to say *something*, which is a problem a single stack never had. The
/// collapsed layout never shows it — `BufferSplitViewController` clears the column rather than
/// let this land on a phone's navigation stack, where "no buffer selected" would be a screen
/// pushed on top of the list you just came from.
///
/// Not `PillPresenting`: the pill names the conversation you're in, and there isn't one.
final class NoBufferViewController: UIViewController {

    private let placeholder = StateView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        placeholder.configure(.init(
            symbol: "bubble.left.and.bubble.right",
            title: "No Conversation Selected",
            subtitle: "Pick a buffer from the list to start reading."
        ))
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.topAnchor.constraint(equalTo: view.topAnchor),
            placeholder.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            placeholder.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }
}
