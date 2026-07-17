// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine
import LurkerKit
import UIKit
import UserNotifications

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
    /// Same shape again: the app owns the OS-facing bit (permission, APNs) and feeds the
    /// resulting token into the view model.
    private let push = PushRegistrar()

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
            .sink { [weak self] session in
                self?.render(session, animated: true)
                // Signing in is the moment push becomes askable — there's finally an
                // account to attach a device to. Needed alongside sceneDidBecomeActive
                // because the first sign-in happens while the scene is already active, and
                // would otherwise wait for a background/foreground round trip to register.
                self?.enablePushIfSignedIn()
            }
            .store(in: &cancellables)

        // Drives the indicator light's red: the socket only ever reports
        // connecting/connected/reconnecting, so without the OS's view of the path there'd
        // be no way to tell "no internet" from "still trying".
        reachability.start { [viewModel] reachable in
            viewModel.setReachable(reachable)
        }

        // Keep the app-icon badge honest (#490). A push sets it via `aps.badge` and then
        // nothing ever revises it, so without this the icon keeps claiming three unread
        // highlights after you've read all three — until the next push happens to carry a
        // smaller number. Driven off state so it follows read-state broadcasts (including
        // ones caused by another device), which is the same thing the web client's
        // useAppBadge does.
        viewModel.statePublisher
            .map(\.totalHighlights)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { count in
                // setBadgeCount(0) is how you clear it; there's no separate call.
                UNUserNotificationCenter.current().setBadgeCount(count) { error in
                    guard let error else { return }
                    // Best-effort: a wrong badge is not worth failing anything over, but a
                    // silent failure here is exactly why a stale badge is hard to diagnose.
                    NSLog("[push] could not set app badge: %@", error.localizedDescription)
                }
            }
            .store(in: &cancellables)

        AppDelegate.tapHandler = self
        // A tap that cold-launched the app arrived before this scene existed, so the
        // AppDelegate parked it. Drain it now that there's something to navigate with.
        if let pending = AppDelegate.pendingTap {
            AppDelegate.pendingTap = nil
            open(pending)
        }
    }

    /// In flight, if any. Two paths legitimately want to enable push — the session
    /// transition and scene activation — and on a restored launch BOTH fire, because
    /// sessionPublisher is a CurrentValueSubject that replays `.loggedIn` the moment we
    /// subscribe. Without this they'd race and each do the full round trip.
    private var pushEnableTask: Task<Void, Never>?

    /// Ask for push once we're signed in — never before. Notification permission is a
    /// one-shot grant, and a prompt on the sign-in screen asks the user to authorize
    /// notifications for an account they haven't named yet.
    private func enablePushIfSignedIn() {
        guard viewModel.session == .loggedIn, pushEnableTask == nil else { return }
        pushEnableTask = Task { [weak self] in
            defer { self?.pushEnableTask = nil }
            guard let self else { return }
            let outcome = await push.enable(serverSupportsAPNs: { [viewModel] in
                await viewModel.serverSupportsAPNs()
            })
            switch outcome {
            case .registering:
                break // the token lands in AppDelegate.didRegister…
            case .unsupportedByServer:
                // Expected on a self-hosted server: it has no Apple key and never will.
                // Not an error, and not the user's problem — the PWA is their push path.
                // (A server we couldn't REACH also lands here, but isn't remembered as
                // unsupported, so the next activation asks again.)
                NSLog("[push] server does not deliver APNs; skipping registration")
            case .denied:
                NSLog("[push] notification permission denied")
            case .failed(let message):
                NSLog("[push] could not enable: %@", message)
            }
        }
    }

    // A socket dies after a long background; the view model reconnects (and resumes from
    // `?since=`) when we come back, and stops trying while we're away. enterForeground
    // also reports presence, which is what stops the server pushing to a phone whose
    // owner is looking at it.
    func sceneDidBecomeActive(_ scene: UIScene) {
        viewModel.enterForeground()
        // Re-run on every activation, not just the first: iOS can rotate a device token,
        // and the user may have granted (or revoked) notifications in Settings while we
        // were away. Cheap — the token is re-issued identically and the server upserts.
        enablePushIfSignedIn()
    }

    /// Backgrounding reports presence, which is the frame that makes push work at all: the
    /// server suppresses every notification until it hears we've stopped looking.
    ///
    /// It's also the one frame we send while iOS is trying to suspend us, and a WebSocket
    /// write is asynchronous — enqueued here, drained by URLSession later. Suspended in
    /// between and the frame is simply lost, leaving the server convinced someone is
    /// watching until its ping reaper notices (~60s of no push, on the exact path push
    /// exists for). So buy runtime explicitly rather than assume the write wins the race:
    /// it usually does, which is what makes this fail as "push is sometimes late" instead
    /// of as a bug.
    func sceneDidEnterBackground(_ scene: UIScene) {
        var assertion: UIBackgroundTaskIdentifier = .invalid
        // The expiry handler runs if iOS reclaims the time before the write lands; ending
        // the assertion there is mandatory, or the OS kills the app for holding it.
        assertion = UIApplication.shared.beginBackgroundTask(withName: "lurker.presence") {
            guard assertion != .invalid else { return }
            UIApplication.shared.endBackgroundTask(assertion)
            assertion = .invalid
        }
        viewModel.enterBackground {
            // Arbitrary queue (URLSession's), and UIBackgroundTaskIdentifier is main-actor
            // state here — hop before touching it.
            Task { @MainActor in
                guard assertion != .invalid else { return }
                UIApplication.shared.endBackgroundTask(assertion)
                assertion = .invalid
            }
        }
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
    /// (See the `NotificationTapHandling` conformance below for the notification path.)
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

// MARK: - Notification taps (#15)

extension SceneDelegate: NotificationTapHandling {

    /// Open the buffer a tapped notification names. Same move as picking it in the
    /// switcher — swap the navigation root — so a tap lands in exactly the state a manual
    /// switch would, unread divider and history request included.
    func open(_ tap: NotificationTap) {
        guard let navigation, viewModel.session == .loggedIn else {
            // Tapped while signed out (a push that outlived the session). Park it: if the
            // user signs back in, `render` builds the stack and this is stale anyway, so
            // dropping it is the honest outcome — better than bouncing them somewhere
            // they didn't ask for.
            return
        }
        let key = BufferKey(networkId: tap.networkId, target: tap.target)
        // Look up by `key.id`, which lower-cases the target: IRC servers are inconsistent
        // about case and the notification's target came from whatever the server said at
        // send time. An exact-key match would miss `#Lurker` vs `#lurker`.
        //
        // Not in the store yet? Synthesize one. A push can beat its own backlog frame —
        // the notification is what woke us — and the new screen's `hydrateIfNeeded` asks
        // for the history regardless, so the buffer fills in a moment later.
        let buffer = viewModel.state.buffers[key.id]
            ?? Buffer(
                networkId: tap.networkId,
                target: tap.target,
                kind: BufferKind.of(networkId: tap.networkId, target: tap.target)
            )

        // Anything presented (the buffer switcher, the nick list) would otherwise sit over
        // the buffer we just navigated to.
        navigation.dismiss(animated: false)
        navigation.setViewControllers(
            [ChatViewController(viewModel: viewModel, buffer: buffer)], animated: false
        )
    }

    func registerPushToken(_ token: String) async {
        let ok = await viewModel.registerPushDevice(token: token)
        if !ok { NSLog("[push] server rejected this device token") }
    }
}
