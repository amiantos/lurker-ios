// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Turns raw server JSON into typed `ServerFrame`s. The one place that knows the wire
/// format. Kinds the 1.0 foundation doesn't consume yet parse to `.ignored` rather
/// than failing. Pure and synchronous, so it runs on whatever thread the socket
/// callback arrives on.
enum FrameParser {

    /// Parse one WS text frame (discriminated by `kind`).
    static func parseWs(_ text: String) -> ServerFrame {
        guard let obj = object(from: text) else { return .ignored }
        switch obj["kind"] as? String {
        case "snapshot": return parseSnapshot(obj)
        // Carries no state of its own — its arrival *is* the message.
        case "backlog-complete": return .backlogComplete
        case "backlog": return parseBacklog(obj)
        case "history": return parseHistory(obj)
        case "irc": return parseLive(obj)
        case "read-state":
            let target = obj.string("target")
            return target.isEmpty ? .ignored : .readState(
                networkId: obj.intOrNull("networkId"),
                target: target,
                lastReadId: obj.int("lastReadId"),
                unread: obj.int("unread"),
                highlights: obj.int("highlights")
            )
        case "send-result":
            return .sendResult(
                clientId: obj.stringOrNull("clientId"),
                ok: obj.bool("ok"),
                error: obj.stringOrNull("error")
            )
        case "settings":
            // `changes` carries only what moved. An empty object is legal (the server sends
            // `changes || {}`) and simply patches nothing.
            return .settingsChanged(parseSettingValues(obj["changes"]))
        case "error":
            return .serverError(obj.string("text"))
        case "favorites-changed":
            // The FULL global order, replace wholesale — the same frame seeds the
            // connect burst, so this one handler covers seed and every correction.
            return .favoritesChanged(obj.objects("favorites").map { entry in
                FavoriteEntry(
                    networkId: entry.int("networkId"),
                    target: entry.string("target"),
                    bufferId: entry.int("bufferId")
                )
            })
        case "bookmark-updated":
            // The fan-out for a save/unsave made anywhere on the account, including this
            // device — the server echoes to every socket, so it's the one source of truth
            // and nothing renders a toggle optimistically. A zero id can't address a row.
            let messageId = obj.int("messageId")
            return messageId == 0
                ? .ignored
                : .bookmarkUpdated(messageId: messageId, saved: obj.bool("saved"))
        case "search-result":
            // A reply with no token is unaddressable — it can't be matched to the call waiting
            // for it, and `int()` would quietly read it as 0, a value no request ever carries
            // (tokens start at 1). Dropped as unparseable rather than becoming a `.searchResult`
            // nothing can consume.
            //
            // Note this is NOT the "unknown token" case, which is normal and must stay a no-op:
            // a search that already timed out, or was failed by a socket drop, can still have
            // its reply turn up afterwards. That one is correlated fine — to a call that has
            // gone.
            guard let token = obj.intOrNull("token") else { return .ignored }
            return .searchResult(token: token, page: parseSearchPage(obj))
        case "ignore-list-updated":
            // A frame with no usable `masks` array is dropped rather than read as "this scope
            // now has no rules". `objects()` answers `[]` for a missing, null or mistyped key,
            // and the store treats the payload as complete-for-that-scope — so without this
            // guard one malformed frame silently deletes every rule in the bucket, live, and
            // nothing re-seeds them short of a reconnect. A hide feature must not fail open.
            // Both siblings in this switch refuse a payload they can't trust the same way
            // (`search-result` on a missing token, `buffer-closed` on an empty target).
            //
            // The check is on the raw value, not on emptiness: `masks: []` is a legitimate
            // "the last rule was removed" and has to keep working.
            guard obj["masks"] is [Any] else { return .ignored }
            // `networkId` is nullable and its null means the GLOBAL bucket — not the system
            // buffer, which is what a null networkId means on every other frame. `intOrNull`
            // keeps the two apart; `int()` would fold global onto network 0.
            return .ignoreListUpdated(
                networkId: obj.intOrNull("networkId"),
                rules: obj.objects("masks").map(parseIgnoreRule)
            )
        case "relay-bot-updated":
            // A mark is about one connection and one nick; neither can be inferred, and a frame
            // missing either would key a mark on nothing (network 0, or the empty nick — which
            // would then "match" every nick-less line). Refused rather than folded, the same
            // posture the siblings above take toward a payload they can't trust.
            let nick = obj.string("nick")
            guard let networkId = obj.intOrNull("networkId"), !nick.isEmpty else { return .ignored }
            return .relayBotUpdated(
                networkId: networkId,
                nick: nick,
                marked: obj.bool("marked"),
                pattern: obj.string("pattern")
            )
        case "buffer-renamed":
            // Same trust posture as buffer-closed below: empty names can't
            // identify anything, so refuse rather than rename an arbitrary
            // buffer. networkId stays null-distinct for the same BufferKey
            // reason.
            let from = obj.string("from")
            let to = obj.string("to")
            return from.isEmpty || to.isEmpty
                ? .ignored
                : .bufferRenamed(
                    networkId: obj.intOrNull("networkId"),
                    from: from,
                    to: to,
                    bufferId: obj.intOrNull("bufferId"),
                    merged: obj.bool("merged"),
                    mergedFromBufferId: obj.intOrNull("mergedFromBufferId")
                )
        case "buffer-closed":
            // `networkId` is genuinely nullable here (the system buffer), so read it as
            // optional rather than defaulting to 0 — `intOrNull` keeps a null distinct from
            // network 0 the way BufferKey needs. An empty target can't identify a buffer.
            let target = obj.string("target")
            return target.isEmpty
                ? .ignored
                : .bufferClosed(networkId: obj.intOrNull("networkId"), target: target)
        default:
            return .ignored
        }
    }

    /// Parse REST `GET /api/networks` into the roster (id → name).
    static func parseNetworks(_ body: String) -> ServerFrame {
        guard let obj = object(from: body) else { return .networks([]) }
        // REST carries no live state; the WS snapshot fills state/nick in.
        let networks = obj.objects("networks").map { Network(id: $0.int("id"), name: $0.string("name", "network")) }
        return .networks(networks)
    }

    /// Parse REST `GET /api/highlights` into a page. Each item is a `MessageEvent` spread
    /// flat (so `parseEvent` reads it, same as a backlog line) plus the buffer address
    /// (`networkId`/`target`) and a resolved `networkName`. `nextBefore` is the cursor for
    /// the next older page, null at the end — carried through as `Int?` so `hasMore` can
    /// distinguish "no more" from "more, cursor 0".
    static func parseHighlights(_ body: String) -> HighlightsPage {
        guard let obj = object(from: body) else { return HighlightsPage(items: [], nextBefore: nil) }
        return HighlightsPage(
            items: obj.objects("items").map(parseFeedItem),
            nextBefore: obj.intOrNull("nextBefore")
        )
    }

    /// A WS `search-result` frame's page. Same row shape as `/api/highlights` — the server
    /// builds both from `MessageEventWithNetwork`, so one reader serves both — but a
    /// *different cursor contract*, which is the whole reason this isn't `parseHighlights`.
    ///
    /// Search answers `hasMore` and no cursor, because the cursor is derivable: matches come
    /// back newest-first by message id, so the next page is everything below the last row.
    /// Synthesizing `nextBefore` here (exactly as the web store does) is what lets a search
    /// page through `HighlightsPage` and therefore through the shared feed screen.
    ///
    /// `hasMore` with an empty `results` collapses to "no cursor": there is no id to page
    /// from, and claiming more would leave the list asking for a page it can't address.
    private static func parseSearchPage(_ obj: [String: Any]) -> HighlightsPage {
        let items = obj.objects("results").map(parseFeedItem)
        let hasMore = obj.bool("hasMore")
        return HighlightsPage(
            items: items,
            nextBefore: hasMore ? items.last?.message.id : nil
        )
    }

    /// One cross-buffer feed row: a `MessageEvent` spread flat (so `parseEvent` reads it, same
    /// as a backlog line) plus the buffer address (`networkId`/`target`) and a server-resolved
    /// `networkName`. Shared by highlights, bookmarks and search.
    private static func parseFeedItem(_ item: [String: Any]) -> HighlightItem {
        HighlightItem(
            message: parseEvent(item),
            networkId: item.intOrNull("networkId"),
            target: item.string("target"),
            networkName: item.stringOrNull("networkName")
        )
    }

    // MARK: - Private

    private static func object(from text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private static func parseSnapshot(_ obj: [String: Any]) -> ServerFrame {
        let networks = obj.objects("networks").map { network in
            NetworkSnapshot(
                id: network.int("networkId"),
                state: ConnectionState.from(network.stringOrNull("state")),
                nick: network.string("nick"),
                channels: network.objects("channels").map(parseChannel),
                peerPresence: parsePeerPresence(network["peerPresence"] as? [String: Any]),
                ignoredMasks: network.objects("ignoredMasks").map(parseIgnoreRule),
                relayBots: network.objects("relayBots").compactMap(parseRelayBot),
                away: parseAwayState(network["away"])
            )
        }
        return .snapshot(networks, globalIgnores: obj.objects("globalIgnores").map(parseIgnoreRule))
    }

    /// One stored ignore rule. Shared by the snapshot's two seeds (per-network `ignoredMasks`
    /// and the frame-level `globalIgnores`) and by `ignore-list-updated`, which is the same
    /// row shape in all three.
    ///
    /// Absent optional fields read as "unconstrained", which is what the matcher wants: no
    /// mask is anyone, no channels is everywhere, no pattern is any body. `levels` arrives
    /// already canonicalized by the server, so the irssi alias spellings never reach here.
    private static func parseIgnoreRule(_ obj: [String: Any]) -> IgnoreRule {
        IgnoreRule(
            id: obj.int("id"),
            mask: obj.stringOrNull("mask"),
            channels: obj["channels"] as? [String],
            pattern: obj.stringOrNull("pattern"),
            patternKind: IgnorePatternKind.from(obj.stringOrNull("patternKind")),
            levels: (obj["levels"] as? [String]) ?? [],
            isExcept: obj.bool("isExcept"),
            // Parsed here rather than compared as a string at match time: expiry is checked
            // once per rule per rendered row, and `Date.parse` on every one of those would be
            // the most expensive thing in the filter.
            expiresAt: ISOTime.parse(obj.stringOrNull("expiresAt"))
        )
    }

    /// One relay-bot mark (#277) — the same `{nick, pattern}` row in the snapshot's per-network
    /// `relayBots` and in a `relay-bot-updated` frame.
    ///
    /// A row with no nick addresses nobody, so it's dropped rather than becoming a mark keyed on
    /// the empty string — which would match every nick-less line the client ever renders. An
    /// absent `pattern` is the built-in formats, which is what the server stores for a bare mark.
    private static func parseRelayBot(_ obj: [String: Any]) -> RelayBot? {
        let nick = obj.string("nick")
        return nick.isEmpty ? nil : RelayBot(nick: nick, pattern: obj.string("pattern"))
    }

    /// The snapshot's `peerPresence` blob — `lowercased nick → {nick, state, stateAt,
    /// awayMessage}` — flattened to the one field the client acts on. Entries whose `state`
    /// isn't a known value (or is null) are dropped, which reads as `unknown`, exactly as a
    /// live null-state event would.
    private static func parsePeerPresence(_ blob: [String: Any]?) -> [String: PresenceState] {
        guard let blob else { return [:] }
        var out: [String: PresenceState] = [:]
        for (nick, value) in blob {
            guard let entry = value as? [String: Any],
                  let raw = entry["state"] as? String,
                  let state = PresenceState(rawValue: raw)
            else { continue }
            out[nick.lowercased()] = state
        }
        return out
    }

    /// The `away` blob — `{active, since, message, autoSet, backAt}` — shared by the network
    /// snapshot and the live `away-state` event, which carry the identical shape.
    ///
    /// A null (or missing, or mistyped) blob is nil, not a default-constructed state: the
    /// server sends `away: null` for an account with nothing on record, and inventing an
    /// `active: false` there would be a claim that the user *returned* rather than that we
    /// were never told anything. A blob carrying no readable `since` is nil for the same
    /// reason — see below.
    private static func parseAwayState(_ raw: Any?) -> AwayState? {
        guard let obj = raw as? [String: Any] else { return nil }
        // `since` is the field the whole feature hangs on — both markers are placed from it, and
        // the server itself treats it as the existence test (`away = a.since ? {…} : null`, in
        // both the snapshot and `publishAwayState`). So a blob we can't read one out of is a
        // blob no marker can be placed from, and reading it as an away with no beginning would
        // put a value in the store that nothing can use and nothing can retract.
        //
        // `active` and `autoSet` keep the file's ordinary `bool()` default. Nothing in the
        // placement logic reads either — `MessageRows` works from `since` and `backAt` alone —
        // so a defaulted `false` can't manufacture a marker: only a parsed `backAt` does that.
        guard let since = ISOTime.parse(obj.stringOrNull("since")) else { return nil }
        return AwayState(
            active: obj.bool("active"),
            message: obj.stringOrNull("message"),
            since: since,
            autoSet: obj.bool("autoSet"),
            backAt: ISOTime.parse(obj.stringOrNull("backAt"))
        )
    }

    private static func parseChannel(_ channel: [String: Any]) -> ChannelSnapshot {
        ChannelSnapshot(
            name: channel.string("name"),
            topic: channel.stringOrNull("topic"),
            members: channel.objects("members").map(parseMember)
        )
    }

    /// The server's `memberSnapshot` shape — identical on a snapshot channel, a `names`
    /// broadcast, and a `member-update` patch, so all three parse through here.
    private static func parseMember(_ member: [String: Any]) -> Member {
        Member(
            nick: member.string("nick"),
            modes: (member["modes"] as? [String]) ?? [],
            away: member.bool("away"),
            user: member.stringOrNull("user"),
            host: member.stringOrNull("host")
        )
    }

    /// Decode a REST body to a JSON object, for the callers that need a field this file has no
    /// dedicated parse for (`PATCH /api/settings` → `{values}`). Still routed through here so
    /// `JSONSerialization` stays behind the one type that knows the wire format.
    static func jsonObject(from text: String) -> [String: Any]? {
        object(from: text)
    }

    /// The `error` string from a REST failure body (`{error, key}`), when there is one. Lives
    /// here rather than at the call site because this is the one place that knows the wire
    /// format — and the server's own wording ("must be one of …", "out of range") is more use
    /// to the user than anything the caller could invent.
    static func errorMessage(from text: String) -> String? {
        object(from: text)?.stringOrNull("error")
    }

    /// A `{key: value}` blob of settings — the `values` half of bootstrap, and the `changes`
    /// of a live update. Anything whose value doesn't decode to a `SettingValue` is skipped
    /// rather than guessed at: a key we can't represent is one we also can't write back.
    static func parseSettingValues(_ raw: Any?) -> [String: SettingValue] {
        guard let object = raw as? [String: Any] else { return [:] }
        return object.reduce(into: [:]) { out, pair in
            if let value = SettingValue.from(pair.value) { out[pair.key] = value }
        }
    }

    /// A registry entry's `dependsOn` clauses (#666), if it carries any.
    ///
    /// A clause whose `in` list holds nothing this app can represent is dropped rather than
    /// kept empty: an empty value list can never match, so keeping it would permanently grey
    /// out a control on the strength of a value we simply failed to parse.
    private static func parseDependencies(_ raw: Any?) -> [SettingDependency] {
        guard let entries = raw as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            let key = entry.string("key")
            let values = ((entry["in"] as? [Any]) ?? []).compactMap(SettingValue.from)
            guard !key.isEmpty, !values.isEmpty else { return nil }
            return SettingDependency(key: key, values: values)
        }
    }

    /// `GET /api/settings/bootstrap` → `{registry, values}`.
    ///
    /// The registry is an ARRAY of options on the wire (it's `REGISTRY` verbatim), keyed here
    /// so lookups are by key rather than a linear scan per read.
    static func parseSettingsBootstrap(_ text: String) -> ServerFrame {
        guard let obj = object(from: text) else { return .ignored }
        var registry: [String: SettingOption] = [:]
        for entry in (obj["registry"] as? [[String: Any]]) ?? [] {
            let key = entry.string("key")
            guard !key.isEmpty, let type = SettingType(rawValue: entry.string("type")) else { continue }
            // A registry entry with no usable default is unusable: `effective` would return nil
            // for an unset key and every caller would silently fall through to its own
            // fallback, which is the drift this whole layer exists to prevent.
            guard let defaultValue = entry["default"].flatMap(SettingValue.from) else { continue }
            registry[key] = SettingOption(
                key: key,
                label: entry.string("label"),
                description: entry.string("description"),
                type: type,
                default: defaultValue,
                choices: (entry["choices"] as? [String]) ?? [],
                choiceLabels: (entry["choiceLabels"] as? [String: String]) ?? [:],
                min: entry.intOrNull("min"),
                max: entry.intOrNull("max"),
                dependsOn: parseDependencies(entry["dependsOn"])
            )
        }
        return .settingsBootstrap(registry: registry, values: parseSettingValues(obj["values"]))
    }

    private static func parseBacklog(_ obj: [String: Any]) -> ServerFrame {
        let target = obj.string("target")
        if target.isEmpty { return .ignored }
        let networkId = obj.intOrNull("networkId")
        let events = obj.objects("events")
        // A shell is `events: []` + `hasMoreOlder: true` — the "unhydrated, fetch on
        // open" marker. Any real events, or a frame that isn't claiming more older,
        // means we have this buffer's history. Read `hasMoreOlder` once with a `true`
        // fallback (matching Buffer's default): if a server ever omits it on an empty
        // frame, treating the buffer as a shell (→ fetch) is safe; the `false` fallback
        // would mislabel it hydrated and it would render empty forever.
        let hasMoreOlder = obj.bool("hasMoreOlder", true)
        let hydrated = !events.isEmpty || !hasMoreOlder
        // For a *network* buffer, only a resume slice carries a `reset` field. reset:false
        // means "these are just the events past ?since" → append; reset:true (oversized
        // gap) and a plain full/latest backlog (no field) → replace.
        //
        // The system buffer is the exception, and reading it the same way corrupts it: the
        // server's `buildSystemBacklog` hardcodes `reset: false` on EVERY connect, because
        // it always ships a full latest slice and expects the client to reconcile it — it
        // is never a resume delta. Appending it instead would (a) splice the whole history
        // *after* any live system line that beat the backlog in, and (b) leave a permanent
        // hole when a reconnect gap exceeds the server's slice cap. Replacing is what the
        // server means, and the replace path already preserves live events past the tail.
        let append = networkId != nil && obj.has("reset") && !obj.bool("reset")
        let buffer = Buffer(
            networkId: networkId,
            target: target,
            kind: BufferKind.of(networkId: networkId, target: target),
            unread: obj.int("unread"),
            highlights: obj.int("highlights"),
            lastReadId: obj.int("lastReadId"),
            joined: obj.bool("joined"),
            hydrated: hydrated,
            // Read from the FIELD'S PRESENCE, not its value: `int()` reads a missing
            // `lastReadId` as 0, which is also a legitimate "read nothing". Only a frame that
            // actually carried the pointer may claim to have stated it — see
            // `Buffer.readStateKnown`.
            readStateKnown: obj.has("lastReadId"),
            hasMoreOlder: hasMoreOlder,
            // The connect burst doubles as the id directory (§5.2): every
            // backlog frame carries the buffer's stable id.
            bufferId: obj.intOrNull("bufferId")
        )
        return .backlog(buffer: buffer, messages: events.map(parseEvent), hydrated: hydrated, append: append)
    }

    private static func parseLive(_ obj: [String: Any]) -> ServerFrame {
        // `peer-presence` is network-scoped state routed by `nick`, not a buffer line — its
        // `:server:<id>` target is only a carrier. Handle it before the target guard below so
        // the presence handler never depends on an unrelated field: no id, nothing to render,
        // and `state` may be null → nil → `unknown`.
        if obj.string("type") == "peer-presence" {
            guard let networkId = obj.intOrNull("networkId") else { return .ignored }
            let nick = obj.string("nick")
            if nick.isEmpty { return .ignored }
            return .peerPresence(
                networkId: networkId,
                nick: nick,
                state: PresenceState(rawValue: obj.string("state"))
            )
        }
        // `away-state` is network-scoped state like `peer-presence`, and its `:server:<id>`
        // target is the same kind of carrier — so it's handled above the target guard too,
        // and for the extra reason that its payload is legitimately *null*: an account with
        // no away on record sends `away: null`, which is a value to store rather than a frame
        // to drop.
        if obj.string("type") == "away-state" {
            guard let networkId = obj.intOrNull("networkId") else { return .ignored }
            return .awayState(networkId: networkId, away: parseAwayState(obj["away"]))
        }
        let target = obj.string("target")
        if target.isEmpty { return .ignored }
        // `channel-topic` rides the `irc` kind like everything else, but it isn't an event
        // in the sense the rest of this function means: no id, nothing to render, and its
        // payload is in `topic` rather than `text`. Left to `parseEvent` it would become an
        // `.other` Message appended to the buffer, carrying the topic in a field nothing
        // reads.
        if obj.string("type") == "channel-topic" {
            return .channelTopic(
                networkId: obj.intOrNull("networkId"),
                target: target,
                topic: obj.stringOrNull("topic")
            )
        }
        // `names` and `member-update` are state-only for the same reason as
        // `channel-topic`: no id, nothing to render, payload in fields `parseEvent`
        // doesn't read. Left to fall through they'd become `.other` Messages that
        // carry the member data in no field at all.
        if obj.string("type") == "names" {
            return .channelMembers(
                networkId: obj.intOrNull("networkId"),
                target: target,
                members: obj.objects("members").map(parseMember)
            )
        }
        // `typing` is ephemeral state like the three around it — no id, nothing to render —
        // and its payload lives in `state`, which `parseEvent` doesn't read. Note this sits
        // BELOW the target guard: unlike `peer-presence`, a typing tag is meaningless without
        // knowing which conversation it's about.
        if obj.string("type") == "typing" {
            let nick = obj.string("nick")
            // Nobody to attribute it to. (The server always sends one; a malformed frame
            // shouldn't become an entry keyed on the empty string.)
            if nick.isEmpty { return .ignored }
            return .typing(
                networkId: obj.intOrNull("networkId"),
                target: target,
                nick: nick,
                activity: TypingActivity.from(obj.stringOrNull("state")),
                userhost: obj.stringOrNull("userhost")
            )
        }
        if obj.string("type") == "member-update" {
            // A patch with no nick has nobody to apply to.
            guard let member = obj["member"] as? [String: Any], !member.string("nick").isEmpty
            else { return .ignored }
            return .memberUpdate(
                networkId: obj.intOrNull("networkId"),
                target: target,
                member: parseMember(member)
            )
        }
        return .live(networkId: obj.intOrNull("networkId"), target: target, message: parseEvent(obj))
    }

    private static func parseHistory(_ obj: [String: Any]) -> ServerFrame {
        let target = obj.string("target")
        if target.isEmpty { return .ignored }
        let mode = HistoryMode(rawValue: obj.string("mode")) ?? .before
        // `hasMore` is a legacy alias for `hasMoreOlder`; prefer the explicit field.
        return .history(
            networkId: obj.intOrNull("networkId"),
            target: target,
            events: obj.objects("events").map(parseEvent),
            mode: mode,
            hasMoreOlder: obj.bool("hasMoreOlder", obj.bool("hasMore")),
            hasMoreNewer: obj.bool("hasMoreNewer")
        )
    }

    /// MessageEvent → domain `Message`. Events are spread flat on the frame, so the
    /// same reader handles both a backlog array element and a live `irc` frame.
    ///
    /// `level` and `originNetworkId` are only ever set on system-buffer lines, and are
    /// nil everywhere else — severity there is a sibling field, not a `type`.
    private static func parseEvent(_ event: [String: Any]) -> Message {
        let time = event.stringOrNull("time")
        let type = EventType.from(event.stringOrNull("type"))
        return Message(
            id: event.int("id"),
            type: type,
            nick: event.stringOrNull("nick"),
            text: event.stringOrNull("text"),
            isSelf: event.bool("self"),
            time: time,
            date: ISOTime.parse(time),
            matched: event.bool("matched"),
            level: type == .system ? SystemLevel.from(event.stringOrNull("level")) : nil,
            // Gated like `level`, matching the server: `systemLineToEvent` is the only
            // producer of this field and only ever builds `type: "system"` events, so
            // reading it anywhere else would be inventing a meaning the wire doesn't have.
            originNetworkId: type == .system ? event.intOrNull("originNetworkId") : nil,
            // The server's `extractExtras` spreads these onto the event for exactly one
            // type each — `newNick` on nick, `kicked` on kick, `invited` on invite, `modes`
            // on mode, `newIdent`/`newHost` on chghost, `account` on join. Reading them
            // unconditionally is harmless (they're absent otherwise), and the renderer only
            // reaches for the one its type implies.
            newNick: event.stringOrNull("newNick"),
            kicked: event.stringOrNull("kicked"),
            invited: event.stringOrNull("invited"),
            modes: event.objects("modes").map { ModeChange(mode: $0.string("mode"), param: $0.stringOrNull("param")) },
            newIdent: event.stringOrNull("newIdent"),
            newHost: event.stringOrNull("newHost"),
            // Not an extra — a real column on the messages table, so it survives backlog for
            // every event type that had one (`server/db/messages.ts:157`).
            userhost: event.stringOrNull("userhost"),
            account: event.stringOrNull("account"),
            // Absent means unsaved — the server omits the field rather than sending false,
            // since nearly every row in every backlog is unsaved. See Message.bookmarked
            // for why the store's id set, not this, is what the UI reads.
            bookmarked: event.bool("bookmarked")
        )
    }
}
