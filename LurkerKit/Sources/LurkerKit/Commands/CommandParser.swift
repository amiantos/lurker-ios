// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Turns a line of composer input into a `ParsedInput`. Pure and total — every string maps
/// to something, and nothing here does I/O. A faithful port of the web client's `submit()`
/// gating plus its `handleCommand` dispatcher, so both clients translate a given command to
/// the same wire verbs.
public enum CommandParser {

    /// Classify `input` typed in the buffer identified by (`networkId`, `target`).
    ///
    /// The rules, in order (matching the web's `submit`):
    ///  - `//…` is an escape: send the rest literally, one slash stripped, so you *can* say a
    ///    line that starts with a slash.
    ///  - `/…` is a command.
    ///  - anything else is a plain message — except in the system buffer, which has no
    ///    network to send to, where it's `notCommand`.
    public static func parse(_ input: String, networkId: Int?, target: String) -> ParsedInput {
        // The composer trims before it hands text over, but be total about it anyway.
        let raw = input

        if raw.hasPrefix("//") {
            return .message(String(raw.dropFirst()))
        }
        guard raw.hasPrefix("/") else {
            return networkId == nil ? .notCommand : .message(raw)
        }

        // Split the verb off the rest. `rest` is the whitespace-collapsed token list (the
        // web's `[cmd, ...rest] = line.slice(1).split(/\s+/)`); `argLine` is everything after
        // the verb, edge-trimmed but with interior spacing preserved (the web's `argLine`).
        let body = String(raw.dropFirst())
        let verb = String(body.prefix { !$0.isWhitespace }).lowercased()
        let argLine = String(body.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
        let rest = argLine.isEmpty
            ? []
            : argLine.split(whereSeparator: { $0.isWhitespace }).map(String.init)

        return .command(resolve(verb: verb, body: body, argLine: argLine, rest: rest, networkId: networkId, target: target))
    }

    // MARK: - Dispatch

    private static func resolve(
        verb: String,
        body: String,
        argLine: String,
        rest: [String],
        networkId: Int?,
        target: String
    ) -> [CommandEffect] {
        // Network-agnostic block: these run whether or not a network is active, so the
        // system buffer can issue them.
        switch verb {
        case "commands":
            return [.info(CommandRegistry.helpText())]
        case "away":
            // Empty message clears away. User-scoped — no network attached.
            return [.away(message: argLine)]
        case "back":
            return [.back]
        default:
            break
        }

        // Network gate: everything below needs a channel or DM. In the system buffer, say so
        // rather than dropping the line.
        guard networkId != nil else {
            return [.info("/\(verb) needs an active network — switch to a channel or DM first.")]
        }

        switch verb {
        // Messaging
        case "me":
            return argLine.isEmpty ? [] : [.action(target: target, text: argLine)]
        case "slap":
            guard let who = rest.first else { return [.info("usage: /slap <nick>")] }
            return [.action(target: target, text: "slaps \(who) around a bit with a large trout")]
        case "msg", "query":
            guard let who = rest.first else { return [.info("usage: /msg <nick> [message]")] }
            let bodyText = rest.dropFirst().joined(separator: " ")
            var effects: [CommandEffect] = []
            if !bodyText.isEmpty { effects.append(.send(target: who, text: bodyText)) }
            effects.append(.activate(target: who))
            return effects
        case "notice":
            guard let who = rest.first else { return [.info("usage: /notice <target> <message>")] }
            let bodyText = rest.dropFirst().joined(separator: " ")
            guard !bodyText.isEmpty else { return [.info("usage: /notice <target> <message>")] }
            return [.notice(target: who, text: bodyText)]
        case "ctcp":
            guard rest.count >= 2 else { return [.info("usage: /ctcp <target> <type> [args]")] }
            let ctcpArgs = rest.dropFirst(2).joined(separator: " ")
            return [.ctcp(target: rest[0], type: rest[1].uppercased(), args: ctcpArgs)]
        case "ping":
            guard let who = rest.first else { return [.info("usage: /ping <nick>")] }
            return [.ctcp(target: who, type: "PING", args: "")]

        // Channels & buffers
        case "join":
            // A bare `/join` is a no-op, like the web (it just keeps the buffer you're in).
            guard let first = rest.first else { return [] }
            let key = rest.count > 1 ? rest[1] : nil
            return [.join(channel: ensureChannelPrefix(first), key: key)]
        case "part", "leave":
            // The web does NOT prefix here: `channel = rest[0] || target`. So `/part foo`
            // parts "foo" literally; a bare `/part` parts the current buffer. Ported as-is.
            let channel = rest.first ?? target
            let reason = rest.dropFirst().joined(separator: " ")
            return [.part(channel: channel, reason: reason.isEmpty ? nil : reason)]
        case "cycle", "hop":
            let channel = rest.first ?? target
            return [.part(channel: channel, reason: nil), .join(channel: ensureChannelPrefix(channel), key: nil)]
        case "close":
            return [.close(target: target)]
        case "topic":
            let line = argLine.isEmpty ? "TOPIC \(target)" : "TOPIC \(target) :\(argLine)"
            return [.raw(line: line)]
        case "nick":
            guard let newNick = rest.first else { return [.info("usage: /nick <newnick>")] }
            return [.raw(line: "NICK \(newNick)")]
        case "whois":
            // A bare `/whois` in a DM whoises the peer; in a channel it needs a nick.
            let who = rest.first ?? (isNickTarget(target) ? target : "")
            guard !who.isEmpty else { return [.info("usage: /whois <nick>")] }
            return [.raw(line: "WHOIS \(who)")]
        case "invite":
            guard let who = rest.first else { return [.info("usage: /invite <nick> [channel]")] }
            let channel = rest.count > 1 ? rest[1] : target
            return [.raw(line: "INVITE \(who) \(channel)")]

        // Moderation
        case "kick":
            guard let who = rest.first else { return [.info("usage: /kick <nick> [reason]")] }
            let reason = rest.dropFirst().joined(separator: " ")
            let trailer = reason.isEmpty ? "" : " :\(reason)"
            return [.raw(line: "KICK \(target) \(who)\(trailer)")]
        case "mode":
            guard !argLine.isEmpty else { return [.info("usage: /mode <modes>")] }
            return [.raw(line: "MODE \(argLine)")]
        case "op": return modeShortcut("o", adding: true, rest: rest, target: target)
        case "deop": return modeShortcut("o", adding: false, rest: rest, target: target)
        case "voice": return modeShortcut("v", adding: true, rest: rest, target: target)
        case "devoice": return modeShortcut("v", adding: false, rest: rest, target: target)
        case "halfop": return modeShortcut("h", adding: true, rest: rest, target: target)
        case "dehalfop": return modeShortcut("h", adding: false, rest: rest, target: target)
        case "ban": return modeShortcut("b", adding: true, rest: rest, target: target)
        case "unban": return modeShortcut("b", adding: false, rest: rest, target: target)
        case "quiet": return modeShortcut("q", adding: true, rest: rest, target: target)
        case "unquiet": return modeShortcut("q", adding: false, rest: rest, target: target)

        // Server / services
        case "raw", "quote":
            guard !argLine.isEmpty else { return [.info("usage: /raw <line>")] }
            return [.raw(line: argLine)]
        case "ns":
            guard !argLine.isEmpty else { return [.info("usage: /ns <message>")] }
            return [.raw(line: "PRIVMSG NickServ :\(argLine)")]
        case "cs":
            guard !argLine.isEmpty else { return [.info("usage: /cs <message>")] }
            return [.raw(line: "PRIVMSG ChanServ :\(argLine)")]

        // Server queries — a raw line of the uppercased verb plus any argument, matching the
        // web. Declared in the registry (so they complete and appear in /commands), so they
        // route here explicitly rather than sliding through the unknown-command default.
        case "motd", "version", "time", "lusers", "links", "map", "admin", "info",
             "names", "who", "whowas", "stats", "userhost", "ison", "help":
            let line = argLine.isEmpty ? verb.uppercased() : "\(verb.uppercased()) \(argLine)"
            return [.raw(line: line)]

        // Network lifecycle — deferred to network management (#11). Intercepted rather than
        // left to the raw fallback, where `/quit` would send a real IRC QUIT.
        case "quit", "reconnect", "connect", "disconnect", "server":
            return [.info("Connecting and disconnecting networks isn't in the app yet — it's coming with network management.")]

        default:
            // Server-query verbs (WHO, NAMES, MOTD, …) and anything unrecognized go raw,
            // exactly as the web's `default`. The original casing is preserved: `line.slice(1)`.
            return [.raw(line: body.trimmingCharacters(in: .whitespaces))]
        }
    }

    // MARK: - Helpers

    /// The mode-shortcut family (`/op`, `/ban`, …): one mode letter repeated once per target,
    /// against a leading channel arg or the current buffer. `/op a b` → `MODE #chan +oo a b`.
    private static func modeShortcut(
        _ letter: Character,
        adding: Bool,
        rest: [String],
        target: String
    ) -> [CommandEffect] {
        var args = rest
        // An explicit leading channel overrides the current buffer.
        let channel: String
        if let first = args.first, isChannelTarget(first) {
            channel = first
            args.removeFirst()
        } else {
            channel = target
        }
        guard !args.isEmpty else {
            return [.info("usage: /\(adding ? "" : "de")\(letter) <nick>…")]
        }
        let sign = adding ? "+" : "-"
        let letters = String(repeating: letter, count: args.count)
        return [.raw(line: "MODE \(channel) \(sign)\(letters) \(args.joined(separator: " "))")]
    }

    /// Prefix a bare channel name with `#`, leaving an already-prefixed one alone — the web's
    /// `ensureChannelPrefix`.
    private static func ensureChannelPrefix(_ name: String) -> String {
        guard let first = name.first else { return name }
        return "#&+!".contains(first) ? name : "#\(name)"
    }

    private static func isChannelTarget(_ target: String) -> Bool {
        guard let first = target.first else { return false }
        return first == "#" || first == "&"
    }

    /// A DM/user target: has a network, isn't a channel, isn't a `:server:`/`:system:` pseudo.
    private static func isNickTarget(_ target: String) -> Bool {
        !isChannelTarget(target) && !target.hasPrefix(":")
    }
}
