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
    ///
    /// `globalIgnores` is the un-scoped half of the ignore rules (lurker #350) — rules that
    /// apply on every network, so they belong to no network blob. Spelled out as its own
    /// value rather than hidden in a default because a snapshot that dropped it would leave
    /// the most common kind of rule silently inert until the next time one was edited.
    case snapshot([NetworkSnapshot], globalIgnores: [IgnoreRule])

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
    ///
    /// `speakers` is nil when the frame didn't carry the field at all, which the wire treats as
    /// different from an empty list: a shell deliberately omits it (`wsHub.ts`'s
    /// `buildBufferShell`) precisely so a client that *replaces* on this field can't be made to
    /// wipe a map it already holds. This client merges either way (`ChatState.seedSpeakers`), so
    /// both spellings are a no-op here — the optionality mirrors the wire rather than branching
    /// behavior, and it's the honest shape for a field a server may simply not send.
    case backlog(
        buffer: Buffer, messages: [Message], hydrated: Bool, append: Bool, speakers: [Speaker]?
    )

    /// WS `irc`: one live event, its fields spread flat on the frame.
    case live(networkId: Int?, target: String, message: Message)

    /// WS `history`: a paginated slice for an already-open buffer (distinct from
    /// `backlog`, which is connect-time / open-buffer hydration). `mode` decides how the
    /// store splices it in — `before` prepends, `after` appends, `latest`/`around` replace.
    /// `events` is always oldest-first.
    ///
    /// Every history reply carries `speakers` (see the `backlog` note for why it's optional
    /// anyway). This is the *primary* way the map loads: a fresh connect ships shells, so a
    /// buffer's first real speaker list arrives with the `latest` fetch its first open makes.
    case history(
        networkId: Int?,
        target: String,
        events: [Message],
        mode: HistoryMode,
        hasMoreOlder: Bool,
        hasMoreNewer: Bool,
        speakers: [Speaker]?
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

    /// An `own-nick` event: *our* nick on this network changed — by `/nick`, or because
    /// services renamed us. Network-scoped and target-less, like `peer-presence`.
    ///
    /// Silent by design: the visible line is the ordinary `nick` event fanned out to each
    /// shared channel, and this frame is only the state behind it. Without it `Network.nick`
    /// is whatever the last connect snapshot said, and everything that asks "is this me?"
    /// — the `.smart` tier's own-churn exemption (#63), the member list's self marking,
    /// nick-completion's exclusion of ourselves — answers with a nick we no longer have.
    case ownNick(networkId: Int, nick: String)

    /// A `state` event: this network's connection moved (`connecting` → `connected`, a drop
    /// to `disconnected`, a `reconnecting` backoff).
    ///
    /// The server publishes one on every transition, including a re-assertion of the state
    /// it was already in, precisely so a client that attached late is never wrong. Nothing
    /// else carries this: the connect `snapshot` states each network's connection once, and
    /// without this frame that value stands for the whole session — every status light
    /// frozen at whatever was true when the socket opened.
    ///
    /// `nick` is nil except on the connect transition, where the server sends it alongside.
    /// Nil means "unchanged", never "empty" — blanking `Network.nick` on a disconnect would
    /// break every "is this me?" test the way a missing `own-nick` does.
    case networkState(networkId: Int, state: ConnectionState, nick: String?)

    /// WS `read-state`: server-authoritative read counts for a buffer, broadcast to all of
    /// the user's devices (after a mark-read, or any countable event). The client mirrors
    /// these onto the buffer — it never derives unread/highlight counts locally.
    case readState(networkId: Int?, target: String, lastReadId: Int, unread: Int, highlights: Int)

    /// WS `favorites-changed`: the user's buffer favorites — the Friends/Contacts
    /// successor — as ONE global ordered list spanning networks. Sent in the connect
    /// burst and re-sent wholesale on every favorite/unfavorite/reorder/merge, so the
    /// store simply replaces what it held.
    case favoritesChanged([FavoriteEntry])

    /// WS `bookmark-updated`: a message was saved or unsaved, on any of the account's
    /// devices — including this one. The server echoes to every socket rather than
    /// answering the sender alone, so this is the single source of truth for the toggle
    /// and nothing needs to guess optimistically.
    ///
    /// Note there is no bookmark *snapshot* to pair with it: a save the client never
    /// witnessed arrives on the `bookmarked` flag of the message row itself. So a
    /// `saved: false` for an id the store never knew about is normal, not a lost update —
    /// it just means that line isn't loaded here.
    case bookmarkUpdated(messageId: Int, saved: Bool)

    /// WS `upload-progress`: how far along the server is with an upload *this* device is
    /// running (#47), correlated by the `progressToken` we put in the multipart body.
    ///
    /// **The one frame that never reaches the store** — it is an answer to something this device
    /// started, not state the account owns. It also fans out to every socket the user has open —
    /// two devices uploading at once would otherwise drive each other's readouts — so
    /// `LurkerClient` matches the token against its in-flight uploads and drops anything it
    /// didn't ask for.
    ///
    /// ⚠ It used to be one of two. `search-result` was correlated the same way until search
    /// became a REST read (#123), which is why the interception in `LurkerClient` now has a
    /// single case in it.
    case uploadProgress(token: String, progress: UploadServerProgress)

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

    /// A buffer kept its identity and changed names (protocol §9.7) — today, a
    /// DM following its peer's /nick. Like `bufferClosed`, this travels alone:
    /// nothing else re-materializes the buffer under its new name, so an
    /// unhandled rename strands the old row AND phantoms a new one when the
    /// next live event arrives. `bufferId` is the surviving buffer's stable id
    /// (it did not change); `merged` means a stale buffer already held `to` and
    /// was absorbed — `mergedFromBufferId` names it, and the survivor's history
    /// interleaves server-side (wipe and re-hydrate, never guess).
    case bufferRenamed(
        networkId: Int?,
        from: String,
        to: String,
        bufferId: Int?,
        merged: Bool,
        mergedFromBufferId: Int?
    )

    /// WS `ignore-list-updated`: one scope's ignore rules, re-sent whole (lurker #301).
    ///
    /// `networkId` nil means the global bucket, a number means that network's own — the
    /// server fans one or the other, never both, and the client replaces the matching bucket.
    /// Note this is the opposite of the nil convention buffer frames use, where nil means the
    /// app-scoped system buffer: an ignore scope of "no network" is *every* network.
    ///
    /// Fanned to every one of the account's devices, which is the point — rules are authored
    /// on the web (`/ignore`, the settings pane) and this client has no editor, so this frame
    /// is the whole of how a rule reaches the phone mid-session. It also carries the expiry
    /// sweeper's deletions, so a `-time` rule stops applying here without a reconnect.
    case ignoreListUpdated(networkId: Int?, rules: [IgnoreRule])

    /// WS `relay-bot-updated`: one nick was marked or unmarked as a relay/bridge bot (#277).
    ///
    /// One nick per frame, not a network's whole list — so the store patches rather than replaces
    /// (see `RelayBotSet.applying`). `marked` false is the clear, and `pattern` is the custom
    /// envelope template, empty for the built-in formats.
    ///
    /// Fanned to every one of the account's devices, including the one that asked, which is why
    /// nothing here is applied optimistically: this frame is the mark, and a mark made in a
    /// browser reaches the phone by exactly this route.
    ///
    /// Unlike `ignoreListUpdated`, `networkId` is a plain number: a relay mark is always about one
    /// connection, so there is no global bucket for a nil to mean.
    case relayBotUpdated(networkId: Int, nick: String, marked: Bool, pattern: String)

    /// A `peer-presence` ephemeral (rides `irc`, `type:"peer-presence"`, network-scoped via a
    /// `:server:<id>` target): a watched nick changed state. `state` is nil when the server
    /// reports no known state, which the store reads as `unknown`.
    case peerPresence(networkId: Int, nick: String, state: PresenceState?)

    /// An `away-state` ephemeral (rides `irc`, `type:"away-state"`, network-scoped via a
    /// `:server:<id>` target): *your own* away state changed — from this device, another one,
    /// or the server's own idle auto-away.
    ///
    /// `away` is nil when the account has no away on record. The server sends that literally
    /// (`away: null` when there's no `since`), so it's a value to store rather than a frame to
    /// drop: it is how "cleared" arrives.
    case awayState(networkId: Int, away: AwayState?)

    /// WS `pins-changed`: this network's pinned buffers, in the user's order.
    ///
    /// Authoritative and wholesale — the server re-sends the whole list on every pin, unpin
    /// and reorder — so the store replaces rather than patches. Sent per network, so it says
    /// nothing about the others.
    case pinsChanged(networkId: Int, pinned: [String])

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
    /// This network's own ignore rules — the connect-time seed for the per-network bucket
    /// that `ignore-list-updated` then replaces. Rules with no network scope ride the
    /// snapshot frame itself (`globalIgnores`), not this.
    var ignoredMasks: [IgnoreRule] = []
    /// The nicks marked as relay/bridge bots on this network (#277) — the connect-time seed that
    /// live `relay-bot-updated` frames then patch. Defaulted, like the fields above it, so the
    /// snapshot call sites that predate the feature don't have to name it.
    var relayBots: [RelayBot] = []
    /// Your own away state on this network (#68) — the connect-time seed for what live
    /// `away-state` events then replace. Nil when the server reports none, which is the
    /// normal case for a user who has never been away.
    var away: AwayState?
    /// The targets this network's buffers are pinned to, in the user's order — the
    /// connect-time seed for what live `pins-changed` frames then replace.
    ///
    /// Ordered, so it's an array and not a set: the order IS the payload. It is also a
    /// superset of what can be shown, since a pin row survives its buffer being parted or
    /// closed.
    var pinned: [String] = []
}

struct ChannelSnapshot: Equatable, Sendable {
    let name: String
    let topic: String?
    let members: [Member]
}
