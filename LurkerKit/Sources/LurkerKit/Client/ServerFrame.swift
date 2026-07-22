// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// A parsed, typed update from the server — REST or WS — for the store to fold in.
/// Parsing the raw JSON into these here keeps the JSON layer an implementation detail
/// the store and UI never see.
enum ServerFrame: Equatable, Sendable {
    /// REST `GET /api/networks`: the roster (names live here, not in the snapshot).
    case networks([Network])

    /// WS `snapshot`: live per-network state + joined channels and their members.
    case snapshot([NetworkSnapshot])

    /// WS `backlog`: a buffer, plus its history when `hydrated`. A shell arrives
    /// unhydrated with no events (the "fetch on open" marker).
    ///
    /// `append` distinguishes a `?since=` resume slice that carries only the gap
    /// (`reset:false` → append it) from a full/latest backlog or an oversized-gap reset
    /// (`reset:true` or no `reset` field → replace wholesale). Getting this wrong
    /// silently wipes pre-gap history the moment resume (#4) starts sending `?since`.
    case backlog(buffer: Buffer, messages: [Message], hydrated: Bool, append: Bool)

    /// WS `irc`: one live event, its fields spread flat on the frame.
    case live(networkId: Int?, target: String, message: Message)

    /// WS `history`: a paginated slice for an already-open buffer (distinct from
    /// `backlog`, which is connect-time / open-buffer hydration). `mode` decides how the
    /// store splices it in — `before` prepends, `after` appends, `latest`/`around` replace.
    /// `events` is always oldest-first.
    case history(
        networkId: Int?,
        target: String,
        events: [Message],
        mode: HistoryMode,
        hasMoreOlder: Bool,
        hasMoreNewer: Bool
    )

    /// A `channel-topic` event: RPL_TOPIC on join, i.e. "here's the topic" rather than
    /// "someone changed it". Ephemeral and silent — it carries no id and prints no line,
    /// which is why it's lifted out of `irc` into its own frame instead of arriving as a
    /// `Message` nothing would render. A topic *change* is a `topic` event and stays a
    /// message, because it's also something the channel said.
    case channelTopic(networkId: Int?, target: String, topic: String?)

    /// A `names` event: the channel's full member list, replacing whatever we hold. The
    /// server sends it on our own join and re-broadcasts it whenever it re-learns the
    /// list wholesale (a prefix-mode change, a WHO ident/host backfill, an away flip via
    /// away-notify). Ephemeral and silent, like `channelTopic` — state, not a line.
    case channelMembers(networkId: Int?, target: String, members: [Member])

    /// A `member-update` event: one member's current snapshot, patched onto the list in
    /// place. The server's incremental alternative to re-broadcasting `names` for a
    /// one-nick edit (a chghost, an account change). Also ephemeral and silent.
    case memberUpdate(networkId: Int?, target: String, member: Member)

    /// WS `read-state`: server-authoritative read counts for a buffer, broadcast to all of
    /// the user's devices (after a mark-read, or any countable event). The client mirrors
    /// these onto the buffer — it never derives unread/highlight counts locally.
    case readState(networkId: Int?, target: String, lastReadId: Int, unread: Int, highlights: Int)

    /// WS `send-result`: ack for a send/action/notice, keyed by the client's clientId.
    case sendResult(clientId: String?, ok: Bool, error: String?)

    /// WS `error`.
    case serverError(String)

    /// A 401 mid-session (REST or the WS upgrade): the token expired or was revoked
    /// from another device. The owner drops to sign-in rather than a dead-end (#3).
    case unauthorized

    /// Socket opened. Reconnect/resume is #4.
    case socketOpen

    /// Socket closed or failed.
    case socketClosed(reason: String?, code: Int?)

    /// A frame we parse but the 1.0 foundation doesn't act on yet.
    case ignored
}

/// The four `history` request modes. `before`/`after` page older/newer, `around` jumps
/// to a message, `latest` returns to the live tail. See the server's `history` verb.
public enum HistoryMode: String, Equatable, Sendable {
    case before
    case after
    case around
    case latest
}

/// The per-network live view from the WS `snapshot` (no `name` — see `.networks`).
struct NetworkSnapshot: Equatable, Sendable {
    let id: Int
    let state: ConnectionState
    let nick: String
    let channels: [ChannelSnapshot]
}

struct ChannelSnapshot: Equatable, Sendable {
    let name: String
    let topic: String?
    let members: [Member]
}
