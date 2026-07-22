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
        case "error":
            return .serverError(obj.string("text"))
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
                channels: network.objects("channels").map(parseChannel)
            )
        }
        return .snapshot(networks)
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
            // on mode. Reading them unconditionally is harmless (they're absent otherwise),
            // and the renderer only reaches for the one its type implies.
            newNick: event.stringOrNull("newNick"),
            kicked: event.stringOrNull("kicked"),
            invited: event.stringOrNull("invited"),
            modes: event.objects("modes").map { ModeChange(mode: $0.string("mode"), param: $0.stringOrNull("param")) }
        )
    }
}
