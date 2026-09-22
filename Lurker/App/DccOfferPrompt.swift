// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine
import LurkerKit
import UIKit

/// Asks about a DCC chat offer (lurker#270): "bob wants to chat directly" — Decline, Not Now,
/// Accept. The phone's version of the web's sticky toast, shaped like AirDrop's prompt, which
/// is the same question: someone nearby wants a direct connection, yes or no.
///
/// An alert rather than a toast because this app's toasts take no touches, and an offer is a
/// decision someone is waiting on. It never auto-accepts — accepting makes the server dial an
/// address the peer chose, so it stays a deliberate act.
///
/// Each offer is asked about ONCE (`asked`, by `DccChatOffer.id`). A reconnect re-lists a
/// pending offer and keeps its id, so it doesn't ask again; a peer offering again mints a new
/// one, so it does. Not Now leaves the offer standing — `/dcc chat bob` or the chat's info
/// sheet can still accept it until it expires.
///
/// ⚠ Also asks about offers first learned from a snapshot, which the web deliberately doesn't.
/// A browser tab is usually open when an offer lands; a phone usually isn't — its socket
/// sleeps in the background, the offer sends no push, and the snapshot on the way back in is
/// the only way it hears. Skipping those would skip most of them.
@MainActor
final class DccOfferPrompt {
    private let viewModel: ChatViewModel
    /// What to present over: the sheet on top, else the root. Nil when there's nowhere sensible.
    private let host: () -> UIViewController?
    /// Where a refused Accept or Decline says why.
    private let onRefusal: (String) -> Void

    /// Offers already put in front of the user. Trimmed to the ones still pending, so it stays
    /// as small as the list.
    private var asked: Set<Int> = []
    private weak var alert: UIAlertController?
    private var alertOfferId: Int?
    private var retry: Task<Void, Never>?
    private var cancellable: AnyCancellable?

    init(
        viewModel: ChatViewModel,
        host: @escaping () -> UIViewController?,
        onRefusal: @escaping (String) -> Void
    ) {
        self.viewModel = viewModel
        self.host = host
        self.onRefusal = onRefusal
        // Every emission, not deduped on the offers: a prompt that couldn't be shown (another
        // alert up, a sheet mid-dismissal) is retried from the next one, and `update` is a scan
        // of a list that is almost always empty.
        cancellable = viewModel.statePublisher
            .map(\.dccChatOffers)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] offers in self?.update(offers) }
    }

    private func update(_ offers: [DccChatOffer]) {
        // The question is over when its offer is — accepted elsewhere, declined on the web,
        // expired, or signed out of. Left up, Accept would send the peer a FRESH offer instead,
        // a different act from the one the alert names.
        if let id = alertOfferId, !offers.contains(where: { $0.id == id }) {
            alertOfferId = nil
            alert?.dismiss(animated: true)
        }
        // Taken down by something else — a notification tap clears whatever is presented before
        // it navigates. That's a Not Now: the offer stands, and the next one may be asked.
        if alertOfferId != nil, alert == nil { alertOfferId = nil }
        asked.formIntersection(offers.map(\.id))
        guard alertOfferId == nil, let offer = offers.first(where: { !asked.contains($0.id) }) else {
            return
        }
        // Not over another alert, and not onto a screen mid-transition: UIKit drops a
        // presentation from either. Try again shortly rather than lose the question.
        guard let host = host(), !(host is UIAlertController),
              !host.isBeingDismissed, !host.isBeingPresented
        else {
            scheduleRetry()
            return
        }
        present(offer, over: host)
    }

    private func present(_ offer: DccChatOffer, over host: UIViewController) {
        let network = viewModel.state.networks[offer.networkId]?.displayName
        var message = network.map { "\(offer.nick) on \($0) wants to chat directly." }
            ?? "\(offer.nick) wants to chat directly."
        if offer.passive {
            message += " They're behind a firewall, so your Lurker server would listen for them."
        }
        let alert = UIAlertController(
            title: "DCC chat from \(offer.nick)", message: message, preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Decline", style: .destructive) { [weak self] _ in
            self?.answered {
                await $0.closeDccChat(networkId: offer.networkId, nick: offer.nick)
            }
        })
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel) { [weak self] _ in
            self?.answered(nil)
        })
        let accept = UIAlertAction(title: "Accept", style: .default) { [weak self] _ in
            // On success the app is taken to the chat by `onDccChatOpened`.
            self?.answered {
                await $0.openDccChat(networkId: offer.networkId, nick: offer.nick)
            }
        }
        alert.addAction(accept)
        alert.preferredAction = accept
        asked.insert(offer.id)
        alertOfferId = offer.id
        self.alert = alert
        host.present(alert, animated: true)
    }

    /// The alert is down: run the verb, report a refusal, and ask about the next offer if one
    /// was queued behind this one.
    private func answered(_ verb: ((ChatViewModel) async -> String?)?) {
        alertOfferId = nil
        let viewModel = viewModel
        Task { [weak self] in
            if let verb, let refusal = await verb(viewModel) { self?.onRefusal(refusal) }
        }
        // Next turn: the alert is still on its way down, and presenting over it would fail.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            update(self.viewModel.state.dccChatOffers)
        }
    }

    private func scheduleRetry() {
        guard retry == nil else { return }
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            retry = nil
            update(viewModel.state.dccChatOffers)
        }
    }
}
