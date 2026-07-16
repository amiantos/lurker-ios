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
            members: channel.objects("members").map { member in
                Member(
                    nick: member.string("nick"),
                    modes: (member["modes"] as? [String]) ?? [],
                    away: member.bool("away"),
                    user: member.stringOrNull("user"),
                    host: member.stringOrNull("host")
                )
            }
        )
    }

    private static func parseBacklog(_ obj: [String: Any]) -> ServerFrame {
        let target = obj.string("target")
        if target.isEmpty { return .ignored }
        let networkId = obj.intOrNull("networkId")
        let events = obj.objects("events")
        // A shell is `events: []` + `hasMoreOlder: true` — the "unhydrated, fetch on
        // open" marker. Any real events, or a frame that isn't claiming more older,
        // means we have this buffer's history.
        let hydrated = !events.isEmpty || !obj.bool("hasMoreOlder")
        // Only a resume slice carries a `reset` field. reset:false means "these are
        // just the events past ?since" → append; reset:true (oversized gap) and a plain
        // full/latest backlog (no field) → replace.
        let append = obj.has("reset") && !obj.bool("reset")
        let buffer = Buffer(
            networkId: networkId,
            target: target,
            kind: BufferKind.of(networkId: networkId, target: target),
            unread: obj.int("unread"),
            highlights: obj.int("highlights"),
            lastReadId: obj.int("lastReadId"),
            joined: obj.bool("joined"),
            hydrated: hydrated,
            hasMoreOlder: obj.bool("hasMoreOlder")
        )
        return .backlog(buffer: buffer, messages: events.map(parseEvent), hydrated: hydrated, append: append)
    }

    private static func parseLive(_ obj: [String: Any]) -> ServerFrame {
        let target = obj.string("target")
        if target.isEmpty { return .ignored }
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
    private static func parseEvent(_ event: [String: Any]) -> Message {
        Message(
            id: event.int("id"),
            type: EventType.from(event.stringOrNull("type")),
            nick: event.stringOrNull("nick"),
            text: event.stringOrNull("text"),
            isSelf: event.bool("self"),
            time: event.stringOrNull("time"),
            matched: event.bool("matched")
        )
    }
}
