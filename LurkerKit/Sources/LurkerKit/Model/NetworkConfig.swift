// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// One row of `GET /api/networks` — the network as it is *configured*, which is a different
/// object from the network as it is *rendered* (`Network`).
///
/// ⚠⚠ Deliberately not merged into `Network`. That one is the roster the store holds: id,
/// name, connection state, nick, away — read on the hot path of every frame the reducer
/// touches, and kept small for that reason. This one is a form's backing model, fetched when
/// someone opens the networks screen and thrown away when they leave. Folding them together
/// would put hostnames and credential flags in the message path, and would make the frame
/// reducer responsible for fields no frame carries.
///
/// The `channels` array the endpoint also returns is not modelled: nothing in #11 reads it
/// (the form edits autojoin channels only at create time, via `default_channel`). Add it when
/// something needs it rather than parsing a list to drop it.
public struct NetworkConfig: Equatable, Sendable, Identifiable {
    public let id: Int
    public var name: String
    public var host: String
    public var port: Int
    public var tls: Bool
    /// Whether the TLS certificate has to be a valid, trusted one.
    ///
    /// ⚠⚠ It reads like a permission to accept anything and it is the opposite: the server
    /// passes it straight to `rejectUnauthorized` (`ircConnection.ts:4040`, and the column
    /// defaults to 1), so **true means verify**. Turning it off is what lets a self-signed
    /// certificate through. The default therefore has to be true — a draft that defaulted it
    /// false would silently disable certificate verification on every network created from
    /// this app, which is a security decision no default gets to make on the user's behalf.
    public var trustedCertificates: Bool
    public var nick: String
    public var username: String?
    public var realname: String?
    public var autoconnect: Bool
    public var saslAccount: String?
    /// Raw lines sent after registration, newline-separated, as the server stores them.
    public var connectCommands: String?
    /// Whether a server password is *set*. The password itself is never returned — see
    /// `SecretEdit` for what that costs a form that wants to edit it.
    public var hasPassword: Bool
    /// Whether a SASL password is set. Same rules as `hasPassword`.
    public var hasSaslPassword: Bool
    /// True when the instance admin's allowlist excludes this network's host (#298).
    ///
    /// The row survives untouched — it just can't connect — so this is the difference
    /// between a Connect button that fails with a reason and one that appears to do nothing.
    /// The server refuses the connect itself; this only lets the client say why first.
    public var blocked: Bool

    public init(
        id: Int,
        name: String,
        host: String,
        port: Int,
        tls: Bool,
        // True = verify, matching the column's own default. See the property's note.
        trustedCertificates: Bool = true,
        nick: String,
        username: String? = nil,
        realname: String? = nil,
        autoconnect: Bool = false,
        saslAccount: String? = nil,
        connectCommands: String? = nil,
        hasPassword: Bool = false,
        hasSaslPassword: Bool = false,
        blocked: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.tls = tls
        self.trustedCertificates = trustedCertificates
        self.nick = nick
        self.username = username
        self.realname = realname
        self.autoconnect = autoconnect
        self.saslAccount = saslAccount
        self.connectCommands = connectCommands
        self.hasPassword = hasPassword
        self.hasSaslPassword = hasSaslPassword
        self.blocked = blocked
    }
}

/// What a form is asking to happen to one stored secret.
///
/// ⚠⚠ Passwords are never returned by the API — a row carries `has_password`, not the
/// password. So an empty text field is ambiguous in exactly the way that matters: it is both
/// what "leave the existing password alone" looks like and what "remove the password" looks
/// like. A form that sent the field's contents on every save would silently clear a password
/// the user never touched.
///
/// Three states, so the ambiguity can't exist: `unchanged` omits the key from the body
/// entirely (the server patches only what it's given), `set` sends the new value, and
/// `cleared` sends null. The UI owes the user a visible way to reach `cleared` — an empty
/// field is not it.
public enum SecretEdit: Equatable, Sendable {
    case unchanged
    case set(String)
    case cleared
}

/// The body of a create or update. Every non-secret field is always sent: the form shows all
/// of them, so "what's on screen" and "what's stored" are the same set, and a partial PATCH
/// would only reintroduce the question of which fields the form is authoritative for.
///
/// `defaultChannel` is create-only, matching the server: it seeds autojoin rows rather than
/// updating a column, and there is nothing for it to mean on an edit.
public struct NetworkDraft: Equatable, Sendable {
    public var name: String
    public var host: String
    public var port: Int
    public var tls: Bool
    public var trustedCertificates: Bool
    public var nick: String
    public var username: String?
    public var realname: String?
    public var autoconnect: Bool
    public var saslAccount: String?
    public var connectCommands: String?
    public var password: SecretEdit
    public var saslPassword: SecretEdit
    /// Comma- or whitespace-separated channel list, create only. The server accepts both
    /// separators (`parseChannelList`), matching IRC's own `JOIN #a,#b` syntax.
    public var defaultChannel: String?

    public init(
        name: String = "",
        host: String = "",
        port: Int = 6697,
        tls: Bool = true,
        // ⚠⚠ True = verify the certificate. See `NetworkConfig.trustedCertificates`: this
        // reads like the permissive option and is the strict one, and the server's own
        // default for a new network is the same. Matches the web's add form.
        trustedCertificates: Bool = true,
        nick: String = "",
        username: String? = nil,
        realname: String? = nil,
        autoconnect: Bool = true,
        saslAccount: String? = nil,
        connectCommands: String? = nil,
        password: SecretEdit = .unchanged,
        saslPassword: SecretEdit = .unchanged,
        defaultChannel: String? = nil
    ) {
        self.name = name
        self.host = host
        self.port = port
        self.tls = tls
        self.trustedCertificates = trustedCertificates
        self.nick = nick
        self.username = username
        self.realname = realname
        self.autoconnect = autoconnect
        self.saslAccount = saslAccount
        self.connectCommands = connectCommands
        self.password = password
        self.saslPassword = saslPassword
        self.defaultChannel = defaultChannel
    }

    /// A draft pre-filled from a stored row, for the edit form. Both secrets start
    /// `unchanged` — the values were never sent to us, so anything else would be a guess.
    public init(editing config: NetworkConfig) {
        self.init(
            name: config.name,
            host: config.host,
            port: config.port,
            tls: config.tls,
            trustedCertificates: config.trustedCertificates,
            nick: config.nick,
            username: config.username,
            realname: config.realname,
            autoconnect: config.autoconnect,
            saslAccount: config.saslAccount,
            connectCommands: config.connectCommands
        )
    }

    /// Why this draft can't be sent, or nil when it can.
    ///
    /// ⚠⚠ Enforced here, not only in the form. `POST` is validated server-side — 400 on a
    /// missing name, host or nick — but `PATCH` is **not**: it sets whatever keys it is
    /// given. So an edit that blanks the name stores an empty one, and the roster then reads
    /// it back as no name at all — which is #136's "we haven't heard the name" state, so the
    /// network renders as "Unnamed network" and re-triggers the roster read for good. This
    /// layer is the only guard both paths share, and a gate you have to remember to apply
    /// isn't one.
    public var validationError: String? {
        if Self.trimmed(name).isEmpty { return "Give this network a name." }
        if Self.trimmed(host).isEmpty { return "A server address is required." }
        if Self.trimmed(nick).isEmpty { return "A nickname is required." }
        if !(1...65535).contains(port) { return "Port must be between 1 and 65535." }
        return nil
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The JSON body for `POST /api/networks` or `PATCH /api/networks/:id`.
    ///
    /// `includeDefaultChannel` is false on an edit, where the key has no meaning. Secrets
    /// appear only when the user actually decided something about them: `unchanged` omits
    /// the key, `cleared` sends an explicit null (which is what the column stores for "no
    /// password", so null is a value here and not an absence).
    public func jsonBody(includeDefaultChannel: Bool) -> [String: Any] {
        // Trimmed on the way out, so a name that is only spaces can't slip past a check that
        // read it untrimmed — and so a host with a stray trailing space isn't a host nothing
        // resolves.
        var body: [String: Any] = [
            "name": Self.trimmed(name),
            "host": Self.trimmed(host),
            "port": port,
            "tls": tls,
            "trusted_certificates": trustedCertificates,
            "nick": Self.trimmed(nick),
            "autoconnect": autoconnect,
        ]
        // Optional text fields send null rather than "" when empty: the column is nullable and
        // the server's own defaults (username from nick, realname from nick) key off null, so
        // an empty string would store a real, empty value and defeat them.
        body["username"] = username?.isEmpty == false ? username! : NSNull()
        body["realname"] = realname?.isEmpty == false ? realname! : NSNull()
        body["sasl_account"] = saslAccount?.isEmpty == false ? saslAccount! : NSNull()
        body["connect_commands"] = connectCommands?.isEmpty == false ? connectCommands! : NSNull()
        Self.apply(password, to: "server_password", in: &body)
        Self.apply(saslPassword, to: "sasl_password", in: &body)
        if includeDefaultChannel, let defaultChannel, !defaultChannel.isEmpty {
            body["default_channel"] = defaultChannel
        }
        return body
    }

    private static func apply(_ edit: SecretEdit, to key: String, in body: inout [String: Any]) {
        switch edit {
        case .unchanged: break
        case .set(let value): body[key] = value
        case .cleared: body[key] = NSNull()
        }
    }
}

/// The outcome of creating or updating a network.
///
/// The saved row comes back rather than just a success flag: the server fills in what the
/// draft left out (an omitted username defaults from the nick) and normalizes what it was
/// given, so the row it returns is the one the screen should show. Re-listing to find that
/// out would be a round trip for something the reply already carried.
public enum NetworkSaveResult: Equatable, Sendable {
    case saved(NetworkConfig)
    /// The write landed but its reply couldn't be read.
    ///
    /// ⚠ Its own case rather than a `failure` with careful wording, because the distinction
    /// is one the caller has to *act* on, not report: a form that treats this as a refusal
    /// keeps itself open with Save re-enabled, and the next tap creates the network a second
    /// time. Prose in a message string cannot stop that. Dismiss on this, the way you would
    /// on `saved`; the roster has already been re-read, so the network is there to see.
    case savedWithoutDetail
    /// The server's own wording wherever it gave any — a blocked host, a missing field, a
    /// paused account — because it knows why it refused and this client is guessing.
    case failure(message: String)
}
