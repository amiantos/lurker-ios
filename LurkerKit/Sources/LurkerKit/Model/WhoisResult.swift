// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// One WHOIS reply (#12) — the `whois` payload of a `whois_result` frame.
///
/// The server does not parse the numerics itself: irc-framework aggregates RPL_WHOIS*
/// (311/312/317/319/330/…) into a single `whois` event at RPL_ENDOFWHOIS, and
/// `ircConnection.ts` fans that object out verbatim. So the field names here are
/// irc-framework's spellings, not Lurker's, and this type is the only place that
/// should know them.
///
/// The server buffer separately gets the *raw* numerics through the default-show `raw`
/// handler (#281, #342). That is a different rendering of the same reply, not a fallback
/// for this one — both happen, always.
public struct WhoisResult: Equatable, Sendable {
    /// The nick as the server spelled it. Present on every reply including a miss, because
    /// RPL_ENDOFWHOIS carries it (`user.js:152`) — which is what makes a miss addressable.
    public let nick: String
    public let ident: String?
    public let hostname: String?
    public let realName: String?
    /// Where they are actually connected from, when the server tells opers/self (RPL_WHOISACTUALLY).
    public let actualHostname: String?
    public let actualIP: String?
    public let server: String?
    public let serverInfo: String?
    /// Services account (RPL_WHOISACCOUNT). Distinct from `registeredNick`, which is only a
    /// claim that the nick is registered.
    public let account: String?
    /// ⚠ The RPL_WHOISCHANNELS payload is **one space-separated string** of prefix+name
    /// tokens — `"@#foo +#bar #baz"` — accumulated across repeats (`user.js:222`). Not an
    /// array. Read it through `channels`, which does the splitting.
    public let channelsLine: String?
    /// User modes, when the server discloses them (RPL_WHOISMODES). A raw mode string.
    public let modes: String?
    /// The trailing text of the numeric that asserts each of these, so a set flag is a
    /// non-empty string rather than a bool. Kept as text because the wording is the server's
    /// ("is an IRC Operator", "is a Network Service") and is worth showing.
    public let isOperator: String?
    public let helpop: String?
    public let bot: String?
    public let registeredNick: String?
    /// RPL_WHOISSECURE. The one genuinely boolean flag irc-framework sets (`user.js:269`).
    public let isSecure: Bool
    public let certfp: String?
    /// The away reason, present only when the whois ran while they were away. `peerPresence`
    /// is the fresher source for the same fact — prefer it and fall back here.
    public let away: String?
    /// Idle seconds (RPL_WHOISIDLE).
    public let idleSeconds: Int?
    /// Signon time.
    public let signedOn: Date?
    /// `"not_found"` when the nick isn't on the network — read through `isNotFound`.
    public let error: String?

    public init(
        nick: String,
        ident: String? = nil,
        hostname: String? = nil,
        realName: String? = nil,
        actualHostname: String? = nil,
        actualIP: String? = nil,
        server: String? = nil,
        serverInfo: String? = nil,
        account: String? = nil,
        channelsLine: String? = nil,
        modes: String? = nil,
        isOperator: String? = nil,
        helpop: String? = nil,
        bot: String? = nil,
        registeredNick: String? = nil,
        isSecure: Bool = false,
        certfp: String? = nil,
        away: String? = nil,
        idleSeconds: Int? = nil,
        signedOn: Date? = nil,
        error: String? = nil
    ) {
        self.nick = nick
        self.ident = ident
        self.hostname = hostname
        self.realName = realName
        self.actualHostname = actualHostname
        self.actualIP = actualIP
        self.server = server
        self.serverInfo = serverInfo
        self.account = account
        self.channelsLine = channelsLine
        self.modes = modes
        self.isOperator = isOperator
        self.helpop = helpop
        self.bot = bot
        self.registeredNick = registeredNick
        self.isSecure = isSecure
        self.certfp = certfp
        self.away = away
        self.idleSeconds = idleSeconds
        self.signedOn = signedOn
        self.error = error
    }

    /// The nick isn't on the network.
    ///
    /// ⚠⚠ This does **not** come from ERR_NOSUCHNICK. That numeric reaches only
    /// irc-framework's generic error handler and produces no `whois` event at all; the miss
    /// is *synthesized* at RPL_ENDOFWHOIS when nothing filled the cache (`user.js:151`).
    ///
    /// The corollary is worth knowing before trusting silence: a server that answers 401 and
    /// then sends no 318 produces no signal whatsoever, and a screen waiting on one waits
    /// forever. There is no timeout here (the web has none either).
    public var isNotFound: Bool { error == "not_found" }

    /// `nick!ident@host`, the form an ignore rule's mask is matched against.
    ///
    /// A missing half becomes `*` rather than making the whole thing nil — unlike
    /// `Member.userhost`, which is fed straight to the matcher and where a half-mask would
    /// silently fail a rule. This one is for *display*, where "we know the host but not the
    /// ident" is worth showing.
    public var hostmask: String? {
        guard ident != nil || hostname != nil else { return nil }
        return "\(nick)!\(ident ?? "*")@\(hostname ?? "*")"
    }

    /// One channel from the RPL_WHOISCHANNELS line: the sigils they hold there, and the
    /// name without them.
    public struct ChannelEntry: Equatable, Sendable {
        /// The membership sigils (`~ & @ % +`), as sent — possibly several, possibly none.
        public let prefix: String
        public let name: String

        public init(prefix: String, name: String) {
            self.prefix = prefix
            self.name = name
        }
    }

    /// The channels they're in, split out of `channelsLine`.
    ///
    /// The membership sigils are peeled off so `name` is joinable as-is — see
    /// `MemberPrefix.splitChannelToken` for why that peel can't be greedy.
    public var channels: [ChannelEntry] {
        guard let channelsLine else { return [] }
        return channelsLine.split(whereSeparator: \.isWhitespace).compactMap { token in
            // Nil for a token that is only sigils — it names no channel, and a conforming
            // server can't send one, but it would otherwise be a row that is tappable and empty.
            guard let split = MemberPrefix.splitChannelToken(String(token)) else { return nil }
            return ChannelEntry(prefix: split.prefix, name: split.name)
        }
    }
}
