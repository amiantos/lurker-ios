// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    // One client for the app's lifetime. It holds the session token and the socket, so
    // it outlives any single screen. State dies with the process — this is a prototype;
    // there is no Keychain, no persistence, and you sign in again every launch.
    private let client = LurkerClient()

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UINavigationController(
            rootViewController: LoginViewController(client: client)
        )
        window.makeKeyAndVisible()
        self.window = window
    }
}
