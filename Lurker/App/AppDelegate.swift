// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit
import UserNotifications

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    /// Where a notification tap wants to go, when it arrives before there's anything to
    /// navigate with. A cold launch from a notification runs this delegate's callback
    /// before the scene has a window, so the tap is parked here and the scene drains it
    /// once it's built. Without this the first tap after a cold launch silently lands on
    /// the default buffer, which reads as the notification being ignored.
    static var pendingTap: NotificationTap?

    /// Set by the scene once it can navigate. Taps that arrive while the app is already
    /// running go straight here.
    static weak var tapHandler: NotificationTapHandling?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Must be set before launch finishes, per UNUserNotificationCenter — otherwise a
        // cold launch from a tap never calls back at all.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    // MARK: - APNs registration

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let hex = PushRegistrar.hexToken(from: deviceToken)
        Task { @MainActor in
            await Self.tapHandler?.registerPushToken(hex)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Not fatal, and not worth a dialog: the app works without push. This is almost
        // always a provisioning problem (no aps-environment entitlement, no APNs
        // capability) — a build-time mistake, not something the user can act on.
        NSLog("[push] APNs registration failed: %@", error.localizedDescription)
    }
}

@MainActor
protocol NotificationTapHandling: AnyObject {
    func open(_ tap: NotificationTap)
    func registerPushToken(_ token: String) async
}

extension AppDelegate: UNUserNotificationCenterDelegate {

    /// A notification arriving while the app is FOREGROUND. The server gates on presence
    /// and shouldn't be sending one — but "shouldn't" isn't "can't": there's a real gap
    /// between backgrounding and the server hearing about it, so a stale push can land
    /// just as the user comes back. Suppressing the banner is the belt to the server's
    /// braces. The badge still updates, since that number is still true.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard let tap = NotificationTap.parse(response.notification.request.content.userInfo) else {
            return
        }
        if let handler = Self.tapHandler {
            handler.open(tap)
        } else {
            // Cold launch: nothing can navigate yet. The scene drains this when it's ready.
            Self.pendingTap = tap
        }
    }
}
