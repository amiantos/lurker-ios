// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Turns a line of composer input into a `ParsedInput`. Pure and total — every string maps
/// to something, and nothing here does I/O. A faithful port of the web client's `submit()`
/// gating plus its `handleCommand` dispatcher, so both clients translate a given command to
/// the same wire verbs.
public enum CommandParser {

    /// A user-authored chat body, on its way to a channel or DM: `||spoiler||` becomes IRC
    /// spoiler codes here and nowhere else.
    ///
    /// ⚠⚠ Opt-in PER CALL SITE, deliberately — never fold this into `ChatViewModel.send` or
    /// `LurkerClient.sendMessage`. `/ns` and `/cs` build a raw `PRIVMSG NickServ :…` whose body
    /// is usually `identify <password>`, and rewriting bytes headed for an auth handshake is a
    /// bug, not a feature. Routing each chat verb through this is what keeps those untouched by
    /// construction rather than by a guard someone has to remember. (They emit `.raw` rather
    /// than `.send`, so on this client they're separated by shape too — but the rule is the
    /// rule, and the web learned it the hard way.)
    ///
    /// Applied to: plain text, `//`-escaped text, `/me`, `/msg`, `/query`, `/notice`. Not to
    /// `/slap` (its body is generated, not typed), nor `/raw`, `/quote`, `/ctcp`, `/ns`, `/cs`.
    /// That set matches the web's `chatBody` callers; keep them in step.
    ///
    /// ⚠ Only the PAYLOAD is rewritten. Anything showing the user their own line back — a
    /// failed-send notice, input history — must keep the TYPED text, so what they see and recall
    /// is `||…||` rather than raw control codes.
    private static func chatBody(_ text: String) -> String {
        SpoilerMarkup.apply(to: text)
    }

    /// Classify `input` typed in the buffer identified by (`networkId`, `target`).
    ///
    /// The rules, in order (matching the web's `submit`):
    ///  - `//…` is an escape: send the rest literally, one slash stripped, so you *can* say a
    ///    line that starts with a slash.
    ///  - `/…` is a command.
    ///  - anything else is a plain message — except in the system buffer, which has no
    ///    network to send to, where it's `notCommand`.
    ///
    /// `ignores` is the account's rules, passed in rather than reached for so this stays pure:
    /// `/ignore` with no arguments prints them and `/unignore <n>` addresses one by its
    /// position. The whole set goes in rather than a materialized listing so that the two
    /// verbs that need one build it and the other fifty don't — every plain message comes
    /// through here too. It defaults to empty, the honest answer for a caller that has none.
    ///
    /// `relayBots` rides along for the same reason and with the same nil convention: `/relay` with
    /// no arguments prints the marks on this network, and nil means "they haven't arrived yet", so
    /// the listing says so rather than claiming there are none.
    ///
    /// `modeSpec` is the network's mode vocabulary, nil while it's unknown: `/quiet` reads it to
    /// tell a quiet list from an owner rank, and the mode shortcuts read its MODES limit.
    ///
    /// `hasBuffer` answers whether this network has a buffer by that name open. `/part`, `/topic`
    /// and `/mode` ask it about a leading `&`, `+` or `!` word, which is a channel only when one by
    /// that name exists (see `leadsWithChannel`). It defaults to "none", which reads every such
    /// word as text.
    ///
    /// `now` is likewise injected, for `/ignore -time` and for lapsed rules.
    /// The line a composer sends for `draft`, or nil when there's nothing to send (empty, or only
    /// whitespace). Trailing whitespace goes; LEADING stays, because it decides what the line is:
    /// ` /whois bob` is text to the channel, as on the web (`raw.startsWith('/')` on the untrimmed
    /// draft), irssi (`cmdchars` on the first character) and gamja (lurker-ios#210). Both composers
    /// send through this, and `OutgoingTyping` asks it too, so the typing a draft announces matches
    /// what it sends.
    public static func sendable(_ draft: String) -> String? {
        var line = draft
        while let last = line.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
            line.unicodeScalars.removeLast()
        }
        return line.unicodeScalars.contains(where: { !CharacterSet.whitespacesAndNewlines.contains($0) }) ? line : nil
    }

    public static func parse(
        _ input: String,
        networkId: Int?,
        target: String,
        ignores: IgnoreSet? = .empty,
        relayBots: RelayBotSet? = .empty,
        modeSpec: ModeSpec? = nil,
        hasBuffer: (String) -> Bool = { _ in false },
        now: Date = Date()
    ) -> ParsedInput {
        // Command or message is decided on the line as typed — the composer drops only TRAILING
        // whitespace (`sendable`): a leading space is how you say "/whatever" to a channel without
        // the `//` escape, as on the web, irssi and gamja (lurker-ios#210).
        let raw = input

        if raw.hasPrefix("//") {
            // A `//`-escaped literal only has somewhere to go in a real buffer; in the system
            // buffer it's non-command input like any other, so nudge rather than swallow it.
            return networkId == nil ? .notCommand : .message(chatBody(String(raw.dropFirst())))
        }
        guard raw.hasPrefix("/") else {
            return networkId == nil ? .notCommand : .message(chatBody(raw))
        }

        // Split the verb off the rest. `rest` is the whitespace-collapsed token list (the
        // web's `[cmd, ...rest] = line.slice(1).split(/\s+/)`); `argLine` is everything after
        // the verb, edge-trimmed but with interior spacing preserved (the web's `argLine`).
        let body = String(raw.dropFirst())
        let verb = String(body.prefix { !$0.isWhitespace }).lowercased()
        // Newlines too, like the web's `trim()`: `/me⏎waves` (a multi-line paste, a
        // shift-return) would otherwise send the newline at the front of the action.
        let argLine = String(body.dropFirst(verb.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = argLine.isEmpty
            ? []
            : argLine.split(whereSeparator: { $0.isWhitespace }).map(String.init)

        return .command(resolve(
            verb: verb, fullBody: body, argLine: argLine, rest: rest,
            networkId: networkId, target: target, ignores: ignores, relayBots: relayBots,
            modeSpec: modeSpec, hasBuffer: hasBuffer, now: now
        ))
    }

    // MARK: - Dispatch

    private static func resolve(
        verb: String,
        fullBody: String,
        argLine: String,
        rest: [String],
        networkId: Int?,
        target: String,
        ignores: IgnoreSet?,
        relayBots: RelayBotSet?,
        modeSpec: ModeSpec?,
        hasBuffer: (String) -> Bool,
        now: Date
    ) -> [CommandEffect] {
        // A lone `/` (or `/ `) has no verb — nudge rather than fall through to the raw
        // default, which would put an empty line on the wire.
        guard !verb.isEmpty else {
            return [.info("Type a command after the slash — /commands lists what you can run.")]
        }

        // Network-agnostic block: these run whether or not a network is active, so the
        // system buffer can issue them.
        switch verb {
        case "commands":
            return [.info(CommandRegistry.helpText())]
        case "away", "back":
            // Empty message clears away. The network it's typed on goes with it, and from the
            // system buffer there's none, which the server reads as every network — so `-one`
            // there is refused rather than quietly reaching them all.
            let (all, message) = awayFlag(argLine)
            if all == false && networkId == nil {
                return [.info("/\(verb) -one: there's no network here. Run it in a network's buffer.")]
            }
            return verb == "away" ? [.away(message: message, all: all)] : [.back(all: all)]
        // Ignore rules are global by default, so both verbs run without a network — the system
        // buffer can list them and write them. Only `-network` needs a connection, and that's
        // checked where it's read.
        case "ignore":
            return resolveIgnore(argLine: argLine, networkId: networkId, ignores: ignores, now: now)
        case "unignore":
            return resolveUnignore(argLine: argLine, networkId: networkId, ignores: ignores, now: now)
        // Intercepted rather than rawed, and above the gate because none of them is about a
        // network: `SERVER` is a server-to-server command, and what people mean by it (and by the
        // web's `/network` verbs) is a form on this client. The rest are the web's app commands,
        // with no screen here; raw, each would come back as a 421 in the server log.
        case "server", "network", "net":
            return [.info("Networks are added and edited in Settings → Networks.")]
        case "set", "get", "theme":
            return [.info("/\(verb) is web-only — the app's own options are in Settings.")]
        case "highlight", "hilight", "unhighlight", "dehilight":
            return [.info("Highlight words are edited in the web client for now.")]
        default:
            break
        }

        // Network gate: everything below needs a channel or DM. In the system buffer, say so
        // rather than dropping the line.
        //
        // Bound rather than merely tested, so the one case below that needs the id — `/relay`,
        // whose marks are per-(network, nick) — takes it from the gate instead of restating it or
        // force-unwrapping. Nothing else past this point reads it: the wire effects carry a target
        // and let the executor supply the network.
        guard let networkId else {
            // The connection verbs (#152) act on a network rather than on a conversation, and
            // the server buffer is as good a place to type them as a channel — so their gate
            // says so, instead of sending someone with an offline network to a channel they
            // can't join yet.
            if ["connect", "disconnect", "quit", "reconnect"].contains(verb) {
                return [.info("/\(verb) needs a network — open one of its buffers first, or use Settings → Networks.")]
            }
            return [.info("/\(verb) needs an active network — switch to a channel or DM first.")]
        }

        switch verb {
        // Messaging
        case "me":
            return argLine.isEmpty ? [] : [.action(target: target, text: chatBody(argLine))]
        case "react":
            let value = argLine.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return [.info("usage: /react <emoji|text> — e.g. /react 👍")] }
            // The web turns `:tada:` (or `:tada`) into 🎉 from its emoji table. This client has no
            // table, and sending the name would react with the literal text, so it refuses
            // instead. `:D` and `:P` are reactions people type on purpose, and still go out.
            if isShortcode(value) {
                return [.info("/react: emoji names like \(value) aren't supported here — use the emoji itself, e.g. /react 👍")]
            }
            guard Reactions.isValidValue(value) else {
                return [.info("a reaction can be at most \(Reactions.maxGraphemes) characters")]
            }
            return [.react(value: value)]
        case "slap":
            guard let who = rest.first else { return [.info("usage: /slap <nick>")] }
            return [.action(target: target, text: "slaps \(who) around a bit with a large trout")]
        case "shrug":
            // A message, not an action: `/shrug no idea` says "no idea ¯\_(ツ)_/¯", as on the web.
            guard ChannelName.isChannelTarget(target) || isNickTarget(target) else {
                return [.info("usage: /shrug [text] — run inside a channel or DM")]
            }
            let shrugText = argLine.isEmpty ? Self.shrug : "\(argLine) \(Self.shrug)"
            return [.send(target: target, text: chatBody(shrugText))]
        case "msg", "query":
            guard let who = rest.first else { return [.info("usage: /msg <nick> [message]")] }
            let bodyText = rest.dropFirst().joined(separator: " ")
            var effects: [CommandEffect] = []
            if !bodyText.isEmpty { effects.append(.send(target: who, text: chatBody(bodyText))) }
            effects.append(.activate(target: who))
            return effects
        case "notice":
            guard let who = rest.first else { return [.info("usage: /notice <target> <text>")] }
            // Slice the body past the target so interior spacing survives (mirrors /topic),
            // rather than re-joining the whitespace-split tokens.
            let bodyText = body(after: who, in: argLine)
            guard !bodyText.isEmpty else { return [.info("usage: /notice <target> <text>")] }
            return [.notice(target: who, text: chatBody(bodyText))]
        case "ctcp":
            guard rest.count >= 2 else { return [.info("usage: /ctcp <target> <type> [args]")] }
            let ctcpArgs = rest.dropFirst(2).joined(separator: " ")
            return [.ctcp(target: rest[0], type: rest[1].uppercased(), args: ctcpArgs)]
        case "ping":
            // A bare /ping in a DM pings the peer.
            let who = rest.first ?? bufferPeer(target)
            guard !who.isEmpty else { return [.info("usage: /ping <nick>")] }
            return [.ctcp(target: who, type: "PING", args: "")]

        // Channels & buffers
        case "join", "j":
            // A bare `/join` is a no-op, like the web (it just keeps the buffer you're in).
            guard let first = rest.first else { return [] }
            let key = rest.count > 1 ? rest[1] : nil
            return [.join(channel: ChannelName.ensurePrefix(first), key: key)]
        case "part", "leave", "p":
            // `/part [reason]` leaves the current channel; `/part <#chan> [reason]` leaves a
            // named one. A leading channel word marks a channel (see `leadsWithChannel`), anything
            // else is a parting reason for the current channel — so `/part heading out` and
            // `/part +brb` say goodbye here rather than parting a channel "heading" or "+brb".
            let partChannel: String?
            let partReason: String
            if let first = rest.first, leadsWithChannel(first, hasBuffer: hasBuffer) {
                partChannel = first
                partReason = body(after: first, in: argLine)
            } else {
                partChannel = ChannelName.isChannelTarget(target) ? target : nil
                partReason = argLine
            }
            guard let partChannel else {
                return [.info("usage: /part [#chan] [reason] — no channel context")]
            }
            return [.part(channel: partChannel, reason: partReason.isEmpty ? nil : partReason)]
        case "cycle", "hop":
            // Part and rejoin the CURRENT channel; the whole arg line is an optional part
            // reason (not a channel). Both legs use the structured verbs so the persisted
            // `joined` flag flips false and back, keeping reconnect auto-join intact.
            guard ChannelName.isChannelTarget(target) else {
                return [.info("usage: /cycle [reason] — run inside a channel")]
            }
            return [.part(channel: target, reason: argLine.isEmpty ? nil : argLine),
                    .join(channel: target, key: nil)]
        case "close":
            return [.close(target: target)]
        case "clear":
            // `/clear`            — hide everything up to now, behind an undoable marker;
            // `/clear off|undo`   — drop the marker so the hidden messages come back.
            //
            // Anything else is read as a plain clear rather than refused. `/clear` takes no
            // other argument, and the alternative — an error for `/clear all`, which is what
            // a user reaching for "clear everything" would type — would refuse the thing they
            // asked for on the grounds that they were too specific about it.
            let arg = argLine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return [.clear(target: target, undo: arg == "off" || arg == "undo")]
        case "topic":
            // `/topic` reads the current channel's topic; `/topic text` sets it; a leading
            // channel word retargets (see `leadsWithChannel`, which keeps `/topic !!! down !!!` a
            // topic). Interior spacing of the body is preserved by slicing.
            let channel: String
            let bodyText: String
            if let first = rest.first, leadsWithChannel(first, hasBuffer: hasBuffer) {
                channel = first
                bodyText = body(after: first, in: argLine)
            } else {
                guard ChannelName.isChannelTarget(target) else {
                    return [.info("usage: /topic [#chan] [text] — no channel context")]
                }
                channel = target
                bodyText = argLine
            }
            let line = bodyText.isEmpty ? "TOPIC \(channel)" : "TOPIC \(channel) :\(bodyText)"
            return [.raw(line: line)]
        case "nick":
            guard let newNick = rest.first else { return [.info("usage: /nick <newnick>")] }
            return [.raw(line: "NICK \(newNick)")]
        case "whois":
            // A bare `/whois` in a DM whoises the peer; in a channel it needs a nick.
            let who = rest.first ?? bufferPeer(target)
            guard !who.isEmpty else { return [.info("usage: /whois <nick>")] }
            return [.showProfile(nick: who)]
        case "invite":
            // `/invite <nick> [#chan]`, or channel-first as /kick takes it: `/invite #chan <nick>`.
            // The channel defaults to the current buffer, but only if that's a channel — an
            // /invite from a DM with no explicit channel would otherwise aim at the peer nick.
            //
            // ⚠ A second word that isn't a channel is refused, where the web falls back to the
            // current channel: `/invite bob rust` meant #rust, and inviting bob to the channel
            // you're in instead — maybe a private one — is the worse of the two mistakes.
            let who: String?
            let channel: String?
            if let first = rest.first, ChannelName.isChannelTarget(first) {
                channel = first
                who = rest.count > 1 ? rest[1] : nil
            } else {
                who = rest.first
                if rest.count > 1, !ChannelName.isChannelTarget(rest[1]) {
                    return [.info("/invite: \"\(rest[1])\" isn't a channel — usage: /invite <nick> [#channel]")]
                }
                channel = rest.count > 1 ? rest[1] : (ChannelName.isChannelTarget(target) ? target : nil)
            }
            guard let who else { return [.info("usage: /invite <nick> [#channel]")] }
            guard let channel else {
                return [.info("usage: /invite <nick> [#channel] — no channel context")]
            }
            // Wire order is nick first, whichever way round it was typed.
            return [.raw(line: "INVITE \(who) \(channel)")]

        // Moderation
        case "kick":
            // `/kick <nick> [reason]` in a channel, or `/kick <#chan> <nick> [reason]` anywhere.
            let (channel, args) = leadingChannel(rest, target: target)
            guard let channel else {
                return [.info("usage: /kick [#chan] <nick> [reason] — no channel context")]
            }
            guard let who = args.first else { return [.info("usage: /kick [#chan] <nick> [reason]")] }
            let reason = args.dropFirst().joined(separator: " ")
            let trailer = reason.isEmpty ? "" : " :\(reason)"
            return [.raw(line: "KICK \(channel) \(who)\(trailer)")]
        case "mode":
            // `/mode <flags>` applies to the current channel; `/mode <target> <flags…>` is
            // explicit. A leading `+`/`-` in a channel buffer is the flags-only form — unless it
            // names an open `+channel`, so `/mode +local +m` reaches +local (lurker#724).
            guard let first = rest.first else { return [.info("usage: /mode [target] <flags> [args]")] }
            if (first.hasPrefix("+") || first.hasPrefix("-")), !leadsWithChannel(first, hasBuffer: hasBuffer),
               ChannelName.isChannelTarget(target) {
                return [.raw(line: "MODE \(target) \(rest.joined(separator: " "))")]
            }
            return [.raw(line: "MODE \(argLine)")]
        case "op": return modeShortcut(verb, letter: "o", adding: true, rest: rest, target: target, spec: modeSpec)
        case "deop": return modeShortcut(verb, letter: "o", adding: false, rest: rest, target: target, spec: modeSpec)
        case "voice": return modeShortcut(verb, letter: "v", adding: true, rest: rest, target: target, spec: modeSpec)
        case "devoice": return modeShortcut(verb, letter: "v", adding: false, rest: rest, target: target, spec: modeSpec)
        case "halfop": return modeShortcut(verb, letter: "h", adding: true, rest: rest, target: target, spec: modeSpec)
        case "dehalfop": return modeShortcut(verb, letter: "h", adding: false, rest: rest, target: target, spec: modeSpec)
        case "ban": return modeShortcut(verb, letter: "b", adding: true, rest: rest, target: target, spec: modeSpec)
        case "unban": return modeShortcut(verb, letter: "b", adding: false, rest: rest, target: target, spec: modeSpec)
        // `/quiet` speaks solanum's +q quiet LIST. On InspIRCd and Unreal +q is the owner rank,
        // so `/quiet bob` would make bob an owner — refused unless the network lists q among its
        // list modes. Before the vocabulary arrives there's nothing to check, so it goes through,
        // as on the web.
        case "quiet", "unquiet":
            if noQuietList(modeSpec) { return [.info("this network has no +q quiet list")] }
            return modeShortcut(verb, letter: "q", adding: verb == "quiet", rest: rest, target: target, spec: modeSpec)
        case "kickban":
            // Ban first, so they can't rejoin in the gap, then kick. A leading channel is optional.
            let (channel, args) = leadingChannel(rest, target: target)
            guard let channel else {
                return [.info("usage: /kickban [#chan] <nick> [reason] — no channel context")]
            }
            guard let who = args.first else { return [.info("usage: /kickban [#chan] <nick> [reason]")] }
            let reason = args.dropFirst().joined(separator: " ")
            let trailer = reason.isEmpty ? "" : " :\(reason)"
            return [.raw(line: "MODE \(channel) +b \(who)"), .raw(line: "KICK \(channel) \(who)\(trailer)")]

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

        // DCC (lurker#270). Below the network gate: a chat rides one network's connection.
        case "dcc":
            return resolveDcc(rest: rest)

        // App
        case "relay":
            // Below the network gate above: a mark is per-(network, nick), so there is no
            // sensible answer to `/relay` in the system buffer.
            return resolveRelay(argLine: argLine, networkId: networkId, relayBots: relayBots)

        // Connection lifecycle (#152) — REST verbs on this buffer's network, never raw lines
        // (see `CommandEffect.disconnect` for why a raw QUIT is the one thing /quit must not
        // be). Below the network gate: the system buffer has no connection to start or stop.
        case "connect":
            return [.connect]
        case "disconnect", "quit":
            // The whole argument line is the reason, interior spacing kept — it's a quit
            // message. Empty means "let the server pick its default". Line breaks fold to
            // spaces: the reason is the tail of one IRC line, and a pasted break would end it
            // early and put the rest on the wire as a command of its own.
            let reason = argLine.split(whereSeparator: \.isNewline).joined(separator: " ")
            return [.disconnect(reason: reason.isEmpty ? nil : reason)]
        case "reconnect":
            return [.reconnect]

        // The web's network-scoped commands this client has no screen for. Each would otherwise go
        // out raw and come back as a 421 in the server log — or, for `/list`, as a LIST that only
        // refreshes the server's cache and shows nothing.
        case "list":
            return [.info("The channel list isn't in the app yet — /join #channel if you know its name.")]
        case "retention", "jitsi", "talk", "e2e":
            return [.info("/\(verb) is web-only for now.")]

        default:
            // Anything unrecognized goes raw, exactly as the web's `default`. The original
            // casing is preserved: `line.slice(1)`.
            return [.raw(line: fullBody.trimmingCharacters(in: .whitespaces))]
        }
    }

    // MARK: - DCC (lurker#270)

    private static let dccUsage = "usage: /dcc chat [-passive] <nick> · /dcc close chat <nick>"

    /// The words for DCC file transfers, which this app has no screen for: the web's transfer verbs
    /// and their aliases, plus irssi's `send` and `resume`. A habit carried over from either gets an
    /// answer rather than a usage line that pretends the verb doesn't exist.
    private static let dccTransferVerbs: Set<String> = [
        "list", "ls", "accept", "ok", "yes", "get", "reject", "deny", "no", "cancel", "abort", "stop",
        "send", "resume",
    ]

    /// The scope flag at the front of an `/away` or `/back` line (lurker#994): `-all` for every
    /// network, `-one` for just this one, nil without one. Only a leading, whole-word flag
    /// counts — `/away back at -all hands` is a message, as is `-allnighter`. The web's
    /// `parseAwayFlag` reads it the same way, except that its `\s` also counts U+FEFF: this
    /// splits on `Character.isWhitespace` like every other command (see `IgnoreArgs.tokenize`).
    static func awayFlag(_ argLine: String) -> (all: Bool?, rest: String) {
        let line = argLine.drop(while: \.isWhitespace)
        let word = line.prefix { !$0.isWhitespace }
        let all: Bool
        switch word.lowercased() {
        case "-all": all = true
        case "-one": all = false
        default: return (nil, argLine)
        }
        return (all, String(line.dropFirst(word.count).drop(while: \.isWhitespace)))
    }

    /// `/dcc` — the chat verbs, in irssi's syntax exactly, as the web has them:
    ///
    ///     DCC CHAT [-passive] <nick>      irssi dcc-chat.c:442
    ///     DCC CLOSE <type> <nick>         irssi dcc.c:490
    ///
    /// ⚠ Type-first on close is the reason this is strict. The web once took `/dcc close <nick>`
    /// as a shorthand, which read irssi's `/dcc close chat bob` as closing a chat with a peer
    /// named "chat" — and left the real one open. Accepting only irssi's shape leaves nothing to
    /// guess.
    ///
    /// ⚠ `-passive` is opt-in, never a fallback: WeeChat and HexDroid turn a passive offer into
    /// a silent dial to port 0, so the server refuses an active offer it can't make rather than
    /// quietly degrading to one.
    private static func resolveDcc(rest: [String]) -> [CommandEffect] {
        let args = Array(rest.dropFirst())
        switch rest.first?.lowercased() ?? "" {
        case "chat":
            let flags = args.filter { $0.hasPrefix("-") }
            let positional = args.filter { !$0.hasPrefix("-") }
            if let unknown = flags.first(where: { $0.lowercased() != "-passive" }) {
                return [.info("/dcc: unknown option \"\(unknown)\". usage: /dcc chat [-passive] <nick>")]
            }
            // `/dcc chat close bob` isn't a command, and read literally it would OFFER a chat
            // to someone called "close". Answer the intent instead.
            if positional.count > 1 {
                return [.info(positional[0].lowercased() == "close"
                    ? "To end a chat: /dcc close chat <nick>"
                    : "usage: /dcc chat [-passive] <nick>")]
            }
            guard let nick = dccPeer(positional.first) else {
                return [.info("usage: /dcc chat [-passive] <nick>")]
            }
            return [.dccChat(nick: nick, passive: !flags.isEmpty)]
        case "close":
            switch args.first?.lowercased() ?? "" {
            case "chat":
                guard args.count == 2, let nick = dccPeer(args[1]) else {
                    return [.info("usage: /dcc close chat <nick>")]
                }
                return [.dccCloseChat(nick: nick)]
            case "send", "get":
                return [.info("DCC file transfers aren't in the app yet.")]
            default:
                return [.info("usage: /dcc close chat <nick>")]
            }
        case let verb where dccTransferVerbs.contains(verb):
            return [.info("DCC file transfers aren't in the app yet.")]
        default:
            return [.info(dccUsage)]
        }
    }

    /// The peer a DCC verb names, or nil when the token can't be one.
    ///
    /// ⚠ A leading `=` is refused: that's a chat's BUFFER name, and `/dcc chat =bob` almost
    /// certainly means bob — accepting it would offer a chat to someone literally called "=bob".
    /// A channel is refused too, all four sigils: the offer is a CTCP to its target, so a channel
    /// name would put it in front of everyone there.
    private static func dccPeer(_ token: String?) -> String? {
        guard let token = token?.trimmingCharacters(in: .whitespaces), !token.isEmpty,
              !DccChat.isTarget(token), !ChannelName.isChannelTarget(token)
        else { return nil }
        return token
    }

    // MARK: - Ignore rules (#86)

    /// `/ignore` — with no arguments, the rule listing; otherwise a rule to store.
    ///
    /// Nothing is mutated locally: the effect asks, and the rule appears when the server's
    /// `ignore-list-updated` lands. The receipt rides on the effect rather than being printed
    /// here, so it's withheld when the verb never reached a socket.
    private static func resolveIgnore(
        argLine: String,
        networkId: Int?,
        ignores: IgnoreSet?,
        now: Date
    ) -> [CommandEffect] {
        // `whitespacesAndNewlines`: the composer is multi-line and Return inserts a newline, so
        // `/ignore\n` reaches here with one still attached — and an argLine that is only a
        // newline would otherwise skip the listing and author a rule instead.
        let args = argLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !args.isEmpty else {
            // Only the *listing* needs the rules to have arrived. Authoring below doesn't, and
            // gating it would refuse a perfectly good `/ignore bob` during the connect burst.
            guard let ignores else { return [.info(unsynced)] }
            return [.info(listing(ignores.listing(for: networkId), now: now))]
        }

        let parsed: IgnoreArgs.Parsed
        switch IgnoreArgs.parse(args, now: now) {
        case .success(let value): parsed = value
        case .failure(let failure): return [.info("/ignore: \(failure.message)")]
        }
        // Global (the default) works anywhere; `-network` names a connection the system buffer
        // doesn't have. Refusing beats quietly writing the global rule they didn't ask for.
        guard !parsed.scopeNetwork || networkId != nil else {
            return [.info("/ignore -network needs an active network — switch to a channel or DM.")]
        }
        let scope = parsed.scopeNetwork ? networkId : nil
        // `add-ignore` is an upsert, not an insert: the server matches an existing rule on
        // every dimension EXCEPT expiry and rewrites that row's `expires_at` in place
        // (`findIdenticalStmt`/`addRule`). So `/ignore -time 1h bob` followed by `/ignore bob`
        // doesn't make a second rule — it makes the hour-long mute permanent, and vice versa.
        // Saying "added" for that is how someone loses a timed rule without being told.
        // Without the rules, an add and an upsert are indistinguishable — so the receipt
        // claims neither rather than guessing "added" in the one window this command is
        // careful about everywhere else. Authoring itself stays allowed here: the rule is
        // fine, it's only our ability to describe what it did to the list that's missing.
        let verb: String
        if let listed = ignores?.listing(for: networkId) {
            verb = listed.contains { $0.scope == scope && sameRule($0.rule, parsed.rule) }
                ? "ignore updated"
                : "ignore added"
        } else {
            verb = "ignore sent"
        }
        return [.addIgnore(
            scope: scope,
            rule: parsed.rule,
            receipt: "\(verb): \(parsed.rule.summary(global: scope == nil, now: now))"
        )]
    }

    /// Whether two rules are the same one as far as the server's dedupe is concerned — every
    /// dimension but the id and the expiry, which is exactly what `findIdenticalStmt` compares
    /// and exactly what makes a re-issued `/ignore` change a rule's lifetime instead of adding
    /// a rule.
    private static func sameRule(_ lhs: IgnoreRule, _ rhs: IgnoreRule) -> Bool {
        lhs.mask == rhs.mask
            && (lhs.channels ?? []) == (rhs.channels ?? [])
            && (lhs.pattern ?? "") == (rhs.pattern ?? "")
            && lhs.patternKind == rhs.patternKind
            && lhs.levels == rhs.levels
            && lhs.isExcept == rhs.isExcept
    }

    /// `/unignore <index|mask>` — a number addresses a rule by its position in the last
    /// listing, anything else is a mask to clear.
    ///
    /// The two remove differently on purpose, matching the web: by-index is exact (it resolves
    /// to the rule's id and its bucket), while by-mask clears every rule carrying that mask,
    /// which is what makes the common `/ignore bob` → `/unignore bob` round trip work without
    /// anyone having to read a listing first.
    private static func resolveUnignore(
        argLine: String,
        networkId: Int?,
        ignores: IgnoreSet?,
        now: Date
    ) -> [CommandEffect] {
        // Run through the same tokenizer `/ignore` used to create the mask, so a mask is
        // removable in the spelling that made it: `/ignore "bob smith"` stores `bob smith`, and
        // comparing the raw arg would have matched only the unquoted form. Trimming is
        // `whitespacesAndNewlines` for the multi-line composer (see `resolveIgnore`).
        let arg = IgnoreArgs.tokenize(argLine).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !arg.isEmpty else {
            return [.info("usage: /unignore <index|mask>  (index from /ignore)")]
        }
        // Every answer below is a claim about which rules exist — "no ignore #3", "no ignore
        // with mask bob". Made against a set that hasn't arrived yet, each of them is a
        // confident denial of a rule the account really has.
        guard let ignores else { return [.info(unsynced)] }
        let listed = ignores.listing(for: networkId)

        // ASCII digits only — the web's `/^\d+$/`. `Int(_:)` alone would accept `+5` and a
        // non-ASCII digit, either of which would silently address a different rule.
        if arg.allSatisfy({ $0.isASCII && $0.isNumber }) {
            // An index too large for an Int is out of range by definition, so it reads as one
            // past the end rather than becoming a different number.
            let index = Int(arg) ?? 0
            if index >= 1, index <= listed.count {
                let item = listed[index - 1]
                return [.removeIgnore(
                    scope: item.scope,
                    id: item.rule.id,
                    mask: nil,
                    receipt: "removed ignore #\(index): \(item.rule.summary(global: item.scope == nil, now: now))"
                )]
            }
            // Not an index that exists — but numeric masks are real (bots, `*!*@1234`), and
            // the web's parser stops here, leaving a rule you can create and never name.
            // Falling through to mask matching is a deliberate divergence: an in-range index
            // still wins, so nothing that worked before changes meaning.
            if !listed.contains(where: { matchesMask($0, arg) }) {
                return [.info("/unignore: no ignore #\(arg) (see /ignore)")]
            }
        }

        // A rule that applies to anyone is stored with no mask at all (`*` normalizes to nil
        // on both sides), so there is no string for the server's `mask = ?` delete to match —
        // it can only go by number. Said plainly, because the listing prints those rules as
        // `*` and typing what you were shown is the obvious next move.
        guard arg != "*" else {
            return [.info("/unignore: a rule that applies to anyone has no mask to match — remove it by number (see /ignore).")]
        }

        // Case-insensitive exact match of the stored mask, not a glob.
        let matches = listed.filter { matchesMask($0, arg) }
        guard !matches.isEmpty else {
            return [.info("/unignore: no ignore with mask \"\(arg)\" (see /ignore)")]
        }
        // Scoped to the issuing network, not to the matches': the server's by-mask delete
        // spans the globals plus that one network, which is exactly the set just counted.
        return [.removeIgnore(
            scope: networkId,
            id: nil,
            mask: arg,
            receipt: "removed \(matches.count) ignore\(matches.count > 1 ? "s" : "") matching \"\(arg)\"."
        )]
    }

    /// Whether a listed rule's mask is the one the user typed, folded **the way the server's
    /// delete folds it**: SQLite's `COLLATE NOCASE`, which is ASCII-only and byte-exact
    /// otherwise.
    ///
    /// Deliberately not `caseInsensitiveCompare`, which is the obvious spelling and folds far
    /// wider — it treats a decomposed `café` as equal to the composed one, and `STRASSE` as
    /// equal to `straße`. Those all count a match here that the `DELETE` will not make, so the
    /// user is told a rule was removed and it is still there on the next `/ignore`. This
    /// number is a claim about what the server did, so it has to be answered in the server's
    /// terms.
    private static func matchesMask(_ item: ScopedIgnoreRule, _ arg: String) -> Bool {
        guard let mask = item.rule.mask else { return false }
        return asciiLowered(mask) == asciiLowered(arg)
    }

    /// A mask folded the way SQLite folds it: **per byte**, `A`–`Z` only.
    ///
    /// Bytes, not `Character`s, which is what makes this agree rather than merely look like it
    /// does. A grapheme cluster like `A` + combining acute is not `isASCII`, so folding by
    /// character leaves its `A` alone while `NOCASE` — which walks bytes — lowers it. That's
    /// the *inverse* of the divergence this function exists to prevent: the client would report
    /// "no ignore with that mask" for a rule the `DELETE` would have removed.
    ///
    /// Comparing the byte arrays also sidesteps Swift's canonical `==`, under which a
    /// decomposed `cafe\u{301}` equals a composed `café` and to SQLite does not.
    private static func asciiLowered(_ text: String) -> [UInt8] {
        text.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }
    }

    /// The `/ignore` listing as one block — one local line, not one per rule, so a long list
    /// arrives as a single message row rather than as N (the same shape `/commands` takes).
    private static func listing(_ ignores: [ScopedIgnoreRule], now: Date) -> String {
        let head = ignores.isEmpty
            ? ["ignore list is empty."]
            : ["ignore list (\(ignores.count)):"] + ignores.enumerated().map { index, item in
                "  \(index + 1). \(item.rule.summary(global: item.scope == nil, now: now))"
            }
        return (head + [grammar]).joined(separator: "\n")
    }

    /// What to say when the account's rules haven't reached this device yet — the connect
    /// burst hasn't finished, or the socket is down. Distinct from "you have no rules", which
    /// is what an empty set would otherwise be read as.
    private static let unsynced =
        "Your ignore rules haven't arrived yet — try again once you're connected."

    // MARK: - Relay bots (#277)

    /// `/relay` — with no arguments, the marks on this network; otherwise a mark to set or clear.
    ///
    /// Nothing is written locally, exactly as with `/ignore`: the effect asks, and the mark
    /// appears when the server's `relay-bot-updated` lands. The receipt rides on the effect so
    /// it's withheld if the verb never reached a socket.
    private static func resolveRelay(
        argLine: String,
        networkId: Int,
        relayBots: RelayBotSet?
    ) -> [CommandEffect] {
        switch RelayArgs.parse(argLine) {
        case .failure(let message):
            return [.info("/relay: \(message)")]
        case .list:
            // Only the listing needs the marks to have arrived — it's a claim about what exists,
            // and made against a set still in flight it's a confident "you have none" for an
            // account that may have several. Marking below doesn't need them and isn't gated.
            guard let relayBots else {
                return [.info("Your relay bots haven't arrived yet — try again once you're connected.")]
            }
            return [.info(relayListing(relayBots.listing(for: networkId)))]
        case .add(let nick, let pattern):
            // ⚠ A custom pattern that won't compile has to be refused HERE, at the only moment
            // anyone is looking. `RelayEnvelope.templates(for:)` deliberately doesn't fall back to
            // the built-ins for one — the user asked for a specific shape and inventing a speaker
            // by some other rule would be worse — so the mark would be stored, listed by
            // `/relay list`, and silently re-attribute nothing, forever, with a receipt that said
            // it worked. The server won't catch it either: it stores the string without reading it.
            //
            // Forgetting the braces is the whole of how this happens (`/relay add bot [Discord]
            // <nick> message`), so the refusal names them.
            if !pattern.isEmpty, RelayEnvelope.compile(pattern) == nil {
                return [.info(
                    "/relay: that pattern can't be used. It needs {nick} and {message} — {source} "
                        + "is optional — e.g. /relay add \(nick) [{source}] <{nick}> {message}. "
                        + "Leave it off entirely to use the built-in formats."
                )]
            }
            // "marked" either way, not "updated": unlike `add-ignore` — whose upsert can silently
            // convert a timed rule into a permanent one, which is why that receipt is careful —
            // re-marking a bot with a new pattern has exactly one outcome, and it's this one.
            let suffix = pattern.isEmpty ? "" : " (pattern: \(pattern))"
            return [.setRelayBot(
                networkId: networkId, nick: nick, marked: true, pattern: pattern,
                receipt: "marked \(nick) as a relay bot\(suffix)."
            )]
        case .remove(let nick):
            return [.setRelayBot(
                networkId: networkId, nick: nick, marked: false, pattern: "",
                receipt: "unmarked \(nick) as a relay bot."
            )]
        }
    }

    /// The `/relay` listing as one block, like `/ignore`'s — one message row rather than N.
    ///
    /// The empty case carries the way *out* of it. A user typing `/relay` into a channel where a
    /// bridge is talking is asking "how do I fix this", and "none" alone answers a different
    /// question than the one they have.
    private static func relayListing(_ bots: [RelayBot]) -> String {
        guard !bots.isEmpty else {
            return "No relay bots marked on this network. /relay add <nick>"
        }
        let rows = bots.map { "  \($0.nick)\($0.pattern.isEmpty ? "" : "  — \($0.pattern)")" }
        return (["relay bots (\(bots.count)):"] + rows).joined(separator: "\n")
    }

    /// The flag and level vocabulary, printed under every listing.
    ///
    /// This is the only place it's reachable. `/commands` builds its usage line from the
    /// positional `ArgSpec`s, so it can only say `/ignore [mask] [levels]` — and the grammar
    /// is irssi's, which nobody guesses: without this, `-network`, the one flag that scopes a
    /// rule to a single connection, cannot be discovered from inside the app. The web spends
    /// four cheatsheet lines on the same problem.
    private static let grammar = """
          usage: /ignore [flags] [nick|mask|#chan] [LEVELS…] — no arguments lists
          flags: -network (this network only) -except -regexp -full -pattern <text> -time <dur>
          levels: PUBLIC MSGS NOTICES ACTIONS JOINS PARTS QUITS NICKS KICKS MODES TOPICS \
        NOHIGHLIGHT NOUNREAD NONOTIFY, or ALL -PUBLIC to subtract
        """

    // MARK: - Helpers

    /// `¯\_(ツ)_/¯`, as the web's `/shrug` says it.
    private static let shrug = "¯\\_(ツ)_/¯"

    /// Whether a command's leading word names a channel, for the commands whose first argument
    /// may instead be free text: `/part [reason]`, `/topic [text]`, `/mode`. The web's
    /// `isChannelArgAmbiguous`.
    ///
    /// ⚠ `#` always does: a sentence effectively never starts with one. The other three sigils do
    /// only when this network has a buffer by that name, because `+` and `!` absolutely start
    /// sentences — `/part +brb` would part a channel "+brb", `/topic !!! down !!!` would set the
    /// topic of a channel "!!!". Commands whose first argument is never text (`/kick`, `/invite`,
    /// the mode shortcuts) ask `ChannelName.isChannelTarget` instead.
    private static func leadsWithChannel(_ token: String?, hasBuffer: (String) -> Bool) -> Bool {
        guard let token, ChannelName.isChannelTarget(token) else { return false }
        return token.hasPrefix("#") || hasBuffer(token)
    }

    /// A whole `:name:` in the gemoji character set — what the web's `reactionFromInput` would
    /// look up, closing colon optional. Left open, an emoticon isn't a name: `:D` and `:P` are
    /// too short to be one, and a nose and a letter (`:-D`, `:-p`) is a face. `:-1` and `:+1`
    /// stay names — the web turns them into 👎 and 👍.
    private static func isShortcode(_ text: String) -> Bool {
        guard text.hasPrefix(":") else { return false }
        let closed = text.count > 1 && text.hasSuffix(":")
        let name = text.dropFirst().dropLast(closed ? 1 : 0)
        if !closed, name.count == 2, name.first == "-", name.last?.isLetter == true { return false }
        return name.count >= (closed ? 1 : 2) && name.allSatisfy { char in
            char.isASCII && (char.isLetter || char.isNumber || "_+-".contains(char))
        }
    }

    /// Whether the network is known to have no +q quiet list — an unknown spec isn't.
    private static func noQuietList(_ spec: ModeSpec?) -> Bool {
        spec.map { !$0.list.contains("q") } ?? false
    }

    /// How many param-taking changes one MODE line may carry before the network's 005 says: the
    /// web's `DEFAULT_MAX_MODES`, and RFC 2812's floor.
    private static let defaultMaxModes = 3

    /// The longest MODE line the shortcuts build, in bytes: the web's `MODE_LINE_BUDGET`, which
    /// leaves room under IRC's 512 for the prefix the server relays it with. Long ban masks reach
    /// it before MODES does, and a server truncates what's past it.
    private static let modeLineBudget = 400

    /// The channel a moderation command acts on and the arguments after it: a leading channel
    /// word (any sigil — none of these commands takes free text first), else the current buffer
    /// when it's a channel, else nil.
    private static func leadingChannel(_ rest: [String], target: String) -> (String?, [String]) {
        if let first = rest.first, ChannelName.isChannelTarget(first) {
            return (first, Array(rest.dropFirst()))
        }
        return (ChannelName.isChannelTarget(target) ? target : nil, rest)
    }

    /// The mode-shortcut family (`/op`, `/ban`, …): one mode letter repeated once per target,
    /// against a leading channel arg (any sigil) or the current channel buffer. `/op a b` →
    /// `MODE #chan +oo a b`, split into as many lines as the network's MODES allows — a server
    /// drops the changes past its limit without a word. Refuses outside a channel, rather than
    /// aiming a channel mode at a DM peer.
    private static func modeShortcut(
        _ verb: String,
        letter: Character,
        adding: Bool,
        rest: [String],
        target: String,
        spec: ModeSpec?
    ) -> [CommandEffect] {
        let (channel, args) = leadingChannel(rest, target: target)
        guard let channel else {
            return [.info("usage: /\(verb) [#chan] <nick>… — no channel context")]
        }
        guard !args.isEmpty else {
            return [.info("usage: /\(verb) [#chan] <nick>…")]
        }
        let sign = adding ? "+" : "-"
        func line(_ params: [String]) -> String {
            "MODE \(channel) \(sign)\(String(repeating: letter, count: params.count)) \(params.joined(separator: " "))"
        }
        // One mask too long for a line of its own can't be split, and sending the rest without it
        // would half-apply the command — so the whole command is refused.
        if args.contains(where: { line([$0]).utf8.count > modeLineBudget }) {
            return [.info("/\(verb): one of those is too long for a MODE line")]
        }
        // A known spec with no MODES is no limit; an unknown spec is the default, as the web.
        let limit: Int? = if let spec { spec.maxModes } else { defaultMaxModes }
        var lines: [[String]] = []
        var batch: [String] = []
        for arg in args {
            let full = limit.map { batch.count >= $0 } ?? false
            if !batch.isEmpty, full || line(batch + [arg]).utf8.count > modeLineBudget {
                lines.append(batch)
                batch = []
            }
            batch.append(arg)
        }
        lines.append(batch)
        return lines.map { .raw(line: line($0)) }
    }

    /// The body of a command after its first token, interior spacing preserved — the web's
    /// `argLine.slice(first.length).trim()`. `argLine` begins with `first`. Newlines are
    /// trimmed too, as `trim()` does: `/topic #chan⏎new topic` mustn't start with one.
    private static func body(after first: String, in argLine: String) -> String {
        String(argLine.dropFirst(first.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A DM/user target: has a network, isn't a channel, isn't a `:server:`/`:system:` pseudo.
    private static func isNickTarget(_ target: String) -> Bool {
        !ChannelName.isChannelTarget(target) && !target.hasPrefix(":")
    }

    /// The person a bare `/whois` or `/ping` means in this buffer, or "" for none: a DM's peer,
    /// and a DCC chat's too.
    ///
    /// ⚠⚠ Peeled, never the buffer name. `=bob` isn't a nick, and both verbs put their argument
    /// on the IRC wire — `/ping` as a CTCP, which no server-side `=` guard covers — so the raw
    /// target here was a `PRIVMSG =bob` waiting to happen.
    private static func bufferPeer(_ target: String) -> String {
        isNickTarget(target) ? DccChat.peer(target) : ""
    }
}
