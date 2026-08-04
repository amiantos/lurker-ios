// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine
import Foundation

/// How the live socket stands, for a connection state the user can actually see.
public enum SocketStatus: Equatable, Sendable {
    case connecting
    case connected
    case reconnecting
}

/// Immutable snapshot of everything the chat UI renders. The map keys are `BufferKey.id`.
public struct ChatState: Sendable {
    public var connection: SocketStatus = .connecting
    /// Whether the device has a network path at all, per the OS — fed in by the app
    /// (`ChatViewModel.setReachable`), the same way foreground/background is, so this
    /// package stays free of the `Network` framework (whose `NWPath` would also collide
    /// with our own `Network` model type).
    ///
    /// Deliberately separate from `connection`: they're two different truths. The socket
    /// only ever reports connecting/connected/reconnecting — it has no way to say "there
    /// is no internet" — so without this the indicator could never legitimately show red.
    public var reachable: Bool = true
    /// Highest persisted message id seen (excluding the system buffer, which has its own
    /// id space) — replayed as `?since=` on reconnect so the server ships only the gap.
    /// Populated now so #4 can resume without a store change.
    public var maxEventId: Int = 0
    public var networks: [Int: Network] = [:]
    public var buffers: [String: Buffer] = [:]
    /// Whether a full snapshot burst has finished this session — i.e. `buffers` is the
    /// server's whole answer rather than a prefix of it.
    ///
    /// The buffer list needs this to tell "still arriving" from "you genuinely have no
    /// buffers". Three plausible signals are all wrong, in ways that only show on some
    /// accounts:
    ///
    ///  - **`connection`** — the socket reports `.connected` *before* the burst is applied,
    ///    so it flashes the empty state in the gap. The same trap `BufferPlaceholder`
    ///    documents for the message list.
    ///  - **The `snapshot` frame** — not authoritative for buffer existence (see
    ///    `ServerFrame.snapshot`): its `channels` is empty for every network that isn't
    ///    currently connected, and DMs and `:server:` logs are never in it. A DM-only account,
    ///    or any launch while the networks are still connecting, would flash "no buffers".
    ///  - **Emptiness itself** — indistinguishable from the answer being empty.
    ///
    /// So it's latched on `backlog-complete`, the frame that exists to say the burst is done.
    ///
    /// Never cleared on a drop. A reconnect resends everything, but the roster we already have
    /// stays on screen while it does, so going back to "loading" would blank a list with
    /// perfectly good content in it. `reset()` builds a fresh `ChatState`, so sign-out clears it.
    public var backlogComplete = false
    public var messages: [String: [Message]] = [:]
    public var members: [String: [Member]] = [:]
    /// Buffer favorites (the Friends/Contacts successor): one server-authoritative
    /// global ordered list spanning networks, seeded and corrected wholesale by
    /// `favorites-changed`. The UI splits it by kind — DMs → Friends, channels →
    /// Favorites.
    public var favorites: [FavoriteEntry] = []
    /// Saved-message ids — what the bookmark toggle reads. **Read through
    /// `isBookmarked(_:)`.**
    ///
    /// A cache of what this session has *seen*, not a mirror of what the account owns. There
    /// is deliberately no bookmark snapshot in the connect burst: the server used to send
    /// every saved id on every connect, which is the one piece of connect state that grows
    /// without bound over an account's life. Instead each message row carries its own
    /// `bookmarked` flag, so this fills in from the pages the client was going to render
    /// anyway, and an id that isn't here is simply one whose line isn't loaded.
    ///
    /// That's sound because the only question ever asked of it is "is the line the user is
    /// looking at saved?" — and a line being looked at is a line that was loaded. The full
    /// Bookmarks list comes from `GET /api/bookmarks`, not from here.
    ///
    /// A page is authoritative for the rows it CONTAINS, in both directions — an unflagged
    /// row means unsaved — but says nothing about the rows it doesn't. Silence about an id is
    /// not an unsave. See `noteBookmarks(in:networkId:)`.
    ///
    /// The other way in is `noteBookmarked(ids:)`, for the `GET /api/bookmarks` feed, whose
    /// rows carry no flag because every one of them is saved by definition.
    ///
    /// Ids are `messages` table ids. System-buffer lines have a *separate* id sequence that
    /// overlaps this one, but they can't be bookmarked at all (the server's ownership check
    /// joins through networks, which they have none of) — so nothing ever puts one in here,
    /// and `MessageActions` never asks about one.
    public var bookmarkedIds: Set<Int> = []
    /// Peer presence keyed `networkId → lowercased nick → state`. Mirrors the server's
    /// MONITOR-fed presence: seeded from each network snapshot's `peerPresence` blob and
    /// patched by live `peer-presence` events. Read through `presence(networkId:nick:)`,
    /// which layers the network's own connection state on top.
    public var peerPresence: [Int: [String: PresenceState]] = [:]
    /// Who is composing, keyed `BufferKey.id → lowercased nick → entry`.
    ///
    /// Purely ephemeral — there is no snapshot for it, so this starts empty on every connect
    /// and is fed entirely by live `typing` frames.
    ///
    /// **Read through `typists(in:now:)`, never directly.** An entry is removed only by an
    /// event — a `done`/unrecognized state, a message from that nick, the buffer closing, the
    /// socket dropping. Nothing prunes on a clock, so a lapsed entry stays in this map until
    /// one of those happens; `typists` filters it out of the answer rather than deleting it.
    /// Reading the map raw therefore reports people who stopped typing minutes ago.
    ///
    /// The residue is bounded and small — one entry per nick who typed here and then went
    /// quiet without sending anything — so it's left to be cleaned up by the events above
    /// rather than by a sweep that would only exist to tidy a map nobody reads directly.
    public var typing: [String: [String: TypingEntry]] = [:]
    /// Whether the roster is settled: a burst has completed and none is in flight, so
    /// `buffers` is the server's whole answer *right now* and a missing key is proof the
    /// buffer isn't open.
    ///
    /// `backlogComplete` alone isn't that proof — it latches for the session, so it stays
    /// true while a *later* burst (a reconnect, an in-band resync) is still arriving and
    /// `buffers` is mid-rebuild. Reading absence during that window would condemn buffers
    /// whose frames simply hadn't landed yet. Both conditions together are what §4.3's
    /// "absence is proof" actually licenses.
    public var rosterSettled: Bool { backlogComplete && !burstActive }
    /// Bumped once per snapshot burst. The identity of "everything the server has told us
    /// so far" — a change means it started over.
    ///
    /// This is what one-shot-per-connection requests must key off, NOT `connection`.
    /// `connection` looks like the obvious signal and isn't: `handleClose` drops a close
    /// callback that arrives after the socket has already been replaced (correct — a stale
    /// close must not clobber its live replacement), so a socket can die and be replaced
    /// with `connection` never leaving `.connected`. A request written to the dead socket
    /// is then lost with no observable state change, and anything that latched "I already
    /// asked" waits forever for a reply that cannot come.
    ///
    /// A burst, by contrast, is unmissable: every reconnect produces one, and it is the
    /// server saying "here is everything again", which is exactly the moment a pending
    /// request from the previous socket becomes void.
    public internal(set) var burstGeneration = 0
    /// Live events that arrived while a buffer was detached (#42), keyed like `messages` —
    /// kept aside instead of being appended, and merged back in when it re-attaches.
    ///
    /// A detached buffer can't take a live event into its log: the slice sits far below the
    /// tail, so appending would splice a hole. But *dropping* it loses the message outright,
    /// because the re-attach fetch was built by the server BEFORE the event existed — a hole
    /// the client can never notice and nothing ever refetches. That's the real cost, and it
    /// isn't a rare race: walking a detached slice forward (#45) fires an `after` page per
    /// screenful, and everything said during the last of those round trips falls in it.
    ///
    /// Capped per buffer at `heldLiveCap`, oldest dropped first. Trimming from the OLD edge is
    /// what makes the cap safe: the re-attach keeps only the held events newer than the slice
    /// it fetched, and that slice is itself the newest few hundred rows — so anything the trim
    /// discards is either already in the fetch or older than it, never the gap above it.
    var heldLive: [String: [Message]] = [:]

    /// Buffer keys the server has named in the snapshot burst currently in flight, so
    /// `backlog-complete` can prune the ones it *didn't* — see `pruneToBurst`.
    var burstSeen: Set<String> = []
    /// bufferId → storage key (`BufferKey.id`). Maintained by every path that
    /// writes a `buffers` row with a known id; consumed by rename-following.
    public internal(set) var keysById: [Int: String] = [:]
    /// Whether a snapshot burst is in flight (a `snapshot` frame arrived, its terminal
    /// `backlog-complete` hasn't). Guards the prune: a stray `backlog-complete` with no
    /// burst behind it must not be read as "the server listed nothing", which would wipe
    /// the roster.
    var burstActive = false
    /// The account's ignore rules (lurker #301). Seeded by the connect `snapshot` — global
    /// rules from the frame, per-network ones from each network blob — and replaced a bucket
    /// at a time by `ignore-list-updated`.
    ///
    /// Server-authoritative and read-only here: rules are authored on the web and fanned to
    /// every device, so what this holds is the same set the server itself matched against
    /// when it stamped the messages now on screen. Filtering happens at *render* time
    /// (`ChatViewController.apply`, the member list, the feeds) rather than on the way into
    /// this store, so a rule arriving mid-session re-filters the backlog already held — and
    /// a rule going away brings those lines straight back with no refetch.
    public var ignores: IgnoreSet = .empty
    /// The user's server-side settings (#65). Seeded by `/api/settings/bootstrap` and patched
    /// by live `settings` frames, so a change made on the web takes effect here without a
    /// relaunch. Read through `settings.effective(_:)` / its typed helpers — never `values`.
    public var settings = Settings()
    public var error: String?

    public init() {}

    /// Forget a buffer completely — the row and everything keyed to it.
    ///
    /// "Closed is absent" (lurker `CLIENT_PROTOCOL.md` §9.1): the server keeps the history,
    /// so a reopen restores it in full and there is nothing here worth preserving. Clearing
    /// `members`/`typing` alongside the messages is what stops a reopened buffer inheriting a
    /// nicklist or a "still typing…" line from before the close.
    ///
    /// `peerPresence` is deliberately untouched — it's keyed by network+nick rather than by
    /// buffer, and that nick may still be visible in channels we're in.
    ///
    /// The one shared definition of "drop it", used by all three paths that need it: this
    /// device closing a buffer (`removeBuffer`), the server saying another device did
    /// (`buffer-closed`), and reconciling a burst that no longer lists it (`pruneToBurst`).
    mutating func dropBuffer(_ key: String) {
        if let id = buffers[key]?.bufferId, keysById[id] == key { keysById[id] = nil }
        buffers[key] = nil
        messages[key] = nil
        members[key] = nil
        typing[key] = nil
        heldLive[key] = nil
    }

    /// Move everything keyed by `from` onto `to` — the rename mirror of
    /// `dropBuffer`'s map set, plus `burstSeen` (a rename landing mid-burst
    /// must not let the closing prune delete the survivor) and the id index.
    /// The `to` slots are overwritten: the only caller (the `bufferRenamed`
    /// reduce) drops the absorbed side first on a merge, so a collision here
    /// means stale local state losing to the surviving buffer, which is right.
    mutating func rekeyBuffer(from: String, to: String, newTarget: String) {
        guard let buf = buffers[from] else { return }
        let renamed = buf.renamed(to: newTarget)
        // Casing-only rename: same storage key (BufferKey folds case), so nothing
        // moves — but the display name still changed, and it's the whole frame.
        if from == to {
            buffers[to] = renamed
            return
        }
        buffers[from] = nil
        buffers[to] = renamed
        messages[to] = messages[from]
        messages[from] = nil
        members[to] = members[from]
        members[from] = nil
        typing[to] = typing[from]
        typing[from] = nil
        heldLive[to] = heldLive[from]
        heldLive[from] = nil
        if burstSeen.remove(from) != nil { burstSeen.insert(to) }
        if let id = renamed.bufferId { keysById[id] = to }
    }

    /// Learn (or confirm) a buffer's stable id → storage-key mapping. The
    /// index is what lets a rename be followed by a screen that only knows
    /// the id it was opened with.
    mutating func indexBufferId(_ buffer: Buffer, key: String) {
        guard let id = buffer.bufferId else { return }
        keysById[id] = key
    }

    /// Drop every buffer the just-finished snapshot burst didn't mention.
    ///
    /// The burst enumerates exactly the user's OPEN buffers — the server skips closed rows
    /// when building it (`wsHub.ts:651`) — so after `backlog-complete`, a buffer we hold that
    /// got no frame is one the server no longer considers open. That is the *only* way we
    /// learn about a close that happened while this device wasn't listening, and on a phone
    /// that's the common case: `buffer-closed` is fanned out to connected sockets only, and
    /// reconnect is a `?since=` gap-fill that replays messages, not buffer lifecycle. Without
    /// this, closing a buffer on the web while the phone is backgrounded left the row on the
    /// phone until the app was relaunched.
    ///
    /// Safe because it drops only what's in memory. §4.3's warning — "don't purge local
    /// history, drafts, or a saved read position on the strength of a missing frame" — is
    /// about *persisted* state, of which this client has none per buffer: messages are a
    /// cache refetched on open, and read state is server-owned. Rendering the buffer as
    /// absent is exactly what a missing frame licenses.
    mutating func pruneToBurst() {
        guard burstActive else { return }
        // Collected before mutating: `buffers` is being written in the loop below.
        let doomed = buffers.keys.filter { !burstSeen.contains($0) }
        for key in doomed { dropBuffer(key) }
        burstActive = false
        burstSeen = []
    }

    /// What the app-icon badge should read: unread highlights across every buffer (#490).
    ///
    /// Mirrors the server's `computeTotalHighlights`, which is what it stamps on each push
    /// — so the number the icon shows while the app is closed and the number it shows once
    /// it reopens come from the same definition rather than drifting apart. Per-buffer
    /// counts are server-authoritative, so this is a sum, never a local tally.
    ///
    /// It has to exist client-side at all because a push only ever REVISES the badge: iOS
    /// applies `aps.badge` and then nothing touches it again, so reading your messages
    /// would leave the icon stuck on whatever the last notification claimed until another
    /// one happened to arrive.
    public var totalHighlights: Int {
        buffers.values.reduce(0) { $0 + $1.highlights }
    }

    /// The buffer for `key`, synthesizing an empty one when the store has no row yet.
    ///
    /// Every screen that navigates somewhere by *key* rather than by a buffer in hand needs
    /// this: a launch restoring where you left off, a notification tap, a highlight tap, a
    /// channel you just asked to join. In all four the row may legitimately not exist yet —
    /// a push can beat its own backlog frame, a join's row arrives with `channel-joined` —
    /// and the screen's `hydrateIfNeeded` fills it in once it does.
    ///
    /// It lives here because the four call sites had each written it out and one had already
    /// drifted, hardcoding `.channel` where `BufferKind.of` would have said `.dm`: a `!foo`
    /// target carries a channel sigil for *input* purposes (`ChannelName.sigils`) but is not
    /// one of the sigils a buffer is classified by. That mismatch gives a screen a member
    /// list and nick coloring for a buffer whose store row disagrees.
    public func buffer(for key: BufferKey) -> Buffer {
        buffers[key.id]
            ?? Buffer(
                networkId: key.networkId,
                target: key.target,
                kind: BufferKind.of(networkId: key.networkId, target: key.target)
            )
    }

    /// The status of a watched (network, nick), disconnected-aware — the single source the
    /// friend rows read. Mirrors the web client's `peerFor` + `deriveState`, plus a check the
    /// web doesn't need (its socket state drives the same store):
    ///  - if THIS client can't reach the server — no device network path, or a socket that
    ///    isn't up (connecting/reconnecting) — every cached row is stale, because presence only
    ///    ever arrives over a live socket. Report `offline` rather than a green dot over a dead
    ///    link; a stale snapshot can otherwise leave `Network.state` reading `.connected`;
    ///  - a network we hold but that isn't connected reads `offline` (its cached presence
    ///    rows are stale, and a peer on a network we've dropped is unreachable from here);
    ///  - a connected network with no row for the nick reads `unknown` ("potentially online",
    ///    the no-MONITOR case), as does a network we've never heard of;
    ///  - otherwise the stored state maps through: `online`/`back` → online, `away`, `offline`.
    public func presence(networkId: Int, nick: String) -> FriendPresence {
        guard reachable, connection == .connected else { return .offline }
        if let network = networks[networkId], network.state != .connected { return .offline }
        switch peerPresence[networkId]?[nick.lowercased()] {
        case .online, .back: return .online
        case .away: return .away
        case .offline: return .offline
        case nil: return .unknown
        }
    }

    /// Whether this line is saved. See `bookmarkedIds` for why an unknown id reads as
    /// unsaved rather than unknown.
    public func isBookmarked(_ messageId: Int) -> Bool { bookmarkedIds.contains(messageId) }

    /// Reconcile `bookmarkedIds` against a page of rows.
    ///
    /// Each row is authoritative FOR ITSELF, in both directions: the server computes
    /// `bookmarked` per row and omits it when false, so a row that arrives unflagged is
    /// saying it isn't saved. Without the clear, an unsave made on another device while this
    /// client was offline would never land — the `bookmark-updated` echo was missed, and the
    /// reconnect backlog that does carry the truth would be read for additions only, leaving
    /// the line lit until someone tapped it.
    ///
    /// What it must NOT do is evict ids the page says nothing about: a page knows its own
    /// slice and no more, so silence about an id is not an unsave.
    ///
    /// `networkId` gates the whole thing. System-buffer rows come from a different table with
    /// its own id sequence that overlaps this one, and they never carry the flag — reconciling
    /// against them would clear real bookmarks that happen to share an id.
    mutating func noteBookmarks(in messages: [Message], networkId: Int?) {
        guard networkId != nil else { return }
        for message in messages where message.id != 0 {
            if message.bookmarked {
                bookmarkedIds.insert(message.id)
            } else {
                bookmarkedIds.remove(message.id)
            }
        }
    }

    /// Mark ids saved wholesale, for a source that carries no per-row flag because every row
    /// in it is saved by definition — the `GET /api/bookmarks` feed. Purely additive: unlike a
    /// message page, this one has nothing to say about the rows it doesn't contain.
    mutating func noteBookmarked(ids: [Int]) {
        for id in ids where id != 0 { bookmarkedIds.insert(id) }
    }

    /// The peers currently composing in `key`, display-cased, longest-running first.
    ///
    /// `now` is a parameter rather than an internal `Date()` so this is deterministic under
    /// test. The lease is evaluated *here* — the map itself is never pruned — which means a
    /// caller that stops asking simply sees expired entries gone the next time it does, with
    /// no timer needed to keep the state honest in the meantime.
    ///
    /// Ordered by when each peer started their current run, tie-broken on the folded nick so
    /// two entries stamped from the same instant (which is every fixture in the tests, and a
    /// real possibility for two frames in one runloop) still come out in a fixed order rather
    /// than at the mercy of dictionary iteration.
    ///
    /// An ignored peer is left out: someone whose messages you've hidden shouldn't announce
    /// that they're about to send one — the line would name a person whose next line you'll
    /// never see. The filter sits here rather than at the call site because every surface that
    /// shows typists reads through this one method, and a gate you have to remember to apply
    /// at each of them isn't one. Only a whole-identity rule counts (`isIgnored`): a typing tag
    /// carries no body or event type, so a content or level-scoped rule has nothing to judge.
    public func typists(in key: BufferKey, now: Date = Date()) -> [String] {
        guard let entries = typing[key.id] else { return [] }
        // Gated once rather than per entry: this runs inside the chat screen's
        // `removeDuplicates` on every frame the socket delivers, and again every second from
        // the typing ticker, so an account with no rules should pay one dictionary lookup for
        // the whole call and not one per person composing.
        let filtering = !ignores.isEmpty(for: key.networkId)
        return entries.values
            .filter {
                guard $0.isLive(at: now) else { return false }
                guard filtering else { return true }
                // Scoped to this buffer, so a `-channels #foo` rule silences the indicator in
                // the same buffer it silences the messages.
                return !ignores.isIgnored(
                    networkId: key.networkId, nick: $0.nick, userhost: $0.userhost,
                    channel: key.target, now: now
                )
            }
            .sorted { ($0.startedAt, $0.nick.lowercased()) < ($1.startedAt, $1.nick.lowercased()) }
            .map(\.nick)
    }

    /// A channel's members minus anyone an ignore rule erases (lurker #301).
    ///
    /// Here, next to `typists(in:)`, for the reason that one gives: `members` is read by the
    /// nicklist, the buffer-info count and nick completion, and a filter each of them has to
    /// remember to apply isn't one — the info sheet reported a count that included people the
    /// nicklist next to it was hiding.
    ///
    /// Only a whole-identity `ALL` rule removes somebody (see `IgnoreMatch.isMemberHidden`). A
    /// content, level-scoped or `NOHIGHLIGHT` rule leaves them listed, because they are still
    /// in the channel and still talking — a nicklist that disagreed with who is actually
    /// present would be lying about the room rather than filtering it.
    ///
    /// You are always listed. A hostmask rule can legitimately cover your own nick (a shared
    /// bouncer host, a wildcard on the network you're on), and disappearing yourself from your
    /// own nicklist is never what such a rule meant.
    public func visibleMembers(in key: BufferKey) -> [Member] {
        let members = self.members[key.id] ?? []
        guard !ignores.isEmpty(for: key.networkId) else { return members }
        let ownNick = key.networkId.flatMap { networks[$0]?.nick }
        return members.filter { member in
            if let ownNick, member.nick.caseInsensitiveCompare(ownNick) == .orderedSame {
                return true
            }
            return !ignores.isMemberHidden(
                networkId: key.networkId,
                nick: member.nick,
                userhost: member.userhost,
                channel: key.target
            )
        }
    }

}

/// Holds the domain state and folds `ServerFrame`s into it. The fold is a pure function
/// (`reduce`) with no I/O, so it is fully unit-testable; the store just wraps it in a
/// `CurrentValueSubject` the UI observes. `@MainActor` because the client marshals every
/// frame to main before applying it, so no locking is needed.
@MainActor
final class LurkerStore {
    private let subject = CurrentValueSubject<ChatState, Never>(ChatState())

    var state: ChatState { subject.value }
    var statePublisher: AnyPublisher<ChatState, Never> { subject.eraseToAnyPublisher() }

    /// Clear everything session-scoped. Reachability survives: it's a fact about the
    /// device, not the session, and nothing re-reports it on sign-out — resetting it to
    /// the `true` default would leave an offline phone claiming it's online.
    func reset() {
        var next = ChatState()
        next.reachable = subject.value.reachable
        subject.value = next
    }

    /// Drop a buffer and its cached messages/members — the optimistic local half of a
    /// close-buffer (the server then hides it, so it won't re-appear on the next snapshot).
    func removeBuffer(_ key: BufferKey) {
        var next = subject.value
        next.dropBuffer(key.id)
        subject.value = next
    }

    func clearError() { subject.value.error = nil }

    /// Append a client-authored info line to a buffer — the app answering the user in
    /// place, the web client's `localInfo`. Ephemeral by construction: id 0 never
    /// persists, so resyncs and reloads drop it, exactly like the web's local lines.
    func appendLocal(_ key: BufferKey, text: String) {
        var next = subject.value
        let line = Message(id: 0, type: .system, nick: nil, text: text, level: .info)
        next.messages[key.id] = (next.messages[key.id] ?? []) + [line]
        subject.value = next
    }

    /// Mirror the OS's view of network reachability into the state. Not a `ServerFrame`
    /// because it isn't one — it comes from the device, not the server — so it sits
    /// alongside the other direct mutations rather than lying in `reduce`.
    func setReachable(_ reachable: Bool) {
        guard subject.value.reachable != reachable else { return }
        subject.value.reachable = reachable
    }

    /// Record a fetched page of saved messages as bookmarked, in ONE mutation.
    ///
    /// Not a `ServerFrame` because it isn't one — it comes from a REST read, like
    /// `setReachable` comes from the device. Per-id `bookmark-updated` frames would say the
    /// same thing, but each `apply` publishes a whole `ChatState`, so a 50-row page would
    /// wake every subscriber 50 times to communicate a single set union.
    func noteBookmarked(ids: [Int]) {
        guard !ids.isEmpty else { return }
        var next = subject.value
        next.noteBookmarked(ids: ids)
        subject.value = next
    }

    func apply(_ frame: ServerFrame) {
        subject.value = Self.reduce(subject.value, frame)
    }

    /// The pure core. Given the current state and a frame, produce the next state.
    ///
    /// `now` exists only for the typing lease — the one piece of state whose meaning depends on
    /// the clock. It's a defaulted parameter rather than a `Date()` inside the typing branch so
    /// this stays a pure function of its inputs and the lease behavior is testable without
    /// sleeping through it.
    static func reduce(_ state: ChatState, _ frame: ServerFrame, now: Date = Date()) -> ChatState {
        switch frame {
        case .networks(let networks):
            return applyNetworks(state, networks)
        case .snapshot(let networks, let globalIgnores):
            // Frame 1 of every burst (CLIENT_PROTOCOL.md §4.3), so this is where the
            // roster reconciliation window opens. Start collecting the keys the server
            // names; `backlog-complete` closes the window and prunes the rest.
            // Open the window BEFORE applying, not after: `applySnapshot` materializes
            // rows and records them as seen, and clearing afterwards threw those
            // entries away — leaving any buffer the snapshot named but that got no
            // backlog frame of its own to be pruned by the terminal frame.
            var next = state
            next.burstSeen = []
            next.burstActive = true
            next.burstGeneration &+= 1
            return applySnapshot(next, networks, globalIgnores: globalIgnores)
        case .backlogComplete:
            // The burst is over, so whatever `buffers` holds now is the whole roster — even
            // when that's nothing. Latched: a later resync re-sends it, and re-asserting true
            // costs nothing, but going back to false would blank a populated list.
            var next = state
            next.backlogComplete = true
            // ...and "the whole roster" cuts both ways: anything we still hold that the
            // burst didn't name is no longer open. This is the only signal for a close that
            // happened while this device wasn't connected.
            next.pruneToBurst()
            return next
        case .backlog(let buffer, let messages, let hydrated, let append):
            return applyBacklog(state, buffer, messages, hydrated: hydrated, append: append)
        case .live(let networkId, let target, let message):
            return applyLive(state, networkId: networkId, target: target, message: message)
        case .channelTopic(let networkId, let target, let topic):
            return applyChannelTopic(state, networkId: networkId, target: target, topic: topic)
        case .channelMembers(let networkId, let target, let members):
            return applyChannelMembers(state, networkId: networkId, target: target, members: members)
        case .memberUpdate(let networkId, let target, let member):
            return applyMemberUpdate(state, networkId: networkId, target: target, member: member)
        case .history(let networkId, let target, let events, let mode, let hasMoreOlder, let hasMoreNewer):
            return applyHistory(
                state, networkId: networkId, target: target,
                events: events, mode: mode, hasMoreOlder: hasMoreOlder, hasMoreNewer: hasMoreNewer
            )
        case .readState(let networkId, let target, let lastReadId, let unread, let highlights):
            return applyReadState(
                state, networkId: networkId, target: target,
                lastReadId: lastReadId, unread: unread, highlights: highlights
            )
        case .favoritesChanged(let favorites):
            var next = state
            next.favorites = favorites
            return next
        case .bookmarkUpdated(let messageId, let saved):
            var next = state
            if saved {
                next.bookmarkedIds.insert(messageId)
            } else {
                // A remove for an id we never held is normal, not a lost update: without a
                // connect snapshot, the set only knows the lines this session has loaded.
                next.bookmarkedIds.remove(messageId)
            }
            return next
        case .ignoreListUpdated(let networkId, let rules):
            // One bucket at a time — the server fans the global list or one network's, never
            // both — and the list it carries is complete for that scope, so it replaces rather
            // than merges. A removal has no other way to reach us.
            var next = state
            next.ignores = state.ignores.replacing(networkId: networkId, with: rules)
            return next
        case .bufferClosed(let networkId, let target):
            // The live half: a close on another device while this one is connected. The
            // offline half — a close we were never told about — is `pruneToBurst`.
            var next = state
            next.dropBuffer(BufferKey(networkId: networkId, target: target).id)
            return next
        case .bufferRenamed(
            let networkId, let from, let to, let bufferId, let merged, _):
            // Protocol §9.7: same buffer, new name. On a merge the ABSORBED
            // buffer (the stale one that already held `to`) is dropped FIRST,
            // so the rekey lands with no collision; its storage key equals the
            // survivor's post-rename key (BufferKey folds case), which is why
            // a viewer sitting in the absorbed DM self-heals — the key they
            // watch simply becomes the survivor. The survivor's history
            // interleaves two streams server-side, so its local slice is
            // wiped and de-hydrated: the ordinary hydrate path refetches
            // rather than guessing at the interleave.
            var next = state
            let fromKey = BufferKey(networkId: networkId, target: from).id
            let toKey = BufferKey(networkId: networkId, target: to).id
            if next.buffers[fromKey] != nil {
                // `toKey != fromKey` is belt-and-braces: the server never merges a
                // casing-only rename, but if a malformed frame said so, dropping
                // `toKey` here would delete the very row being renamed.
                if merged, toKey != fromKey { next.dropBuffer(toKey) }
                next.rekeyBuffer(from: fromKey, to: toKey, newTarget: to)
            } else if merged, var held = next.buffers[toKey] {
                // We never held the source (a live rename can beat the source's
                // backlog frame mid-burst, or a reconnect left a gap) — so the row
                // we hold under the new name is the ABSORBED one, already swallowed
                // server-side by a survivor this device hasn't seen. CONVERT it
                // rather than drop it: dropping vanishes the buffer under a reader,
                // and conversion is exactly what the absorbed-seat self-heal
                // produces anyway. Its id is the dead one — un-index and clear it;
                // the frame's id (stamped below) is the survivor's.
                if let dead = held.bufferId, next.keysById[dead] == toKey {
                    next.keysById[dead] = nil
                }
                held.bufferId = nil
                next.buffers[toKey] = held.renamed(to: to)
            }
            if var survivor = next.buffers[toKey] {
                if let bufferId { survivor.bufferId = bufferId }
                if merged {
                    survivor.hydrated = false
                    survivor.hasMoreOlder = true
                    next.messages[toKey] = []
                }
                next.buffers[toKey] = survivor
                next.indexBufferId(survivor, key: toKey)
            }
            // The favorites list carries target strings too, and the server only
            // republishes favorites-changed after MERGES — a plain nick-follow
            // rename would otherwise leave the entry pointing at the dead name
            // until the next echo: a ghost Friends chip under the old nick, plus
            // the renamed DM leaking back into its network roster (every section
            // split keys off entry targets). Rewrite by bufferId — the identity
            // the frame proves — and drop nothing: a merge's absorbed-favorite
            // adoption arrives via its own favorites-changed follow-up.
            if let bufferId {
                next.favorites = next.favorites.map { entry in
                    entry.bufferId == bufferId
                        ? FavoriteEntry(networkId: entry.networkId, target: to, bufferId: bufferId)
                        : entry
                }
            }
            return next
        case .peerPresence(let networkId, let nick, let peerState):
            var next = state
            var map = next.peerPresence[networkId] ?? [:]
            // A null state (server reports nothing known) is stored as absence, so it reads
            // back as `unknown` rather than a stale prior state.
            if let peerState {
                map[nick.lowercased()] = peerState
            } else {
                map.removeValue(forKey: nick.lowercased())
            }
            next.peerPresence[networkId] = map
            return next
        case .awayState(let networkId, let away):
            // Only ever a patch onto a network we already hold. The away stream is broadcast
            // from a live connection, so its network is in the snapshot by definition —
            // materializing a row from this frame would invent a network with no name, no
            // state and no channels, which the roster would then render.
            guard var network = state.networks[networkId] else { return state }
            network.away = away
            var next = state
            next.networks[networkId] = network
            return next
        case .typing(let networkId, let target, let nick, let activity, let userhost):
            return applyTyping(
                state, networkId: networkId, target: target,
                nick: nick, activity: activity, userhost: userhost, now: now
            )
        case .settingsBootstrap(let registry, let values):
            var next = state
            next.settings.load(registry: registry, values: values)
            return next
        case .settingsChanged(let changes):
            var next = state
            // Patch, never replace — the frame carries only what moved, so assigning it
            // wholesale would drop every other stored setting until the next bootstrap.
            next.settings.apply(changes: changes)
            return next
        case .settingsValues(let values):
            var next = state
            // Replace: this one IS the full stored set, and it can be smaller than what we
            // hold (see `Settings.replaceValues`).
            next.settings.replaceValues(values)
            return next
        case .serverError(let text):
            var next = state
            next.error = text
            return next
        case .sendResult(_, let ok, let error):
            var next = state
            next.error = ok ? nil : (error ?? "Send failed")
            return next
        case .socketOpen:
            var next = state
            next.connection = .connected
            next.error = nil
            return next
        case .socketClosed:
            var next = state
            // Once we've been connected, a drop is a reconnect; a drop before the first
            // open is still the initial connect.
            switch next.connection {
            case .connected, .reconnecting: next.connection = .reconnecting
            case .connecting: next.connection = .connecting
            }
            // Nobody is typing at us over a socket that isn't there. The lease would retire
            // these on its own, but a `paused` entry holds for 30s — long enough to survive a
            // reconnect and show a peer composing when we've heard nothing from them since
            // before the drop.
            next.typing = [:]
            return next
        case .unauthorized, .ignored:
            // Session-level / no-op; the view model intercepts `.unauthorized` first.
            return state
        case .searchResult:
            // Never reaches here — `LurkerClient` consumes it to resume the awaiting
            // `search(_:)` call, and it is the only frame that does not travel on. Handled
            // explicitly rather than folded into the no-op case above so that "search results
            // are a reply, not state" stays a stated rule instead of a silent one: matches
            // span every buffer at once, and there is no buffer for them to belong to.
            return state
        }
    }

    // MARK: - Reducers

    /// Fold a peer's `+typing` tag into the typing map.
    ///
    /// **Resolve, never materialize.** A typing tag must not conjure a buffer. It's an ambient
    /// signal *about* a conversation, not evidence one exists, and a DM row invented from one
    /// would be a phantom the user never opened — the incoming PRIVMSG is what opens a DM
    /// (`CLIENT_PROTOCOL.md:632`; this was web bug #292). So an entry is stored only when a
    /// buffer row is already present, and the frame is otherwise dropped.
    ///
    /// Case folding comes free from `BufferKey.id`, which lowercases the target: a tag for
    /// `#Chan` lands on a buffer joined as `#chan`, and one cased `Bob` finds the DM opened as
    /// `bob`. Servers are inconsistent here and it has bitten before (web #289).
    private static func applyTyping(
        _ state: ChatState,
        networkId: Int?,
        target: String,
        nick: String,
        activity: TypingActivity?,
        userhost: String?,
        now: Date
    ) -> ChatState {
        let key = BufferKey(networkId: networkId, target: target).id
        guard state.buffers[key] != nil else { return state }
        var next = state
        var entries = next.typing[key] ?? [:]
        // One entry per peer regardless of how the server cased them across two tags.
        let canon = nick.lowercased()

        guard let activity else {
            // `done`, or a value we don't recognize: they've stopped. Removing beats storing a
            // terminal state — an entry parked here with no lease left to run out is precisely
            // the stuck indicator the web had to go back and fix.
            entries.removeValue(forKey: canon)
            next.typing[key] = entries.isEmpty ? nil : entries
            return next
        }

        // A refresh preserves the original start time so the displayed order doesn't shuffle
        // mid-run — but only while the previous entry is still live. Once a peer's lease has
        // lapsed they stopped and started again, and that's a new run which belongs at the end
        // of the list rather than back at its original place.
        let previous = entries[canon]
        let startedAt = previous.flatMap { $0.isLive(at: now) ? $0.startedAt : nil } ?? now
        entries[canon] = TypingEntry(
            nick: nick,
            activity: activity,
            startedAt: startedAt,
            expiresAt: now.addingTimeInterval(activity.lease),
            userhost: userhost
        )
        next.typing[key] = entries
        return next
    }

    private static func applyNetworks(_ state: ChatState, _ networks: [Network]) -> ChatState {
        var next = state
        for network in networks {
            // Merge the REST name in without clobbering any live state the snapshot set.
            if var existing = next.networks[network.id] {
                existing.name = network.name
                next.networks[network.id] = existing
            } else {
                next.networks[network.id] = network
            }
        }
        return next
    }

    private static func applySnapshot(
        _ state: ChatState,
        _ networks: [NetworkSnapshot],
        globalIgnores: [IgnoreRule]
    ) -> ChatState {
        var next = state
        // Ignore rules replace wholesale, both buckets at once — the snapshot IS the account's
        // rule set, so a rule deleted while this device was away has to disappear here rather
        // than survive as a leftover. Built from the frame alone for the same reason: merging
        // the per-network buckets into what we already held would keep a rule belonging to a
        // network that has since been removed.
        var ignoresByNetwork: [Int: [IgnoreRule]] = [:]
        for snapshot in networks where !snapshot.ignoredMasks.isEmpty {
            ignoresByNetwork[snapshot.id] = snapshot.ignoredMasks
        }
        next.ignores = IgnoreSet(global: globalIgnores, byNetwork: ignoresByNetwork)
        for snapshot in networks {
            if var existing = next.networks[snapshot.id] {
                existing.state = snapshot.state
                existing.nick = snapshot.nick
                // Assigned rather than merged, nil included: the snapshot is this network's
                // whole live state, so an away cleared while this device was disconnected has
                // to disappear here. Keeping the old value would leave a stale "away" divider
                // in every buffer with no event able to retract it.
                existing.away = snapshot.away
                next.networks[snapshot.id] = existing
            } else {
                next.networks[snapshot.id] = Network(
                    id: snapshot.id, name: "network", state: snapshot.state, nick: snapshot.nick,
                    away: snapshot.away
                )
            }
            for channel in snapshot.channels {
                let key = BufferKey(networkId: snapshot.id, target: channel.name).id
                var buffer = next.buffers[key]
                    ?? Buffer(networkId: snapshot.id, target: channel.name, kind: .channel)
                buffer.joined = true
                buffer.topic = channel.topic
                next.buffers[key] = buffer
                next.members[key] = channel.members
                // Third path that can materialize a row, so it owes `burstSeen` an entry
                // like the other two — otherwise the burst's closing prune could drop a
                // buffer the snapshot itself just created. Unreachable against today's
                // server (this list and the burst's enumeration are built from the same
                // live `conn.channels` map, so anything here also gets its own frame), but
                // that's a cross-repo invariant this client can't enforce and shouldn't
                // silently depend on.
                next.burstSeen.insert(key)
            }
            // The snapshot is authoritative for this network's presence — replace wholesale,
            // so a reconnect drops any stale rows for peers no longer watched.
            next.peerPresence[snapshot.id] = snapshot.peerPresence
        }
        return next
    }


    private static func applyBacklog(
        _ state: ChatState,
        _ frameBuffer: Buffer,
        _ messages: [Message],
        hydrated: Bool,
        append: Bool
    ) -> ChatState {
        var next = state
        next.noteBookmarks(in: messages, networkId: frameBuffer.networkId)
        let key = frameBuffer.key.id
        // The server named this buffer, so it survives the burst's closing prune. Recorded
        // unconditionally: outside a burst `burstSeen` is dead state that the next `snapshot`
        // clears, so there's nothing to guard against.
        next.burstSeen.insert(key)
        let prior = next.buffers[key]
        // The buffer is parked on an `around` slice below the live tail (#42). A backlog frame
        // has nothing to say about what's on screen, and every way of applying one is wrong:
        //
        //  - Appending a resume gap splices a PERMANENT hole. The gap starts at `?since=`,
        //    which `applyLive` advanced past every event it held back during the detach — so
        //    the rows between the slice and the gap were never delivered and never will be.
        //  - Replacing throws away the window the user jumped to, silently, while they're
        //    reading it.
        //  - Either way the frame's own `hasMoreNewer` (parseBacklog never sets it, so it's
        //    the `false` default) would clear the detach flag — retiring the jump-to-latest
        //    pill, resuming live appends onto the old slice, and leaving a buffer that reads
        //    as live while missing everything in between. That was the bug: jump to an old
        //    message, background the app, come back, and the reconnect's resume frame quietly
        //    stitched the present onto two months ago.
        //
        // So the log waits. Re-attaching is always a fresh `history mode:latest` fetch, which
        // is where the live tail comes from — the same call the web's `replaceBacklog` makes
        // (`vue_client/src/stores/buffers.ts:520`). Buffer-level state below still applies:
        // read counts and `joined` are slice-independent.
        let detached = prior?.hasMoreNewer == true
        var buffer = frameBuffer
        // Never un-hydrate: a later shell for an already-read buffer keeps its history.
        buffer.hydrated = hydrated || prior?.hydrated == true
        // …and never un-know the read state, for the same reason: a frame that omits
        // `lastReadId` hasn't retracted one we were already told.
        buffer.readStateKnown = frameBuffer.readStateKnown || prior?.readStateKnown == true
        // Which also means keeping the VALUES a pointer-less frame would otherwise overwrite
        // with its defaults. `frameBuffer` replaces `prior` wholesale, and all three of these
        // parse to 0 when absent — so a frame that says nothing about read state would
        // otherwise say "read nothing, no unreads", which is a claim it never made.
        if !frameBuffer.readStateKnown, let prior, prior.readStateKnown {
            buffer.lastReadId = prior.lastReadId
            buffer.unread = prior.unread
            buffer.highlights = prior.highlights
        }
        // The frame carries no topic — the server doesn't put one there — so assigning it
        // wholesale would blank whatever the connect `snapshot` had just set, and it ships
        // BEFORE the per-buffer backlogs it would be blanked by.
        buffer.topic = frameBuffer.topic ?? prior?.topic
        // Never un-learn the id either: a frame from a pre-id server (or a
        // synthesized row) hasn't retracted the id a real frame stated.
        buffer.bufferId = frameBuffer.bufferId ?? prior?.bufferId
        // A resync shell (hasMoreOlder defaults true) must not reset the paging or detach
        // state of a buffer we've already paged into or jumped within (#42) — and neither may
        // a real backlog while we're detached, for the reasons above. Only a hydrated backlog
        // for an ATTACHED buffer is the latest tail, and only it gets to say.
        if let prior, detached || (!hydrated && prior.hydrated) {
            buffer.hasMoreOlder = prior.hasMoreOlder
            buffer.hasMoreNewer = prior.hasMoreNewer
        }
        next.buffers[key] = buffer
        next.indexBufferId(buffer, key: key)

        if detached {
            // The slice stands. See above.
        } else if !hydrated {
            // Shell: register the buffer but keep any messages we already hold.
            if next.messages[key] == nil { next.messages[key] = [] }
        } else if append {
            // Resume gap slice: append past the tail, de-duping by persisted id.
            next.messages[key] = appendMerged(next.messages[key] ?? [], messages)
        } else {
            // Full / latest backlog: replace — but keep any live events that arrived after
            // the server built this backlog (id past its tail), so hydrating mid-traffic
            // (e.g. a message lands between open-buffer and its reply) can't punch a hole.
            let tail = messages.map(\.id).max() ?? 0
            let heldNewer = (next.messages[key] ?? []).filter { $0.id > tail }
            next.messages[key] = messages + heldNewer
        }
        next.maxEventId = maxEventId(next.maxEventId, frameBuffer.networkId, messages)
        return next
    }

    private static func applyLive(
        _ state: ChatState,
        networkId: Int?,
        target: String,
        message: Message
    ) -> ChatState {
        var next = state
        let key = BufferKey(networkId: networkId, target: target).id
        let existing = next.messages[key] ?? []
        // De-dupe backlog/live overlap by persisted id; id 0 is ephemeral and always
        // appended.
        if message.id != 0, existing.contains(where: { $0.id == message.id }) { return next }
        if next.buffers[key] == nil {
            // A live event can be the first sign of a buffer (a new incoming DM), so
            // materialize a row for it. Unhydrated, so tapping it fetches history.
            next.buffers[key] = Buffer(
                networkId: networkId, target: target,
                kind: BufferKind.of(networkId: networkId, target: target)
            )
            // A DM that materializes mid-burst was created after the server enumerated the
            // roster, so the burst legitimately won't name it — mark it seen or the closing
            // prune would drop a buffer that just arrived.
            next.burstSeen.insert(key)
        }
        // A topic change is both a line and the topic itself. This has to sit *below* the
        // id de-dupe above, not with the parse: a `topic` event replayed by a backlog/live
        // overlap would otherwise re-apply an old topic over the current one, silently
        // reverting the channel's topic to whatever it was at replay time. The Vue client
        // hit this first and its handler carries the same warning.
        if message.type == .topic { next.buffers[key]?.topic = message.text }
        // Membership churn folds into the member list here, and only here — the same
        // seat below the id de-dupe the topic needs, and for the same reason: a
        // replayed join must not resurrect a member who has since parted. Backlog and
        // history replays deliberately don't fold — the snapshot/`names` list is the
        // authoritative baseline those events predate.
        next.members[key] = foldMembership(next.members[key], message)
        // Anything we hear *from* this nick ends their typing run, and the same seat below
        // the id de-dupe applies for the same reason.
        //
        // This is the spec's first clear condition, not an optimization: `typing=done` is only
        // sent "when the user clears the text-input field WITHOUT sending a message"
        // (`client-tags/typing.md:38`), so a conforming client — senpai, Goguma, gamja —
        // never announces `done` on send. Without this, their message lands and the "alice is
        // typing…" line stays pinned underneath it for the rest of the lease: 6s after an
        // `active`, 30s after a `paused`. Lurker-to-Lurker hides the bug, because our own
        // composer emits a (non-spec) `done` on send.
        //
        // Covers the spec's second condition too — a part/quit/kick from someone mid-sentence
        // clears them rather than leaving a ghost typing in a channel they've left. The web
        // does the same, keyed off the resolved buffer (`stores/buffers.ts:444`).
        if let speaker = message.nick?.lowercased(), next.typing[key]?[speaker] != nil {
            next.typing[key]?.removeValue(forKey: speaker)
            if next.typing[key]?.isEmpty == true { next.typing[key] = nil }
        }
        // A detached buffer (showing an `around` slice below the live tail, #42) holds live
        // events out of the log — appending them would splice a hole past the slice. Member
        // and topic state above stays current; only the message log waits.
        //
        // HELD, not dropped (`heldLive`). The re-attach fetches the latest slice, but the
        // server built that slice before this event existed, so dropping it leaves a hole at
        // the seam that nothing ever fetches again — the client can't even tell it's there.
        // Keeping it means the re-attach can put back exactly what it can't have asked for.
        //
        // `maxEventId` still advances so the resume cursor doesn't re-request an event the
        // client has already been given.
        if next.buffers[key]?.hasMoreNewer == true {
            next.heldLive[key] = trimmedToCap((next.heldLive[key] ?? []) + [message])
            next.maxEventId = maxEventId(next.maxEventId, networkId, [message])
            return next
        }
        next.messages[key] = existing + [message]
        next.maxEventId = maxEventId(next.maxEventId, networkId, [message])
        return next
    }

    /// One live membership event applied to a channel's member list. Nicks match
    /// case-insensitively throughout: servers echo inconsistent casing, and `toLowerCase`
    /// matching is house style (see `BufferKey`).
    ///
    /// A join can seed a list from nil — our own join precedes the `names` broadcast, so
    /// the list briefly holds just us until the full roster lands. Removals against nil
    /// stay nil: a quit fans out to DM buffers too, which have no list to edit.
    private static func foldMembership(_ members: [Member]?, _ message: Message) -> [Member]? {
        switch message.type {
        case .join:
            guard let nick = message.nick, !nick.isEmpty else { return members }
            let list = members ?? []
            // Already present (e.g. the list arrived via `names` before our fold ran):
            // keep the existing entry and whatever modes/away it carries.
            guard !list.contains(where: { $0.nick.lowercased() == nick.lowercased() })
            else { return members }
            return list + [Member(nick: nick)]
        case .part, .quit:
            return removingMember(members, nick: message.nick)
        case .kick:
            // `kicked` is who left; `nick` is the actor doing the kicking.
            return removingMember(members, nick: message.kicked)
        case .nick:
            guard let old = message.nick?.lowercased(), let new = message.newNick, !new.isEmpty
            else { return members }
            return members.map { list in
                list.map { member in
                    guard member.nick.lowercased() == old else { return member }
                    return Member(
                        nick: new, modes: member.modes, away: member.away,
                        user: member.user, host: member.host
                    )
                }
            }
        default:
            return members
        }
    }

    private static func removingMember(_ members: [Member]?, nick: String?) -> [Member]? {
        guard let nick, !nick.isEmpty else { return members }
        return members.map { list in
            list.filter { $0.nick.lowercased() != nick.lowercased() }
        }
    }

    /// RPL_TOPIC on join. Unlike a `topic` event this carries no id, so there's nothing to
    /// de-dupe against — the server only sends it when it's telling us the current truth.
    ///
    /// Deliberately does not materialize a missing buffer, which `applyLive` does: a topic
    /// for a channel we have no row for is nothing to show and nowhere to show it, and the
    /// snapshot that creates the row carries the topic anyway.
    private static func applyChannelTopic(
        _ state: ChatState,
        networkId: Int?,
        target: String,
        topic: String?
    ) -> ChatState {
        var next = state
        next.buffers[BufferKey(networkId: networkId, target: target).id]?.topic = topic
        return next
    }

    /// A `names` broadcast: replace the member list wholesale — it IS the list, the same
    /// authority the snapshot carries. Stored even if no buffer row exists yet: `members`
    /// is a side table keyed like the buffers, so an early entry creates nothing visible,
    /// and the row that makes it visible is on its way (our own join precedes `names`).
    private static func applyChannelMembers(
        _ state: ChatState,
        networkId: Int?,
        target: String,
        members: [Member]
    ) -> ChatState {
        var next = state
        next.members[BufferKey(networkId: networkId, target: target).id] = members
        return next
    }

    /// A `member-update` patch: replace the matching member with the server's snapshot.
    /// Wholesale replace is safe because the server always sends the complete member
    /// (its `memberSnapshot`), never a partial. Resolve, never create — an attribute
    /// patch for a nick we don't hold has nothing to attach to (matching the web
    /// client's `updateMember`), and matching is case-insensitive because a CHGHOST
    /// echoes the nick as the server holds it, which needn't match what NAMES gave us.
    private static func applyMemberUpdate(
        _ state: ChatState,
        networkId: Int?,
        target: String,
        member: Member
    ) -> ChatState {
        var next = state
        let key = BufferKey(networkId: networkId, target: target).id
        guard var list = next.members[key],
              let index = list.firstIndex(where: { $0.nick.lowercased() == member.nick.lowercased() })
        else { return next }
        list[index] = member
        next.members[key] = list
        return next
    }

    /// Mirror server-authoritative read counts onto the buffer. The counts are never
    /// derived locally — a `read-state` broadcast (from this device's mark-read, another
    /// device's, or any countable event) is the single source of truth.
    private static func applyReadState(
        _ state: ChatState,
        networkId: Int?,
        target: String,
        lastReadId: Int,
        unread: Int,
        highlights: Int
    ) -> ChatState {
        var next = state
        let key = BufferKey(networkId: networkId, target: target).id
        guard var buffer = next.buffers[key] else { return next }
        buffer.lastReadId = lastReadId
        buffer.unread = unread
        buffer.highlights = highlights
        // This frame carries the pointer by definition, so it's one of the two that can say
        // the read state is known (see `Buffer.readStateKnown`).
        buffer.readStateKnown = true
        next.buffers[key] = buffer
        return next
    }

    /// Splice a `history` page in: `before` prepends older, `after` appends newer,
    /// `latest`/`around` replace. Always de-dupes by persisted id — a page can overlap
    /// events the live fan-out already delivered.
    private static func applyHistory(
        _ state: ChatState,
        networkId: Int?,
        target: String,
        events: [Message],
        mode: HistoryMode,
        hasMoreOlder: Bool,
        hasMoreNewer: Bool
    ) -> ChatState {
        var next = state
        next.noteBookmarks(in: events, networkId: networkId)
        let key = BufferKey(networkId: networkId, target: target).id
        let existing = next.messages[key] ?? []
        let wasDetached = next.buffers[key]?.hasMoreNewer == true
        switch mode {
        case .before:
            let held = Set(existing.compactMap { $0.id != 0 ? $0.id : nil })
            next.messages[key] = events.filter { $0.id == 0 || !held.contains($0.id) } + existing
        case .after:
            next.messages[key] = appendMerged(existing, events)
        case .latest:
            // Return-to-live: replace, but keep live events newer than this slice's tail so a
            // message that outran the fetch isn't dropped (the slice is at the tail, so there's
            // no gap).
            let tail = events.map(\.id).max() ?? 0
            next.messages[key] = events + existing.filter { $0.id > tail }
        case .around:
            // A jump slice is centered on an arbitrary (possibly old) message, so anything
            // already held is on the far side of a gap — keeping it would splice the old window
            // onto unrelated newer messages. Replace outright, like the web's applyAroundSlice.
            next.messages[key] = events
        }
        if var buffer = next.buffers[key] {
            buffer.hydrated = true
            if mode != .after { buffer.hasMoreOlder = hasMoreOlder } // `after` pages newer
            // Detach state (#42): an `around` slice may sit below the tail → detached; `latest`
            // is the tail → re-attached; `after` carries whether newer remains. `before` pages
            // older within whatever attachment we already have, so it's left untouched.
            switch mode {
            case .around, .after: buffer.hasMoreNewer = hasMoreNewer
            case .latest: buffer.hasMoreNewer = false
            case .before: break
            }
            next.buffers[key] = buffer
        }
        // Detach transitions decide what happens to the events held aside while detached.
        switch (wasDetached, next.buffers[key]?.hasMoreNewer == true) {
        case (_, true) where mode == .around:
            // A fresh jump. Whatever was held belongs to the window we just left, and this
            // slice is somewhere else entirely — start the hold over.
            next.heldLive[key] = []
        case (true, false):
            // Re-attached. The slice we just fetched is the server's answer as of the moment
            // it ran the query; everything said *after* that is what we've been holding, and
            // it is contiguous with the slice's tail because the socket delivered every one of
            // them. Anything at or below the tail is already in the slice — `appendMerged`
            // de-dupes those by id.
            let held = next.heldLive.removeValue(forKey: key) ?? []
            let tail = (next.messages[key] ?? []).map(\.id).max() ?? 0
            // `id == 0` is an ephemeral the server never persisted — a `ctcp` or `e2e` status
            // line — so no fetch can ever contain it and no id can place it. It survives on
            // the same terms it does everywhere else in the store (`appendMerged`): always
            // kept, always appended. Comparing it against the tail would discard every one of
            // them (0 is never greater), which is precisely the loss this hold exists to stop,
            // and the only kind of it that's unrecoverable.
            next.messages[key] = appendMerged(
                next.messages[key] ?? [], held.filter { $0.id == 0 || $0.id > tail }
            )
        default:
            break
        }
        next.maxEventId = maxEventId(next.maxEventId, networkId, events)
        return next
    }

    /// How many live events a single detached buffer holds before the oldest start falling off.
    ///
    /// Generous next to what re-attaching actually fetches (a `latest` slice is a couple of
    /// hundred rows), which is the number that has to be covered — see `ChatState.heldLive`.
    /// Bounded at all because a buffer can sit detached indefinitely: leave a jump slice open
    /// on a busy channel overnight and an unbounded hold is the session's whole traffic.
    private static let heldLiveCap = 500

    private static func trimmedToCap(_ held: [Message]) -> [Message] {
        held.count > heldLiveCap ? Array(held.suffix(heldLiveCap)) : held
    }

    /// Append `incoming` onto `existing`, dropping any persisted id already present.
    private static func appendMerged(_ existing: [Message], _ incoming: [Message]) -> [Message] {
        let seen = Set(existing.compactMap { $0.id != 0 ? $0.id : nil })
        return existing + incoming.filter { $0.id == 0 || !seen.contains($0.id) }
    }

    /// The `?since=` watermark. The system buffer (nil networkId) is skipped — it has a
    /// separate id space, so its ids must not pollute the resume cursor.
    private static func maxEventId(_ current: Int, _ networkId: Int?, _ messages: [Message]) -> Int {
        guard networkId != nil else { return current }
        return max(current, messages.map(\.id).max() ?? 0)
    }
}
