// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// A relayed push, decrypted and ready to show (RELAY_PLAN.md §6.2).
///
/// The plaintext is the server's `pushBody()`: the same title, body and tag a direct APNs
/// push puts in `aps`, plus the routing keys it puts beside it. This rebuilds exactly that,
/// so a relayed notification reads the same and taps through the same `NotificationTap`
/// path as a hosted one.
public struct RelayNotification: Sendable, Equatable {
    public let title: String
    public let body: String
    /// The server's collapse tag: the thread a direct push groups by (`aps.thread-id`), and
    /// the key the extension replaces an earlier notification by (`apns-collapse-id`).
    public let tag: String
    public let badge: Int?
    public let networkId: Int
    public let target: String
    public let messageId: Int?
    public let bufferId: Int?
    public let kind: String?

    /// `userInfo` for the notification: the routing keys a direct push carries beside
    /// `aps`, so `NotificationTap.parse` reads it unchanged, plus the tag for collapsing.
    public var userInfo: [String: Any] {
        var info: [String: Any] = ["networkId": networkId, "target": target, "tag": tag]
        if let messageId { info["messageId"] = messageId }
        if let bufferId { info["bufferId"] = bufferId }
        if let kind { info["kind"] = kind }
        return info
    }

    /// nil for anything that isn't a push we can show — the extension then leaves the
    /// relay's placeholder alone rather than painting a half-built notification.
    public static func parse(_ plaintext: Data) -> RelayNotification? {
        guard let body = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
              let title = body["title"] as? String, !title.isEmpty,
              let tag = body["tag"] as? String, !tag.isEmpty,
              let networkId = intField(body["networkId"]),
              let target = body["target"] as? String, !target.isEmpty
        else { return nil }
        return RelayNotification(
            title: title,
            body: body["body"] as? String ?? "",
            tag: tag,
            badge: intField(body["badge"]),
            networkId: networkId,
            target: target,
            messageId: intField(body["messageId"]),
            bufferId: intField(body["bufferId"]),
            kind: body["kind"] as? String
        )
    }

    /// JSON numbers arrive as NSNumber; a Bool is one too, and isn't an id.
    private static func intField(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }
}
