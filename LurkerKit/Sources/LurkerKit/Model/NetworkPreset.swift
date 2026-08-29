// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// A network the add-network flow can offer to set up for you: one of the bundled catalogue,
/// or one this instance's admin defined (#298).
///
/// Deliberately one shape for both, so the picker merges them into a single list instead of
/// branching per row — the same call the web makes.
public struct NetworkPreset: Equatable, Sendable {
    public let name: String
    public let host: String
    public let port: Int
    public let tls: Bool
    /// True when a client connecting from a datacenter IP likely needs SASL — Libera and
    /// friends refuse unauthenticated cloud addresses. Advisory: it changes what the form
    /// says, never what it sends.
    public let saslLikelyRequired: Bool
    /// The network's own documented main channel, where we can name one. Absent is the honest
    /// and common case: a wrong name lands a new user in a channel that doesn't exist, which
    /// is worse than landing them nowhere.
    public let defaultChannel: String?
    /// An admin's recommended channels, on instance presets only. Plural, unlike a builtin's
    /// single `defaultChannel`: an admin knows their own network and can reasonably say "join
    /// #general and #random"; for a public network we only ever claim to know its one channel.
    public let recommendedChannels: [String]
    public let tags: [String]
    /// True for an admin-defined preset. They pin above the builtins and carry a badge.
    public let isInstance: Bool
    /// The `instance_network` row id, on instance presets only — a genuinely unique key for a
    /// list, since nothing stops an admin listing the same host twice (two ports, or a TLS
    /// and a plaintext entry).
    public let instanceID: Int?

    public init(
        name: String,
        host: String,
        port: Int,
        tls: Bool,
        saslLikelyRequired: Bool = false,
        defaultChannel: String? = nil,
        recommendedChannels: [String] = [],
        tags: [String] = [],
        isInstance: Bool = false,
        instanceID: Int? = nil
    ) {
        self.name = name
        self.host = host
        self.port = port
        self.tls = tls
        self.saslLikelyRequired = saslLikelyRequired
        self.defaultChannel = defaultChannel
        self.recommendedChannels = recommendedChannels
        self.tags = tags
        self.isInstance = isInstance
        self.instanceID = instanceID
    }

    /// The channels we can actually stand behind for this network, in the order to offer them.
    ///
    /// For an instance preset it's whatever the admin listed — they run the place, so their
    /// word is the last word, and we don't second-guess it with #lurker. For a builtin it's
    /// #lurker where there's an active one, then the network's own documented channel.
    /// #lurker leads because a new user is better served by the room where they can get help
    /// with the client than by a network's general chat.
    public var suggestedChannels: [String] {
        if isInstance { return recommendedChannels }
        var channels: [String] = []
        if tags.contains(BuiltinNetworks.lurkerTag) { channels.append(BuiltinNetworks.lurkerChannel) }
        if let own = defaultChannel,
           !channels.contains(where: { $0.caseInsensitiveCompare(own) == .orderedSame }) {
            channels.append(own)
        }
        return channels
    }

    /// A draft prefilled from this preset — the whole point of the picker. Everything the
    /// preset knows is filled in; the nick is what's left for the user.
    ///
    /// The channel list is seeded rather than left blank so a new user lands in a
    /// conversation instead of an empty server log, which is the difference between the app
    /// working and the app looking broken on first run. It's a prefilled, editable field, not
    /// a silent join: where we know nothing, `#chat` is offered as the guess it is.
    public func draft() -> NetworkDraft {
        var draft = NetworkDraft(name: name, host: host, port: port, tls: tls)
        let channels = suggestedChannels
        draft.defaultChannel = channels.isEmpty
            ? BuiltinNetworks.fallbackChannel
            : channels.joined(separator: ", ")
        return draft
    }
}

/// The bundled catalogue, and the two channel names the flow leans on.
///
/// ⚠ The JSON is a **copy** of `vue_client/src/utils/builtinNetworks.json` in the lurker
/// repo, where it is hand-maintained (seeded from the netsplit.de top 100, connection details
/// verified per network). It will drift, and that's accepted: the alternative is an endpoint
/// shipping 24 KB the client could have had in its bundle. If you're updating one, update
/// both.
public enum BuiltinNetworks {
    /// Networks carrying this tag have an active #lurker channel. A marker, not a browse
    /// category — it floats a network to the top and picks its default channel.
    public static let lurkerTag = "lurker"
    public static let lurkerChannel = "#lurker"
    /// Where we know nothing about a network, this is the guess. It stays a *guess*: it is
    /// only ever prefilled into a field the user reviews before connecting, never joined on
    /// their behalf.
    public static let fallbackChannel = "#chat"

    /// The catalogue, #lurker-friendly networks first and most-popular-first within each
    /// group — so the picker's default order is meaningful before anyone types.
    public static let all: [NetworkPreset] = load()

    private static func load() -> [NetworkPreset] {
        guard let url = Bundle.module.url(forResource: "builtinNetworks", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return rows
            .map { row in
                (
                    preset: NetworkPreset(
                        name: row.string("name"),
                        host: row.string("host"),
                        port: row.int("port", 6697),
                        tls: row.bool("tls", true),
                        saslLikelyRequired: row.bool("saslLikelyRequired"),
                        defaultChannel: row.stringOrNull("defaultChannel"),
                        tags: (row["tags"] as? [String]) ?? []
                    ),
                    users: row.intOrNull("users")
                )
            }
            .sorted { left, right in
                let leftLurker = left.preset.tags.contains(lurkerTag)
                let rightLurker = right.preset.tags.contains(lurkerTag)
                if leftLurker != rightLurker { return leftLurker }
                return (left.users ?? -1) > (right.users ?? -1)
            }
            .map(\.preset)
    }
}

/// What `GET /api/network-presets` says: the networks this instance recommends, and whether
/// users may connect to anything else.
public struct NetworkPresets: Equatable, Sendable {
    public let instance: [NetworkPreset]
    /// ⚠ Permissive by default. An un-fetched or older server must not present itself as a
    /// locked-down instance and hide the custom-server path — that would be an app that
    /// can't add a network at all, which is the failure this whole issue is about.
    public let allowUserDefined: Bool

    public init(instance: [NetworkPreset], allowUserDefined: Bool = true) {
        self.instance = instance
        self.allowUserDefined = allowUserDefined
    }

    /// Instance presets first — the admin's own networks are the ones their users came for —
    /// then the catalogue, minus any host the admin already lists, so a locked-down instance
    /// doesn't offer the same server twice under two names.
    public var offered: [NetworkPreset] {
        // ⚠⚠ A locked-down instance offers its own networks and NOTHING else. The policy is
        // an allowlist of hosts (`networkPolicy.hostAllowedChecker`): with
        // `allowUserDefined` off, the enabled instance presets are the entire allowed set,
        // so every builtin here would be a row whose only outcome is a 403 — the same
        // mistake as offering Connect on a blocked network, one screen earlier.
        guard allowUserDefined else { return instance }
        let claimed = Set(instance.map { $0.host.lowercased() })
        return instance + BuiltinNetworks.all.filter { !claimed.contains($0.host.lowercased()) }
    }
}
