// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// A parsed, typed update from the server — REST or WS — for the store to fold in.
/// Parsing the raw JSON into these here keeps the JSON layer an implementation detail
/// the store and UI never see.
enum ServerFrame: Equatable, Sendable {
    /// REST `GET /api/networks`: the roster (names live here, not in the snapshot).
    case networks([Network])

    /// WS `snapshot`: live per-network state + joined channels and their members.
    ///
    /// **Not authoritative for which buffers exist.** Its per-network `channels` is empty for
    /// every network without a live connection, and is read before auto-rejoin JOINs land even
    /// for one that has it. DMs and `:server:` logs aren't in it at all — they arrive as
    /// separate `backlog` frames afterwards. Use `backlogComplete` to know the burst is done.
    case snapshot([NetworkSnapshot])

    /// WS `backlog-complete`: the terminal frame of a snapshot burst (lurker #635).
    ///
    /// The only frame that says "that's all of it". The server sends it last on every
    /// snapshot — connect, in-band resync, fresh-network re-emit — and deliberately *not* at
    /// all if the burst throws partway, since a truncated snapshot has proved nothing about
    /// the buffers it never reached. So it means "the roster you have is the whole roster",
    /// which is exactly what an empty list needs before it can claim to be empty.
    case backlogComplete

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

    /// WS `contacts-snapshot`: the whole friends list, sent in the connect burst. Replaces
    /// whatever the store held (a reconnect re-sends it wholesale).
    case contactsSnapshot([Contact])

    /// WS `contact-updated`: one friend created or edited, fanned out to every device so the
    /// list stays identical whether the edit came from this phone, the browser, or an agent.
    /// Upsert by id.
    case contactUpdated(Contact)

    /// WS `contact-deleted`: a friend removed. Drop it by id.
    case contactDeleted(Int)

    /// WS `buffer-closed`: the user closed this buffer — from *any* of their devices.
    /// Drop it from the model entirely: closed is absent (lurker `CLIENT_PROTOCOL.md` §9.1).
    ///
    /// This is the only buffer-lifecycle frame that needs a handler, and it's the only one
    /// that travels alone. `buffer-opened` and `buffer-reopened` both arrive alongside
    /// something that already materializes the buffer — an `open-buffer` reply ships a
    /// `backlog` with it, and a reopen is caused by an event that arrives as a normal `irc`
    /// frame. Closing has no such companion, which is exactly why its absence was invisible:
    /// opening a buffer on the web propagated here fine, closing one silently didn't, and the
    /// stale row sat in the list until the app was relaunched.
    ///
    /// Dropping rather than flagging is deliberate and matches the web client: the server
    /// keeps the buffer's history, so a reopen restores it in full and there is nothing local
    /// worth preserving. `Buffer.state` has no `closed` case for the same reason.
    case bufferClosed(networkId: Int?, target: String)

    /// A `peer-presence` ephemeral (rides `irc`, `type:"peer-presence"`, network-scoped via a
    /// `:server:<id>` target): a watched nick changed state. `state` is nil when the server
    /// reports no known state, which the store reads as `unknown`.
    case peerPresence(networkId: Int, nick: String, state: PresenceState?)

    /// A `typing` ephemeral (rides `irc`, `type:"typing"`): a peer's `+typing` tag, scoped to
    /// the channel or DM they're composing in. `activity` is nil for `done` and for anything
    /// unrecognized, which the store reads as "stop showing them".
    ///
    /// Our *own* typing never arrives here: under `echo-message` the server sees its own
    /// TAGMSG reflect back and drops it, case-folded, before publishing
    /// (`ircConnection.ts:2621`). So the client deliberately does not re-check for self —
    /// that verdict has an owner, and duplicating it would just be a second place to get the
    /// case-folding wrong.
    case typing(
        networkId: Int?,
        target: String,
        nick: String,
        activity: TypingActivity?,
        userhost: String?
    )

    /// REST `GET /api/settings/bootstrap`: the registry plus the user's *stored* values.
    /// Defaults are not merged in — see `Settings.effective`.
    case settingsBootstrap(registry: [String: SettingOption], values: [String: SettingValue])

    /// WS `settings`: the keys that just changed, fanned out to every device (including the
    /// echo of this client's own `PATCH`). A patch, never a full set.
    case settingsChanged([String: SettingValue])

    /// The `{values}` a REST reply carries (`PATCH /api/settings`) — the user's complete
    /// stored set, which REPLACES what we hold rather than merging into it. See
    /// `Settings.replaceValues`: a key set back to its default is dropped server-side, so it
    /// comes back as an absence that a merge would never notice.
    case settingsValues([String: SettingValue])

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
    /// Watched-peer presence for this network, `lowercased nick → state`. The connect-time
    /// seed the live `peer-presence` events then patch. Defaulted so the many existing
    /// snapshot call sites that predate presence don't have to name it.
    var peerPresence: [String: PresenceState] = [:]
}

struct ChannelSnapshot: Equatable, Sendable {
    let name: String
    let topic: String?
    let members: [Member]
}
