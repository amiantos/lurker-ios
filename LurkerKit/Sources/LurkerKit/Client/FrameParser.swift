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
        case "contacts-snapshot":
            return .contactsSnapshot(obj.objects("contacts").map(parseContact))
        case "contact-updated":
            guard let contact = obj["contact"] as? [String: Any] else { return .ignored }
            return .contactUpdated(parseContact(contact))
        case "contact-deleted":
            return .contactDeleted(obj.int("contactId"))
        case "bookmark-updated":
            // The fan-out for a save/unsave made anywhere on the account, including this
            // device — the server echoes to every socket, so it's the one source of truth
            // and nothing renders a toggle optimistically. A zero id can't address a row.
            let messageId = obj.int("messageId")
            return messageId == 0
                ? .ignored
                : .bookmarkUpdated(messageId: messageId, saved: obj.bool("saved"))
        case "search-result":
            return .searchResult(token: obj.int("token"), page: parseSearchPage(obj))
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
                peerPresence: parsePeerPresence(network["peerPresence"] as? [String: Any])
            )
        }
        return .snapshot(networks)
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

    /// A `ContactRecord` → domain `Contact`, shared by the snapshot list and the
    /// `contact-updated` echo. Targets missing a nick are still carried through — the server
    /// won't send one, and dropping fields silently would mask a contract drift.
    private static func parseContact(_ obj: [String: Any]) -> Contact {
        Contact(
            id: obj.int("id"),
            displayName: obj.string("displayName"),
            notifyOnline: obj.bool("notifyOnline"),
            targets: obj.objects("targets").map { target in
                ContactTarget(
                    networkId: target.int("networkId"),
                    nick: target.string("nick"),
                    isPrimary: target.bool("isPrimary")
                )
            }
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
            hasMoreOlder: hasMoreOlder
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
