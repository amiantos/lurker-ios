// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine
import LurkerKit
import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    // One view model for the app's lifetime. It owns the client (session token + socket)
    // and the store, so it outlives any single screen. State still dies with the process:
    // #2 has no Keychain persistence — that's #3 — so you sign in again every launch.
    private let viewModel = ChatViewModel()
    private var cancellables = Set<AnyCancellable>()

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let navigation = UINavigationController(rootViewController: LoginViewController(viewModel: viewModel))
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        self.window = window

        // A session that ends mid-use (a 401 — expiry, or revocation from another device)
        // drops us back to sign-in rather than leaving a dead, stale screen. A fuller
        // bounce with persistence is #3; this is the minimum so a lost session isn't a
        // dead end.
        viewModel.sessionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak navigation] session in
                guard let self, let navigation, session == .loggedOut else { return }
                let alreadyAtLogin = navigation.viewControllers.count == 1
                    && navigation.viewControllers.first is LoginViewController
                guard !alreadyAtLogin else { return }
                navigation.setViewControllers([LoginViewController(viewModel: self.viewModel)], animated: true)
            }
            .store(in: &cancellables)
    }
}
