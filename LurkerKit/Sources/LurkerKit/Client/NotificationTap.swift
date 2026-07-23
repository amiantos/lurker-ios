// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Where a tapped push notification points (#15).
///
/// Mirrors the custom keys the server puts BESIDE `aps` — Apple reserves `aps` itself, so
/// the routing keys ride at the top level of the payload. See the server's apnsSender.ts;
/// if these names drift apart, every notification tap silently lands on the wrong screen
/// with nothing failing.
public struct NotificationTap: Equatable, Sendable {
    public let networkId: Int
    public let target: String
    /// The message that triggered the push, when it names one — a message/highlight/DM push
    /// carries it (server stamps `messageId: decorated.id`), a friend-online push doesn't. Lets
    /// a tap land on that exact line (#42), not just the buffer bottom.
    public let messageId: Int?

    public init(networkId: Int, target: String, messageId: Int? = nil) {
        self.networkId = networkId
        self.target = target
        self.messageId = messageId
    }

    /// Read the routing keys off a push payload.
    ///
    /// Lives here rather than in the app delegate that receives it: it's pure logic over a
    /// dictionary, and the app target has no tests — so parked next to the delegate it
    /// would be the one piece of the push path nothing could check. `[AnyHashable: Any]` is
    /// Foundation, not UIKit, so LurkerKit can hold it without learning about the OS.
    ///
    /// `nil` for anything that doesn't name a buffer. A malformed payload should open the
    /// app on whatever screen it would have shown anyway — never crash, and never guess at
    /// a destination the user didn't ask for.
    public static func parse(_ userInfo: [AnyHashable: Any]) -> NotificationTap? {
        guard let networkId = intField(userInfo["networkId"]),
              let target = userInfo["target"] as? String,
              !target.isEmpty
        else { return nil }
        // `messageId` reads the same way — absent or unparseable → nil, and the tap simply opens
        // the buffer at its bottom rather than jumping.
        return NotificationTap(networkId: networkId, target: target, messageId: intField(userInfo["messageId"]))
    }

    /// An id field off a push payload, coping with either shape it can arrive in: APNs sends a
    /// JSON number (an NSNumber that `as? Int` bridges), FCM's data dictionary sends a string.
    /// The String arm is NOT redundant — the two payloads are one mistake apart, and routing is
    /// the wrong place to be strict about which of our own servers sent this.
    private static func intField(_ value: Any?) -> Int? {
        switch value {
        case let value as Int: value
        case let value as String: Int(value)
        default: nil
        }
    }
}
