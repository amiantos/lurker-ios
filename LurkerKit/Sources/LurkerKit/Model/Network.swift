// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// An IRC network the account is configured on, as the app *renders* it: the roster's
/// name plus whatever the socket last said about the connection. The editable
/// configuration behind it — host, port, credentials — is `NetworkConfig`, fetched on
/// demand; this one is read on the hot path of every frame the store reduces.
///
/// `name` comes from REST (`GET /api/networks`); the live `state`/`nick` come from the WS
/// `snapshot` and the `state` event, and are merged in — neither carries a name.
public struct Network: Equatable, Sendable {
    public let id: Int
    /// The roster's name for this network, or nil when we haven't heard it yet.
    ///
    /// ⚠⚠ Optional rather than a placeholder string, and that is the whole of #136. The
    /// snapshot can name a network the roster doesn't hold — a failed roster fetch, or a
    /// network added from another client mid-session — and the row it materialized used the
    /// literal `"network"`, which is indistinguishable from a real name by anything
    /// downstream. So the app said "network" where a name belonged and no code could tell
    /// it was lying. Nil is the honest reading, and it's what triggers the roster re-read
    /// (`ChatViewModel.refreshRosterIfAnyNetworkIsNameless`).
    public var name: String?
    /// Where this network sits in the user's own ordering — the `position` column, which
    /// `GET /api/networks` is already sorted by and which the web sidebar's drag-to-reorder
    /// writes.
    ///
    /// REST-only, like `name`: no frame carries it. A network the roster hasn't described yet
    /// gets `Int.max` and sorts last rather than jumping to the front, which is the less
    /// startling of the two ways to be wrong for the moment before the roster lands.
    public var position: Int
    public var state: ConnectionState
    public var nick: String
    /// Your own away state, as this network last reported it (#68).
    ///
    /// Held per network because that's how the server broadcasts it, though the state itself
    /// is user-scoped — every connected network carries the same value. Nil means the server
    /// hasn't reported one, which is also what it sends for a user who has never been away.
    public var away: AwayState?
    /// True when the instance admin's allowlist excludes this network's host (#298).
    ///
    /// REST-only like `name` and `position` — no frame carries it — and held here rather than
    /// left to `NetworkConfig` because it is a fact about what a *rendered* network can be
    /// asked to do: the server buffer's info sheet decides whether to offer Connect off this,
    /// live from the store, rather than re-reading the roster every time it opens (#152). It
    /// gates only *new* connections, so a network can be blocked and connected at once — see
    /// `NetworkRow.isBlocked`.
    ///
    /// Absent reads as "not blocked": an older server has no allowlist to be excluded from,
    /// and a network the roster hasn't described yet has nothing to say about it.
    public var blocked: Bool
    /// Which client tags can go out on this network as the server last said — a reaction, taking
    /// one of ours back, a reply's tag (the snapshot, then `react-support`). **Read through
    /// `ChatState.tagSupport(networkId:)`** and its accessors, which also require the network to
    /// be connected: this describes the last registration, and a dropped link carries nothing.
    public var tagSupport: TagSupport
    /// The network's channel-mode vocabulary (lurker#727) — which letters are lists, flags and
    /// params, its PREFIX ladder, MODES and TOPICLEN.
    ///
    /// ⚠⚠ Nil means UNKNOWN: the server sends null until the registration burst ends, and this
    /// goes back to nil whenever the link drops (the next registration restates it). Never read a
    /// nil as the RFC defaults — a default is not the network saying so.
    public var modeSpec: ModeSpec?

    public init(
        id: Int,
        name: String?,
        position: Int = .max,
        state: ConnectionState = .disconnected,
        nick: String = "",
        away: AwayState? = nil,
        blocked: Bool = false,
        tagSupport: TagSupport = .nothing,
        modeSpec: ModeSpec? = nil
    ) {
        self.id = id
        self.name = name
        self.position = position
        self.state = state
        self.nick = nick
        self.away = away
        self.blocked = blocked
        self.tagSupport = tagSupport
        self.modeSpec = modeSpec
    }

    /// Take the roster's word for the REST-only fields — `name`, `position`, `blocked` — and
    /// keep everything the socket said.
    ///
    /// Here, beside the declarations, rather than as assignments in the store's merge: the
    /// store's copy of this list was missed once (`position` didn't survive a merge until a
    /// review caught it, f69c30a) and extended by hand once more (`blocked`). A field added
    /// above and to `FrameParser.parseNetworks` has one more place to be added, and it's the
    /// next line down.
    public mutating func mergeRoster(_ roster: Network) {
        name = roster.name
        position = roster.position
        blocked = roster.blocked
    }

    /// What to call this network wherever the user sees one named.
    ///
    /// Shared so the fallback can't drift between the join menu, the networks screen and
    /// anything later: an unnamed network is a transient state (the re-fetch closes it) but
    /// it still has to render as *something*, and every site inventing its own word is how
    /// #136's placeholder got mistaken for a name in the first place.
    public var displayName: String { name ?? Self.unnamedDisplayName }

    /// What to call a network whose name we haven't heard.
    ///
    /// Exposed because the buffer list also has to name a *section* for buffers whose network
    /// has no roster entry at all — a case with no `Network` to ask. That site had its own
    /// literal, and the literal was `"network"`: #136's placeholder, still lying in the one
    /// place the fix didn't reach.
    public static let unnamedDisplayName = "Unnamed network"
}

/// What a network lets this client's tags carry (§5.1): a reaction, taking one of ours back, and a
/// reply's tag — three answers, not one, because a network can allow some and deny others. irc.so's
/// UnrealIRCd takes `+draft/react` and `+reply` but denies `+draft/unreact` (lurker#1101), and a
/// reply's tag needs no echo-message, so it can be allowed where reactions aren't.
///
/// ⚠ Resolved at parse time from the server's four booleans (`FrameParser.tagSupport`): a server
/// that predates the split sends only `canReact`, which then stands for all three.
public struct TagSupport: Equatable, Sendable {
    /// A `react` verb without `remove` can go out.
    public var canAddReaction: Bool
    /// A `react` with `remove: true` can go out. The server refuses a removal otherwise, silently.
    public var canRemoveReaction: Bool
    /// A line sent with `replyTo` carries its reply tag. Where it can't, it still goes out, as a
    /// plain line.
    public var canReply: Bool

    public init(canAddReaction: Bool, canRemoveReaction: Bool, canReply: Bool) {
        self.canAddReaction = canAddReaction
        self.canRemoveReaction = canRemoveReaction
        self.canReply = canReply
    }

    /// Nothing goes out: before the burst ends, and on a link that's down.
    public static let nothing = TagSupport(canAddReaction: false, canRemoveReaction: false, canReply: false)
}

/// Mirrors the server's per-network `state` string.
public enum ConnectionState: String, Sendable {
    case connecting
    case connected
    case reconnecting
    case disconnected

    public static func from(_ raw: String?) -> ConnectionState {
        switch raw {
        case "connecting": return .connecting
        case "connected": return .connected
        case "reconnecting": return .reconnecting
        default: return .disconnected
        }
    }
}
