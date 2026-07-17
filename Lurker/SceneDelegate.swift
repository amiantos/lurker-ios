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
    /// Owned here, not by the view model, so LurkerKit stays off the `Network` framework.
    /// This is the same shape as `enterForeground`/`enterBackground`: the app observes the
    /// device and feeds facts in.
    private let reachability = ReachabilityMonitor()

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

        // Drives the indicator light's red: the socket only ever reports
        // connecting/connected/reconnecting, so without the OS's view of the path there'd
        // be no way to tell "no internet" from "still trying".
        reachability.start { [viewModel] reachable in
            viewModel.setReachable(reachable)
        }
    }

    // A socket dies after a long background; the view model reconnects (and resumes from
    // `?since=`) when we come back, and stops trying while we're away.
    func sceneDidBecomeActive(_ scene: UIScene) {
        viewModel.enterForeground()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        viewModel.enterBackground()
    }

    /// The system reclaimed this scene. `NWPathMonitor` is retained by the dispatch source
    /// it starts and only released by `cancel()`, and it holds a closure that captures the
    /// view model — so without this the monitor outlives the scene and keeps the view
    /// model, the client, and its WebSocket alive for good.
    func sceneDidDisconnect(_ scene: UIScene) {
        reachability.stop()
    }

    /// Idempotent: swaps the root only when the on-screen screen doesn't match the
    /// session state, so a replayed/duplicate value is a no-op.
    ///
    /// Signing in lands on the system buffer rather than a list of buffers. It's the app's
    /// own buffer — always present, and constructible without waiting on a frame — so it's
    /// somewhere to *be* while the snapshot arrives, and it's where Lurker says what it's
    /// doing. The buffer list is a sheet off the title pill from there.
    private func render(_ session: ChatViewModel.SessionState, animated: Bool) {
        guard let navigation else { return }
        switch session {
        case .loggedIn:
            // Checked against `first`, not `last`: switching buffers replaces the root
            // with another ChatViewController, and re-rendering must not throw that away.
            if !(navigation.viewControllers.first is ChatViewController) {
                navigation.setViewControllers(
                    [ChatViewController(viewModel: viewModel, buffer: .system)], animated: animated
                )
            }
        case .loggedOut:
            if !(navigation.viewControllers.last is LoginViewController) {
                // Drop anything presented first. The buffer-list sheet is presented by the
                // navigation controller, so swapping its stack doesn't take the sheet with
                // it — a mid-session 401 with the list open would leave it sitting over the
                // sign-in screen, still subscribed, rendering a now-empty list.
                navigation.dismiss(animated: false)
                navigation.setViewControllers([LoginViewController(viewModel: viewModel)], animated: animated)
            }
        case .loggingIn:
            break // stay on the login screen; it shows its own spinner
        }
    }
}
