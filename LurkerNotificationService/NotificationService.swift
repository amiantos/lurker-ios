// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation
import LurkerKit
import UserNotifications

/// Turns a push relayed by push.lurker.chat into the notification a hosted server's direct
/// APNs push would have shown (lurker-dev/RELAY_PLAN.md §6.2).
///
/// The relay can't read what it forwards: it arrives as the server's encrypted Web Push body
/// in `p`, under a placeholder alert ("New message") with `mutable-content`, which is what
/// routes it through here. This decrypts `p` with the keys the app registered — kept in the
/// Keychain group both targets share — and rebuilds the title, body, thread, badge and tap
/// keys from it. Anything that goes wrong leaves the placeholder: a push before the first
/// unlock after a reboot (the keys aren't readable yet), keys rotated since, a body we
/// can't parse. Direct APNs pushes carry no `p` and pass through untouched.
final class NotificationService: UNNotificationServiceExtension {
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    /// What to show if time runs out: the relay's placeholder until decryption succeeds,
    /// then the decrypted notification — collapsing is a nicety, not worth losing it over.
    private var bestAttempt: UNNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        lock.withLock {
            self.contentHandler = contentHandler
            self.bestAttempt = request.content
        }
        guard let p = request.content.userInfo["p"] as? String,
              let body = WebPushCrypto.base64URLDecode(p),
              let keys = KeychainWebPushKeyStore.forMainBundle()?.load(),
              let plaintext = try? WebPushCrypto.decrypt(body, keys: keys),
              let notification = RelayNotification.parse(plaintext),
              let content = request.content.mutableCopy() as? UNMutableNotificationContent
        else {
            deliver(request.content)
            return
        }
        content.title = notification.title
        content.body = notification.body
        content.threadIdentifier = notification.tag
        if let badge = notification.badge { content.badge = NSNumber(value: badge) }
        // Replaces the relay's {aps, p}: the tap path reads the same keys a direct push
        // carries, and the ciphertext has no business lingering in the notification center.
        content.userInfo = notification.userInfo
        lock.withLock { bestAttempt = content }

        // A direct push collapses by `apns-collapse-id` = tag, so a buffer shows one
        // notification, its latest. The relay can't set that — the tag is encrypted — so do
        // it here: drop what's already showing for this tag before this one lands.
        let center = UNUserNotificationCenter.current()
        let tag = notification.tag
        center.getDeliveredNotifications { [weak self] delivered in
            let stale = RelayNotification.collapsing(
                delivered.map {
                    RelayNotification.Delivered(
                        identifier: $0.request.identifier,
                        threadIdentifier: $0.request.content.threadIdentifier,
                        tag: $0.request.content.userInfo["tag"] as? String
                    )
                },
                tag: tag
            )
            if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
            self?.deliver(content)
        }
    }

    /// Out of time (about 30 seconds): show the best we have rather than nothing.
    override func serviceExtensionTimeWillExpire() {
        let best = lock.withLock { self.bestAttempt }
        if let best { deliver(best) }
    }

    /// Exactly once: the timeout and the collapse callback can race.
    private func deliver(_ content: UNNotificationContent) {
        let handler = lock.withLock { () -> ((UNNotificationContent) -> Void)? in
            defer { contentHandler = nil }
            return contentHandler
        }
        handler?(content)
    }
}
