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
    /// `now` is likewise injected, for `/ignore -time` and for lapsed rules.
    public static func parse(
        _ input: String,
        networkId: Int?,
        target: String,
        ignores: IgnoreSet? = .empty,
        relayBots: RelayBotSet? = .empty,
        now: Date = Date()
    ) -> ParsedInput {
        // The composer trims before it hands text over, but be total about it anyway.
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
        let argLine = String(body.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
        let rest = argLine.isEmpty
            ? []
            : argLine.split(whereSeparator: { $0.isWhitespace }).map(String.init)

        return .command(resolve(
            verb: verb, fullBody: body, argLine: argLine, rest: rest,
            networkId: networkId, target: target, ignores: ignores, relayBots: relayBots, now: now
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
        case "away":
            // Empty message clears away. User-scoped — no network attached.
            return [.away(message: argLine)]
        case "back":
            return [.back]
        // Ignore rules are global by default, so both verbs run without a network — the system
        // buffer can list them and write them. Only `-network` needs a connection, and that's
        // checked where it's read.
        case "ignore":
            return resolveIgnore(argLine: argLine, networkId: networkId, ignores: ignores, now: now)
        case "unignore":
            return resolveUnignore(argLine: argLine, networkId: networkId, ignores: ignores, now: now)
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
            return [.info("/\(verb) needs an active network — switch to a channel or DM first.")]
        }

        switch verb {
        // Messaging
        case "me":
            return argLine.isEmpty ? [] : [.action(target: target, text: chatBody(argLine))]
        case "slap":
            guard let who = rest.first else { return [.info("usage: /slap <nick>")] }
            return [.action(target: target, text: "slaps \(who) around a bit with a large trout")]
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
            let who = rest.first ?? (isNickTarget(target) ? target : "")
            guard !who.isEmpty else { return [.info("usage: /ping <nick>")] }
            return [.ctcp(target: who, type: "PING", args: "")]

        // Channels & buffers
        case "join":
            // A bare `/join` is a no-op, like the web (it just keeps the buffer you're in).
            guard let first = rest.first else { return [] }
            let key = rest.count > 1 ? rest[1] : nil
            return [.join(channel: ChannelName.ensurePrefix(first), key: key)]
        case "part", "leave":
            // `/part [reason]` leaves the current channel; `/part <#chan> [reason]` leaves a
            // named one. Consistent with /kick and /topic: a leading channel sigil (`#`/`&`)
            // marks a channel, anything else is a parting reason for the current channel — so
            // `/part heading out` says goodbye here rather than parting a channel "heading".
            let partChannel: String?
            let partReason: String
            if let first = rest.first, ChannelName.isChannelTarget(first) {
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
        case "topic":
            // `/topic` reads the current channel's topic; `/topic text` sets it; a leading
            // `#chan` retargets. Interior spacing of the body is preserved by slicing.
            let channel: String
            let bodyText: String
            if let first = rest.first, ChannelName.isChannelTarget(first) {
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
            let who = rest.first ?? (isNickTarget(target) ? target : "")
            guard !who.isEmpty else { return [.info("usage: /whois <nick>")] }
            return [.showProfile(nick: who)]
        case "invite":
            guard let who = rest.first else { return [.info("usage: /invite <nick> [channel]")] }
            // The channel defaults to the current buffer, but only if that's a channel — an
            // /invite from a DM with no explicit channel would otherwise aim at the peer nick.
            let channel = rest.count > 1 ? rest[1] : (ChannelName.isChannelTarget(target) ? target : nil)
            guard let channel else {
                return [.info("usage: /invite <nick> [channel] — no channel context")]
            }
            return [.raw(line: "INVITE \(who) \(channel)")]

        // Moderation
        case "kick":
            // `/kick <nick> [reason]` in a channel, or `/kick <#chan> <nick> [reason]` anywhere.
            let channel: String?
            let who: String?
            let reason: String
            if let first = rest.first, ChannelName.isChannelTarget(first) {
                channel = first
                who = rest.count > 1 ? rest[1] : nil
                reason = rest.dropFirst(2).joined(separator: " ")
            } else {
                channel = ChannelName.isChannelTarget(target) ? target : nil
                who = rest.first
                reason = rest.dropFirst().joined(separator: " ")
            }
            guard let channel else {
                return [.info("usage: /kick [#chan] <nick> [reason] — no channel context")]
            }
            guard let who else { return [.info("usage: /kick [#chan] <nick> [reason]")] }
            let trailer = reason.isEmpty ? "" : " :\(reason)"
            return [.raw(line: "KICK \(channel) \(who)\(trailer)")]
        case "mode":
            // `/mode <flags>` applies to the current channel; `/mode <target> <flags…>` is
            // explicit. A leading `+`/`-` in a channel buffer is the flags-only form.
            guard let first = rest.first else { return [.info("usage: /mode [target] <flags> [args]")] }
            if (first.hasPrefix("+") || first.hasPrefix("-")), ChannelName.isChannelTarget(target) {
                return [.raw(line: "MODE \(target) \(rest.joined(separator: " "))")]
            }
            return [.raw(line: "MODE \(argLine)")]
        case "op": return modeShortcut(verb, letter: "o", adding: true, rest: rest, target: target)
        case "deop": return modeShortcut(verb, letter: "o", adding: false, rest: rest, target: target)
        case "voice": return modeShortcut(verb, letter: "v", adding: true, rest: rest, target: target)
        case "devoice": return modeShortcut(verb, letter: "v", adding: false, rest: rest, target: target)
        case "halfop": return modeShortcut(verb, letter: "h", adding: true, rest: rest, target: target)
        case "dehalfop": return modeShortcut(verb, letter: "h", adding: false, rest: rest, target: target)
        case "ban": return modeShortcut(verb, letter: "b", adding: true, rest: rest, target: target)
        case "unban": return modeShortcut(verb, letter: "b", adding: false, rest: rest, target: target)
        case "quiet": return modeShortcut(verb, letter: "q", adding: true, rest: rest, target: target)
        case "unquiet": return modeShortcut(verb, letter: "q", adding: false, rest: rest, target: target)

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

        // App
        case "relay":
            // Below the network gate above: a mark is per-(network, nick), so there is no
            // sensible answer to `/relay` in the system buffer.
            return resolveRelay(argLine: argLine, networkId: networkId, relayBots: relayBots)

        // Network lifecycle — deferred to network management (#11). Intercepted rather than
        // left to the raw fallback, where `/quit` would send a real IRC QUIT.
        case "quit", "reconnect", "connect", "disconnect", "server":
            return [.info("Connecting and disconnecting networks isn't in the app yet — it's coming with network management.")]

        default:
            // Anything unrecognized goes raw, exactly as the web's `default`. The original
            // casing is preserved: `line.slice(1)`.
            return [.raw(line: fullBody.trimmingCharacters(in: .whitespaces))]
        }
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

    /// The mode-shortcut family (`/op`, `/ban`, …): one mode letter repeated once per target,
    /// against a leading channel arg (`#`/`&`) or the current channel buffer. `/op a b` →
    /// `MODE #chan +oo a b`. Refuses outside a channel, rather than aiming a channel mode at
    /// a DM peer.
    private static func modeShortcut(
        _ verb: String,
        letter: Character,
        adding: Bool,
        rest: [String],
        target: String
    ) -> [CommandEffect] {
        var channel: String? = ChannelName.isChannelTarget(target) ? target : nil
        var args = rest
        if let first = args.first, ChannelName.isChannelTarget(first) {
            channel = first
            args.removeFirst()
        }
        guard let channel else {
            return [.info("usage: /\(verb) [#chan] <nick>… — no channel context")]
        }
        guard !args.isEmpty else {
            return [.info("usage: /\(verb) [#chan] <nick>…")]
        }
        let sign = adding ? "+" : "-"
        let letters = String(repeating: letter, count: args.count)
        return [.raw(line: "MODE \(channel) \(sign)\(letters) \(args.joined(separator: " "))")]
    }

    /// The body of a command after its first token, interior spacing preserved — the web's
    /// `argLine.slice(first.length).trim()`. `argLine` begins with `first`.
    private static func body(after first: String, in argLine: String) -> String {
        String(argLine.dropFirst(first.count)).trimmingCharacters(in: .whitespaces)
    }

    /// A DM/user target: has a network, isn't a channel, isn't a `:server:`/`:system:` pseudo.
    private static func isNickTarget(_ target: String) -> Bool {
        !ChannelName.isChannelTarget(target) && !target.hasPrefix(":")
    }
}
