// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

/// Offers a Join when someone invites us to a channel (lurker#261): "bob invited you to
/// #secret" — Not Now, Join. The phone's version of the web's toast with a Join button; an
/// alert because this app's toasts take no touches.
///
/// A convenience, not a question anyone is waiting on, which is where it parts from
/// `DccOfferPrompt`. The system buffer already holds the invitation, and `/join` works from
/// there, so an invite that arrives while something else is up — another alert, a sheet on the
/// move, an invite already being asked about — is simply not asked about. That also keeps an
/// invite flood to one alert.
///
/// It also offers an Accept when our caller ID (+g) discarded someone's message (lurker#1184):
/// "bob tried to message you" — Not Now, Accept. The same kind of moment, so the same rules,
/// and one alert between the two.
@MainActor
final class InvitePrompt {
    private let viewModel: ChatViewModel
    /// What to present over: the sheet on top, else the root. Nil when there's nowhere sensible.
    private let host: () -> UIViewController?
    private weak var alert: UIAlertController?
    /// An Accept that couldn't go: the network isn't connected.
    private let onRefusal: (String) -> Void

    init(
        viewModel: ChatViewModel,
        host: @escaping () -> UIViewController?,
        onRefusal: @escaping (String) -> Void
    ) {
        self.viewModel = viewModel
        self.host = host
        self.onRefusal = onRefusal
    }

    func offer(networkId: Int, channel: String, from: String) {
        let network = viewModel.state.networks[networkId]?.displayName
        present(
            title: "Invitation to \(channel)",
            message: network.map { "\(from) invited you on \($0)." } ?? "\(from) invited you.",
            action: "Join"
        ) { [weak self] in
            // On success the app is taken there by `onJoinOpened`; a refusal comes back through
            // `onJoinNotice`, the same as a join from the Join Channel sheet.
            self?.viewModel.requestJoin(networkId: networkId, channel: channel, opens: true)
        }
    }

    /// Accept lets their NEXT message through; the one that was blocked is gone.
    func offerAccept(networkId: Int, from: String) {
        let network = viewModel.state.networks[networkId]?.displayName
        let place = network.map { " on \($0)" } ?? ""
        present(
            title: "\(from) tried to message you",
            message: "Caller ID blocked it\(place). Accept to let their next message through.",
            action: "Accept"
        ) { [weak self] in
            guard let self, !viewModel.acceptCaller(networkId: networkId, nick: from) else { return }
            onRefusal("Couldn't accept \(from) — \(network ?? "the network") isn't connected.")
        }
    }

    private func present(title: String, message: String, action: String, perform: @escaping () -> Void) {
        guard alert == nil, let host = host(), !(host is UIAlertController),
              !host.isBeingDismissed, !host.isBeingPresented
        else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))
        let primary = UIAlertAction(title: action, style: .default) { _ in perform() }
        alert.addAction(primary)
        alert.preferredAction = primary
        self.alert = alert
        host.present(alert, animated: true)
    }
}
