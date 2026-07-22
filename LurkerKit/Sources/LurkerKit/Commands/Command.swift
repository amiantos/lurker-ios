// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The slash-command surface, ported from the web client's `handleCommand` dispatcher
/// (`vue_client/src/components/MessageInput.vue`). The two clients speak the same wire, so a
/// command has to translate to the same verbs on both — `/me` is an `action`, `/join` is a
/// `join`, `/nick` is a `raw NICK`, and anything unrecognized falls through to `raw` exactly
/// as the web does. The parsing is pure and lives here (not in the composer) so the whole
/// vocabulary is unit-testable without a UI.
///
/// What the app deliberately does NOT carry, and why:
///  - `/set` `/get` — web-only settings console; iOS settings are a native screen (#20).
///  - `/network` `/net` — network CRUD is REST-heavy and owns its own issue (#11).
///  - `/ignore` `/highlight` and friends — rule *management* is out of 1.0 scope (#13).
///  - `/relay` `/dcc` `/e2e` `/list` `/jitsi` `/clear` — web-specific or unbuilt features.
///  - `/quit` `/reconnect` — network lifecycle (#11); intercepted with a note rather than
///    left to the raw fallback, where a bare `/quit` would fire a real IRC `QUIT`.

// MARK: - Effects

/// One thing a parsed command asks the app to do. A command resolves to zero or more of
/// these: `/cycle` is a part then a join, `/msg alice hi` is a send then an activate. The
/// parser only decides; `ChatViewModel` performs the I/O. Effects that touch a network
/// (`send`/`action`/`notice`/`raw`/`join`/`part`/`close`/`ctcp`) run against the issuing
/// buffer's network — they carry a target/channel but not the id, which the executor
/// supplies from context. `away`/`back` carry no network at all: they're user-scoped and
/// hit every connection (see `away_is_user_scoped`).
public enum CommandEffect: Equatable, Sendable {
    /// PRIVMSG to a target. The server splits it on newlines and byte-length, so the full
    /// text goes as one `send` — the client never chunks (see `LurkerClient.sendMessage`).
    case send(target: String, text: String)
    /// CTCP ACTION — `/me`, `/slap`.
    case action(target: String, text: String)
    /// NOTICE.
    case notice(target: String, text: String)
    /// A raw IRC line on the issuing network: the escape hatch for `NICK`, `MODE`, `KICK`,
    /// `WHOIS`, service messages, server queries, and every unknown command.
    case raw(line: String)
    /// Join a channel, with an optional key.
    case join(channel: String, key: String?)
    /// Part a channel with an optional reason. The buffer survives, parted.
    case part(channel: String, reason: String?)
    /// Close a buffer (parts a channel / untracks a DM).
    case close(target: String)
    /// User-scoped away; an empty message clears it (the server treats `/away` with no text
    /// as `/back`).
    case away(message: String)
    /// User-scoped back.
    case back
    /// A CTCP request aimed at a target — `/ctcp`, `/ping`.
    case ctcp(target: String, type: String, args: String)
    /// Open the target buffer and switch the UI to it — the DM that `/msg` and `/query`
    /// open. The executor turns this into navigation.
    case activate(target: String)
    /// A local, ephemeral info line printed into the issuing buffer: `/commands` output, a
    /// usage hint, or a "not in the app yet" note. Never touches the network.
    case info(String)
}

/// What a raw line of composer input turned out to be.
public enum ParsedInput: Equatable, Sendable {
    /// Ordinary text to PRIVMSG to the current buffer — a plain message, or a `//`-escaped
    /// line sent literally with the leading slash stripped.
    case message(String)
    /// Non-command input typed into the system buffer, which has no network to send to. The
    /// caller prints the nudge rather than dropping it silently.
    case notCommand
    /// A slash command, resolved to the effects to carry out in order.
    case command([CommandEffect])
}

// MARK: - Command table

/// How a command groups in the `/commands` cheatsheet and in the completion chips.
public enum CommandCategory: String, Sendable, CaseIterable {
    case messaging = "Messaging"
    case channels = "Channels"
    case moderation = "Moderation"
    case server = "Server"
    case status = "Status"
    case app = "App"
}

/// What an argument slot expects — the signal that drives autocomplete. Only `.channel` and
/// `.nick` produce completion chips; the rest are free text or opaque tokens the app can't
/// suggest for (and where an `@`-mention can still fire).
public enum ArgKind: Equatable, Sendable {
    case channel
    case nick
    /// Free text running to the end of the line (a message body, a reason, a topic).
    case text
    /// A single opaque token with nothing to suggest (a channel key, a raw mode string).
    case word
    /// Your own new nick — a value only you can supply.
    case newNick
    case none
}

/// One positional argument in a command's grammar. Used for the usage hints in `/commands`
/// and to tell the completer what the slot under the caret wants.
public struct ArgSpec: Equatable, Sendable {
    public let label: String
    public let kind: ArgKind
    public let optional: Bool
    /// Whether this slot swallows the rest of the line. A trailing `.text` reason or body is
    /// `rest`; a channel or a nick is a single token.
    public let rest: Bool

    public init(_ label: String, _ kind: ArgKind, optional: Bool = false, rest: Bool = false) {
        self.label = label
        self.kind = kind
        self.optional = optional
        self.rest = rest
    }
}

/// A command's identity for the table: its names (canonical first, then aliases), where it
/// files, a one-line summary, and its argument grammar. This is the single source the
/// `/commands` help and the completion chips both read; the actual wire translation lives in
/// `CommandParser` (a switch, mirroring the web's `handleCommand`), the same split the web
/// keeps between its `COMMANDS_LINES` cheatsheet and its dispatcher.
public struct CommandSpec: Equatable, Sendable {
    public let names: [String]
    public let category: CommandCategory
    public let summary: String
    public let args: [ArgSpec]
    /// Runs without an active network — the system buffer can issue it (`/away`, `/back`,
    /// `/commands`). Everything else needs a channel or DM and is gated otherwise.
    public let networkAgnostic: Bool

    public init(
        _ names: [String],
        _ category: CommandCategory,
        _ summary: String,
        args: [ArgSpec] = [],
        networkAgnostic: Bool = false
    ) {
        self.names = names
        self.category = category
        self.summary = summary
        self.args = args
        self.networkAgnostic = networkAgnostic
    }

    /// The canonical name, without the leading slash.
    public var name: String { names[0] }

    /// The kind of the argument at `index`, following a trailing `rest` slot for any index
    /// past the last declared one (so the third nick of `/op a b c` still reads as a nick).
    public func argKind(at index: Int) -> ArgKind {
        guard !args.isEmpty else { return .none }
        if index < args.count { return args[index].kind }
        let last = args[args.count - 1]
        return last.rest ? last.kind : .none
    }

    /// The usage line shown by `/commands`, e.g. `/msg <nick> [message]`.
    public var usage: String {
        let parts = args.map { arg -> String in
            let inner = arg.rest && arg.kind == .nick ? "\(arg.label)…" : arg.label
            return arg.optional ? "[\(inner)]" : "<\(inner)>"
        }
        return (["/" + name] + parts).joined(separator: " ")
    }
}

/// The client's command vocabulary. Order within a category is the order `/commands` prints.
public enum CommandRegistry {
    public static let all: [CommandSpec] = [
        // Messaging
        CommandSpec(["me"], .messaging, "Send an action to this buffer",
                    args: [ArgSpec("action", .text, rest: true)]),
        CommandSpec(["msg", "query"], .messaging, "Open a DM and optionally send a message",
                    args: [ArgSpec("nick", .nick), ArgSpec("message", .text, optional: true, rest: true)]),
        CommandSpec(["notice"], .messaging, "Send a NOTICE",
                    args: [ArgSpec("target", .nick), ArgSpec("message", .text, rest: true)]),
        CommandSpec(["slap"], .messaging, "Slap someone with a large trout",
                    args: [ArgSpec("nick", .nick)]),
        CommandSpec(["ctcp"], .messaging, "Send a CTCP request",
                    args: [ArgSpec("target", .nick), ArgSpec("type", .word), ArgSpec("args", .text, optional: true, rest: true)]),
        CommandSpec(["ping"], .messaging, "CTCP PING a user",
                    args: [ArgSpec("nick", .nick)]),

        // Channels
        CommandSpec(["join"], .channels, "Join a channel",
                    args: [ArgSpec("channel", .channel), ArgSpec("key", .word, optional: true)]),
        CommandSpec(["part", "leave"], .channels, "Leave a channel (keeps the buffer)",
                    args: [ArgSpec("channel", .channel, optional: true), ArgSpec("reason", .text, optional: true, rest: true)]),
        CommandSpec(["cycle", "hop"], .channels, "Part and rejoin this channel",
                    args: [ArgSpec("reason", .text, optional: true, rest: true)]),
        CommandSpec(["close"], .channels, "Close this buffer"),
        CommandSpec(["topic"], .channels, "View or set the channel topic",
                    args: [ArgSpec("new topic", .text, optional: true, rest: true)]),
        CommandSpec(["nick"], .channels, "Change your nick",
                    args: [ArgSpec("newnick", .newNick)]),
        CommandSpec(["whois"], .channels, "Look up a user",
                    args: [ArgSpec("nick", .nick, optional: true)]),
        CommandSpec(["invite"], .channels, "Invite a user to a channel",
                    args: [ArgSpec("nick", .nick), ArgSpec("channel", .channel, optional: true)]),

        // Moderation
        CommandSpec(["kick"], .moderation, "Kick a user from this channel",
                    args: [ArgSpec("nick", .nick), ArgSpec("reason", .text, optional: true, rest: true)]),
        CommandSpec(["mode"], .moderation, "Set channel or user modes",
                    args: [ArgSpec("modes", .text, rest: true)]),
        CommandSpec(["op"], .moderation, "Give operator status",
                    args: [ArgSpec("nick", .nick, rest: true)]),
        CommandSpec(["deop"], .moderation, "Remove operator status",
                    args: [ArgSpec("nick", .nick, rest: true)]),
        CommandSpec(["voice"], .moderation, "Give voice",
                    args: [ArgSpec("nick", .nick, rest: true)]),
        CommandSpec(["devoice"], .moderation, "Remove voice",
                    args: [ArgSpec("nick", .nick, rest: true)]),
        CommandSpec(["halfop"], .moderation, "Give half-operator status",
                    args: [ArgSpec("nick", .nick, rest: true)]),
        CommandSpec(["dehalfop"], .moderation, "Remove half-operator status",
                    args: [ArgSpec("nick", .nick, rest: true)]),
        CommandSpec(["ban"], .moderation, "Ban a mask",
                    args: [ArgSpec("mask", .nick, rest: true)]),
        CommandSpec(["unban"], .moderation, "Lift a ban",
                    args: [ArgSpec("mask", .nick, rest: true)]),
        CommandSpec(["quiet"], .moderation, "Quiet a mask",
                    args: [ArgSpec("mask", .nick, rest: true)]),
        CommandSpec(["unquiet"], .moderation, "Lift a quiet",
                    args: [ArgSpec("mask", .nick, rest: true)]),

        // Server
        CommandSpec(["raw", "quote"], .server, "Send a raw IRC line",
                    args: [ArgSpec("line", .text, rest: true)]),
        CommandSpec(["ns"], .server, "Message NickServ",
                    args: [ArgSpec("message", .text, rest: true)]),
        CommandSpec(["cs"], .server, "Message ChanServ",
                    args: [ArgSpec("message", .text, rest: true)]),
        CommandSpec(["names"], .server, "List the users on a channel",
                    args: [ArgSpec("channel", .channel, optional: true)]),
        CommandSpec(["who"], .server, "Run a WHO query",
                    args: [ArgSpec("mask", .text, optional: true, rest: true)]),
        CommandSpec(["whowas"], .server, "Look up a departed nick",
                    args: [ArgSpec("nick", .nick, optional: true)]),
        CommandSpec(["motd"], .server, "Show the message of the day"),
        CommandSpec(["version"], .server, "Query server version"),
        CommandSpec(["time"], .server, "Query server time"),
        CommandSpec(["lusers"], .server, "Show network user counts"),
        CommandSpec(["links"], .server, "List server links"),
        CommandSpec(["map"], .server, "Show the network map"),
        CommandSpec(["stats"], .server, "Query server statistics",
                    args: [ArgSpec("query", .text, optional: true, rest: true)]),
        CommandSpec(["admin"], .server, "Show server admin info"),
        CommandSpec(["info"], .server, "Show server info"),
        CommandSpec(["userhost"], .server, "Look up a user's host",
                    args: [ArgSpec("nick", .nick, optional: true)]),
        CommandSpec(["ison"], .server, "Check whether nicks are online",
                    args: [ArgSpec("nick", .text, optional: true, rest: true)]),
        CommandSpec(["help"], .server, "Ask the server for help",
                    args: [ArgSpec("topic", .text, optional: true, rest: true)]),

        // Status / app
        CommandSpec(["away"], .status, "Set yourself away on every network",
                    args: [ArgSpec("message", .text, optional: true, rest: true)], networkAgnostic: true),
        CommandSpec(["back"], .status, "Clear your away status", networkAgnostic: true),
        CommandSpec(["commands"], .app, "List the commands you can run", networkAgnostic: true),
    ]

    /// The spec whose names include `verb` (case-insensitive), or nil for an unknown verb.
    public static func spec(for verb: String) -> CommandSpec? {
        let needle = verb.lowercased()
        return all.first { $0.names.contains(needle) }
    }

    /// A bare `/` can't rank by likelihood, so it shows a hand-picked starter set that spans
    /// categories rather than the first N of the table (which would be one category's block).
    /// Most useful first — the completer puts the head of the list nearest the composer.
    public static let featured = ["join", "msg", "me", "nick", "topic", "away"]

    /// Specs whose canonical name starts with `query` (case-insensitive), best first, capped
    /// at `limit`. An empty query returns the `featured` starter set. Only the canonical name
    /// is matched, not aliases — the chips shouldn't offer `/query` and `/msg` as two things.
    public static func matching(_ query: String, limit: Int = 6) -> [CommandSpec] {
        guard !query.isEmpty else {
            return Array(featured.compactMap { name in all.first { $0.name == name } }.prefix(limit))
        }
        let needle = query.lowercased()
        return Array(all.filter { $0.name.hasPrefix(needle) }.prefix(limit))
    }

    /// The `/commands` cheatsheet as one multi-line block, grouped by category.
    public static func helpText() -> String {
        var lines = ["Commands you can run here:"]
        for category in CommandCategory.allCases {
            let specs = all.filter { $0.category == category }
            guard !specs.isEmpty else { continue }
            lines.append("")
            lines.append(category.rawValue)
            for spec in specs {
                lines.append("  \(spec.usage) — \(spec.summary)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
