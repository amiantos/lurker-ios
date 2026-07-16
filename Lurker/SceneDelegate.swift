// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine
import LurkerKit
import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    // One view model for the app's lifetime. It owns the client (session token + socket)
    // and the store. The token now survives relaunch in the Keychain (#3), so a returning
    // user lands straight on their buffers.
    private let viewModel = ChatViewModel()
    private var cancellables = Set<AnyCancellable>()
    private weak var navigation: UINavigationController?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let nav = UINavigationController()
        navigation = nav

        // Restore already ran in the view model's init, so the current session state is
        // known — build the right screen up front, no login flash on a restored session.
        render(viewModel.session, animated: false)

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = nav
        window.makeKeyAndVisible()
        self.window = window

        // Session transitions drive navigation: sign-in and restore → the buffer list;
        // sign-out and a mid-session 401 → back to sign-in (with an explanation).
        viewModel.sessionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] session in self?.render(session, animated: true) }
            .store(in: &cancellables)
    }

    /// Idempotent: swaps the root only when the on-screen screen doesn't match the
    /// session state, so a replayed/duplicate value is a no-op.
    private func render(_ session: ChatViewModel.SessionState, animated: Bool) {
        guard let navigation else { return }
        switch session {
        case .loggedIn:
            if !(navigation.viewControllers.last is BufferListViewController) {
                navigation.setViewControllers([BufferListViewController(viewModel: viewModel)], animated: animated)
            }
        case .loggedOut:
            if !(navigation.viewControllers.last is LoginViewController) {
                navigation.setViewControllers([LoginViewController(viewModel: viewModel)], animated: animated)
            }
        case .loggingIn:
            break // stay on the login screen; it shows its own spinner
        }
    }
}
