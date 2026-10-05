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
@MainActor
final class InvitePrompt {
    private let viewModel: ChatViewModel
    /// What to present over: the sheet on top, else the root. Nil when there's nowhere sensible.
    private let host: () -> UIViewController?
    private weak var alert: UIAlertController?

    init(viewModel: ChatViewModel, host: @escaping () -> UIViewController?) {
        self.viewModel = viewModel
        self.host = host
    }

    func offer(networkId: Int, channel: String, from: String) {
        guard alert == nil, let host = host(), !(host is UIAlertController),
              !host.isBeingDismissed, !host.isBeingPresented
        else { return }
        let network = viewModel.state.networks[networkId]?.displayName
        let alert = UIAlertController(
            title: "Invitation to \(channel)",
            message: network.map { "\(from) invited you on \($0)." } ?? "\(from) invited you.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))
        let join = UIAlertAction(title: "Join", style: .default) { [weak self] _ in
            // On success the app is taken there by `onJoinOpened`; a refusal comes back through
            // `onJoinNotice`, the same as a join from the Join Channel sheet.
            self?.viewModel.requestJoin(networkId: networkId, channel: channel, opens: true)
        }
        alert.addAction(join)
        alert.preferredAction = join
        self.alert = alert
        host.present(alert, animated: true)
    }
}
