// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine

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
    public var messages: [String: [Message]] = [:]
    public var members: [String: [Member]] = [:]
    public var error: String?

    public init() {}

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
        next.buffers[key.id] = nil
        next.messages[key.id] = nil
        next.members[key.id] = nil
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

    func apply(_ frame: ServerFrame) {
        subject.value = Self.reduce(subject.value, frame)
    }

    /// The pure core. Given the current state and a frame, produce the next state.
    static func reduce(_ state: ChatState, _ frame: ServerFrame) -> ChatState {
        switch frame {
        case .networks(let networks):
            return applyNetworks(state, networks)
        case .snapshot(let networks):
            return applySnapshot(state, networks)
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
            return next
        case .unauthorized, .ignored:
            // Session-level / no-op; the view model intercepts `.unauthorized` first.
            return state
        }
    }

    // MARK: - Reducers

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

    private static func applySnapshot(_ state: ChatState, _ networks: [NetworkSnapshot]) -> ChatState {
        var next = state
        for snapshot in networks {
            if var existing = next.networks[snapshot.id] {
                existing.state = snapshot.state
                existing.nick = snapshot.nick
                next.networks[snapshot.id] = existing
            } else {
                next.networks[snapshot.id] = Network(
                    id: snapshot.id, name: "network", state: snapshot.state, nick: snapshot.nick
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
            }
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
        let key = frameBuffer.key.id
        // Never un-hydrate: a later shell for an already-read buffer keeps its history.
        let alreadyHydrated = next.buffers[key]?.hydrated == true
        var buffer = frameBuffer
        buffer.hydrated = hydrated || alreadyHydrated
        // A resync shell (hasMoreOlder defaults true) must not reset the paging or detach
        // state of a buffer we've already paged into or jumped within (#42) — only a real
        // (hydrated) backlog, which is the latest tail, re-attaches.
        if !hydrated, let prior = next.buffers[key], prior.hydrated {
            buffer.hasMoreOlder = prior.hasMoreOlder
            buffer.hasMoreNewer = prior.hasMoreNewer
        }
        next.buffers[key] = buffer

        if !hydrated {
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
        // A detached buffer (showing an `around` slice below the live tail, #42) holds live
        // events out of the log — appending them would splice a hole past the slice. Member
        // and topic state above stays current; only the message log waits, and re-attaching
        // (jump-to-latest → loadLatest) fetches the true latest. `maxEventId` still advances so
        // the resume cursor doesn't re-request an event the client has already seen.
        if next.buffers[key]?.hasMoreNewer == true {
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
        let key = BufferKey(networkId: networkId, target: target).id
        let existing = next.messages[key] ?? []
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
        next.maxEventId = maxEventId(next.maxEventId, networkId, events)
        return next
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
