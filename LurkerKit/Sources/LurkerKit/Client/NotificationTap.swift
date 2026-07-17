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

    public init(networkId: Int, target: String) {
        self.networkId = networkId
        self.target = target
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
        // APNs sends networkId as a JSON number, which arrives as NSNumber — but `as? Int`
        // bridges that, so no NSNumber arm is needed here (verified; an explicit one is
        // dead code).
        //
        // The String arm is NOT redundant: FCM's data dictionary is all-strings, and the
        // two payload shapes are one mistake apart. Routing is the wrong place to be
        // strict about which of our own servers sent this.
        let networkId: Int? = switch userInfo["networkId"] {
        case let value as Int: value
        case let value as String: Int(value)
        default: nil
        }
        guard let networkId,
              let target = userInfo["target"] as? String,
              !target.isEmpty
        else { return nil }
        return NotificationTap(networkId: networkId, target: target)
    }
}
