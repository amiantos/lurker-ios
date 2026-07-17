// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import UIKit
import UserNotifications

/// Owns this device's relationship with APNs: asking permission, registering with Apple,
/// and handing the resulting token to the server (#15, server side #490).
///
/// Lives in the app rather than LurkerKit for the same reason `ReachabilityMonitor` does —
/// it observes the device and feeds facts in. `UNUserNotificationCenter` and
/// `UIApplication` are UIKit, and LurkerKit deliberately knows nothing about either; it
/// takes a `String` token and a `Bool`, and that's the whole surface.
///
/// The order below is deliberate and is the point of the class:
///
///   1. ask the SERVER whether it can deliver APNs at all,
///   2. only then ask the USER for permission,
///   3. only then register with Apple.
///
/// Backwards, and a self-hoster's user gets a permission prompt for notifications their
/// server can never send — a grant spent on nothing, and one iOS won't offer again.
@MainActor
final class PushRegistrar {

    enum Outcome: Equatable {
        /// Registered with Apple; the token is on its way to `didRegister`.
        case registering
        /// The server can't deliver APNs (self-hosted, or older than #490).
        case unsupportedByServer
        /// The user said no, or had already said no.
        case denied
        /// Asking Apple failed. Rare, and usually a provisioning problem.
        case failed(String)
    }

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    /// Run the sequence. Safe to call on every foreground: iOS re-issues the same token,
    /// the server upserts, and an already-granted authorization doesn't re-prompt.
    func enable(serverSupportsAPNs: @Sendable () async -> Bool) async -> Outcome {
        guard await serverSupportsAPNs() else { return .unsupportedByServer }

        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .denied:
            // Already refused. iOS will not re-prompt, so re-asking is a no-op and the
            // honest thing is to say so — Settings is the only way back.
            return .denied
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                guard granted else { return .denied }
            } catch {
                return .failed(error.localizedDescription)
            }
        default:
            break // authorized / provisional / ephemeral — carry on
        }

        // Registering is what actually produces a device token; the authorization above
        // only governs whether iOS will DISPLAY what arrives. They're separate, and both
        // are required.
        UIApplication.shared.registerForRemoteNotifications()
        return .registering
    }

    /// APNs device tokens are raw bytes; the server wants the hex string, which is what
    /// Apple's own tooling and every push service means by "device token".
    static func hexToken(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
