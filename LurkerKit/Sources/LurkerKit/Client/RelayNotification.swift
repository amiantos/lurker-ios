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
    /// The largest body a relay can carry: the whole APNs payload is 4 KB, so anything bigger
    /// didn't come from a server, and isn't worth handing to the JSON parser.
    static let maxPlaintextBytes = 4096

    public static func parse(_ plaintext: Data) -> RelayNotification? {
        // Only top-level scalars are read, and Foundation's parser refuses nesting past its
        // depth limit with an error rather than a crash — with the size cap, a hostile but
        // authenticated body can cost the extension no more than a few KB of parsing.
        guard plaintext.count <= maxPlaintextBytes,
              let body = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
              let title = body["title"] as? String, !title.isEmpty,
              let tag = body["tag"] as? String, !tag.isEmpty,
              let networkId = NotificationTap.intField(body["networkId"]),
              let target = body["target"] as? String, !target.isEmpty
        else { return nil }
        return RelayNotification(
            title: title,
            body: body["body"] as? String ?? "",
            tag: tag,
            badge: NotificationTap.intField(body["badge"]),
            networkId: networkId,
            target: target,
            messageId: NotificationTap.intField(body["messageId"]),
            bufferId: NotificationTap.intField(body["bufferId"]),
            kind: body["kind"] as? String
        )
    }

    /// A notification already showing, as far as collapsing cares.
    public struct Delivered: Sendable, Equatable {
        public let identifier: String
        public let threadIdentifier: String
        public let tag: String?

        public init(identifier: String, threadIdentifier: String, tag: String?) {
            self.identifier = identifier
            self.threadIdentifier = threadIdentifier
            self.tag = tag
        }
    }

    /// Which delivered notifications this one replaces, mirroring `apns-collapse-id` = tag: any
    /// with the same thread (a direct push sets `aps.thread-id` to the tag; the extension sets
    /// `threadIdentifier` to it) or carrying the tag in its userInfo.
    public static func collapsing(_ delivered: [Delivered], tag: String) -> [String] {
        delivered.filter { $0.threadIdentifier == tag || $0.tag == tag }.map(\.identifier)
    }
}
