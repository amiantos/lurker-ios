// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine
import LurkerKit
import UIKit

/// What a paused account sees instead of the app (ios#18): the server won't connect it to IRC or
/// take a write, so there's nothing to do here but wait, or sign out and use another account.
///
/// ⚠ No way to reactivate from here, on purpose. On lurker.chat a pause is billing, and a link to
/// pay outside the store is what App Review rejects. A self-hosted account was paused by its admin,
/// and the copy says to ask them.
///
/// `SceneDelegate` takes this down when the account is resumed — the socket stays open while
/// paused, so that arrives live — or when the session ends.
final class PausedAccountViewController: UIViewController {
    private let viewModel: ChatViewModel
    private let stateView = StateView()
    private var cancellables = Set<AnyCancellable>()

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not using storyboards") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        stateView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stateView)
        NSLayoutConstraint.activate([
            stateView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stateView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        stateView.onAction = { [weak self] in self?.viewModel.logout() }
        // Followed rather than read once: whether the server is hosted comes from `/api/config`,
        // which can answer after the pause did.
        viewModel.accessPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] access in self?.render(access) }
            .store(in: &cancellables)
    }

    private func render(_ access: AccountAccess) {
        guard case .paused(let hosted) = access else { return }
        stateView.configure(StateView.Model(
            symbol: "pause.circle",
            title: "This account is paused",
            subtitle: hosted ? nil : "Ask your server's admin to restore it.",
            actionTitle: "Sign Out"
        ))
    }
}
