// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// One nick's IRCv3 metadata as the server shows it (lurker#607, Mobile lurker#1203): the
/// `userMetadata` record in a network snapshot, and the `values` of a `user-metadata` event.
///
/// Every field is text another user controls. The rules for showing it are in
/// `ChatState.displayName(networkId:nick:)` and the plan; this type only carries it.
public struct UserMetadata: Equatable, Sendable {
    /// The `display-name` key, raw — mIRC codes and all. The head renders them; plain surfaces
    /// strip them (`UserMetadata.shown(_:)`).
    public let displayName: String?
    /// ⚠ Server-minted and opaque: the media proxy route or a CDN URL, never the origin the user
    /// set. Nil when the server can't serve one (previews off), which means "draw the generated
    /// tile" — the same as having no avatar at all, so null and absent collapse here on purpose.
    public let avatarUrl: String?
    public let pronouns: String?
    /// Already filtered to http(s) by the server (`ircMetadata.ts`), so a value here is a link.
    public let homepage: String?
    public let status: String?

    public init(
        displayName: String? = nil,
        avatarUrl: String? = nil,
        pronouns: String? = nil,
        homepage: String? = nil,
        status: String? = nil
    ) {
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.pronouns = pronouns
        self.homepage = homepage
        self.status = status
    }

    /// A record with nothing to show. The server sends `null` to forget a nick rather than an
    /// empty record, but a record that is all nulls is the same statement.
    public var isEmpty: Bool {
        displayName == nil && avatarUrl == nil && pronouns == nil && homepage == nil && status == nil
    }

    /// The display name as a plain surface prints it: mIRC codes stripped, whitespace trimmed,
    /// nil when nothing is left. A name that is all colour codes is not a name — the web's
    /// `useDisplayNames` applies the same test before it shows anything.
    public static func shown(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let plain = IRCFormatting.strip(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return plain.isEmpty ? nil : plain
    }
}

/// What a network said it can carry (`draft/metadata-2`'s cap values), from the snapshot's
/// `metadataLimits`. Nil on `Network` means the network has no metadata at all — an older
/// server, or one whose IRC server never advertised the cap. Edit Profile (lurker#1204) gates on
/// this; nothing in the display half reads it.
public struct MetadataLimits: Equatable, Sendable {
    public let maxSubs: Int?
    /// `max-keys`. ⚠ Zero is soju saying "I relay nothing" — present, but nothing can be set.
    public let maxKeys: Int?
    public let maxValueBytes: Int?
    public let beforeConnect: Bool

    public init(maxSubs: Int?, maxKeys: Int?, maxValueBytes: Int?, beforeConnect: Bool) {
        self.maxSubs = maxSubs
        self.maxKeys = maxKeys
        self.maxValueBytes = maxValueBytes
        self.beforeConnect = beforeConnect
    }
}

/// Every nick's metadata the server holds, per network (lurker#1203).
///
/// Keyed `networkId → folded nick → record`, the way the server keys its own map, and folded the
/// way the web's `toLowerCase()` folds (`NickColor.lowercasedLikeTheWeb`), so a snapshot key the
/// server lowered and a lookup this client lowers meet on a Greek nick too.
///
/// Immutable and only ever replaced — by the snapshot wholesale, by `user-metadata` one nick at
/// a time — so `===` is a valid test for "the metadata changed", which is what lets the chat
/// screen's `removeDuplicates` compare it with a pointer test on every frame. Same contract as
/// `RelayBotSet`.
///
/// A rename needs nothing here: the server sends the old nick's `null`, then the new nick's
/// record (CLIENT_PROTOCOL.md, `user-metadata`).
public final class UserMetadataSet: Sendable {
    private let byNetwork: [Int: [String: UserMetadata]]

    /// `byNetwork`'s nick keys are folded here, so a caller may pass them as the wire had them.
    public init(byNetwork: [Int: [String: UserMetadata]] = [:]) {
        self.byNetwork = byNetwork.reduce(into: [:]) { out, entry in
            var folded: [String: UserMetadata] = [:]
            for (nick, record) in entry.value where !nick.isEmpty {
                folded[Self.fold(nick)] = record
            }
            guard !folded.isEmpty else { return }
            out[entry.key] = folded
        }
    }

    /// An already-folded map, for the patch paths: the set holds a record for every nick the
    /// server knows across every network, and a join on a busy network arrives as one event per
    /// nick — re-folding every key on each would be quadratic across the burst.
    private init(folded: [Int: [String: UserMetadata]]) {
        byNetwork = folded
    }

    public static let empty = UserMetadataSet()

    static func fold(_ nick: String) -> String { NickColor.lowercasedLikeTheWeb(nick) }

    /// The record for `nick` on `networkId`, or nil. A nil network is the app-scoped system
    /// buffer, where nobody has metadata.
    public func record(networkId: Int?, nick: String?) -> UserMetadata? {
        guard let networkId, let nick, !nick.isEmpty else { return nil }
        return byNetwork[networkId]?[Self.fold(nick)]
    }

    /// This set with one nick's record replaced whole, or forgotten on nil — how a
    /// `user-metadata` event folds in.
    public func applying(networkId: Int, nick: String, values: UserMetadata?) -> UserMetadataSet {
        guard !nick.isEmpty else { return self }
        var next = byNetwork
        var bucket = next[networkId] ?? [:]
        if let values {
            bucket[Self.fold(nick)] = values
        } else {
            bucket.removeValue(forKey: Self.fold(nick))
        }
        next[networkId] = bucket.isEmpty ? nil : bucket
        return UserMetadataSet(folded: next)
    }

    /// This set without `networkId` — the network was deleted.
    public func removing(networkId: Int) -> UserMetadataSet {
        guard byNetwork[networkId] != nil else { return self }
        var next = byNetwork
        next[networkId] = nil
        return UserMetadataSet(folded: next)
    }

    /// How many nicks have a record on `networkId` — for tests and `/metadata list`-style
    /// inventories, not the hot path.
    public func count(networkId: Int) -> Int { byNetwork[networkId]?.count ?? 0 }
}
