// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// One row from `GET /api/highlights` — a message a highlight rule matched, carried with
/// the buffer it lives in. Unlike a `Message` in a buffer's log, a highlight is shown
/// *away* from its buffer (in the recent-highlights list), so it has to name its own
/// network and channel: the list spans every buffer at once.
///
/// The server's row is a full `MessageEvent` plus `networkName`; `message` holds the event
/// (nick/text/time/matched/…) and the rest is the buffer address needed to render the
/// context line and to jump back to the conversation.
public struct HighlightItem: Equatable, Sendable {
    public let message: Message
    /// The network the match happened on. Nil would mean the app-scoped system buffer, which
    /// never carries rule matches — so in practice this is always present, but it's optional
    /// to mirror `Buffer.networkId` and to build a `BufferKey` without a special case.
    public let networkId: Int?
    /// The channel or DM target, as the server stored it — used both to label the row and,
    /// with `networkId`, to resolve the buffer to jump to.
    public let target: String
    /// The network's display name, resolved server-side so the list can name it without
    /// waiting on the client's own roster to have loaded.
    public let networkName: String?
    /// Set on an activity-feed row that is someone's reaction to one of your lines (iOS #183),
    /// nil on every highlight, bookmark and search hit. On such a row `message` is the reaction
    /// as a line — the reactor's nick and host, the value as its text, the reaction's time —
    /// because that is what an ignore rule judges and what the header names; its `id` is still
    /// your line's, the jump target.
    public let reaction: FeedReaction?

    public init(
        message: Message, networkId: Int?, target: String, networkName: String?,
        reaction: FeedReaction? = nil
    ) {
        self.message = message
        self.networkId = networkId
        self.target = target
        self.networkName = networkName
        self.reaction = reaction
    }

    /// The buffer this match belongs to, for jumping back to the conversation.
    public var bufferKey: BufferKey { BufferKey(networkId: networkId, target: target) }
}

/// A page of highlights. `nextBefore` is the cursor for the next (older) page — the id to
/// pass as `before=` — or nil when this page reached the end (the server returned fewer
/// rows than the limit). Mirrors the server's `{ items, nextBefore }` response.
public struct HighlightsPage: Equatable, Sendable {
    public let items: [HighlightItem]
    /// Where the next older page starts, or nil at the end.
    public let next: FeedCursor?

    public init(items: [HighlightItem], nextBefore: Int?) {
        self.items = items
        self.next = nextBefore.map { FeedCursor(beforeMessage: $0) }
    }

    public init(items: [HighlightItem], next: FeedCursor?) {
        self.items = items
        self.next = next
    }

    /// The message-id cursor the single-source feeds page on.
    public var nextBefore: Int? { next?.beforeMessage }

    /// Whether another (older) page exists. The server signals the end by dropping
    /// `nextBefore` / `next` (null) once a page doesn't fill the limit.
    public var hasMore: Bool { next != nil }
}

/// Where a feed's next older page starts. Highlights, bookmarks and search page on one message
/// id; the activity feed merges two sources and keeps a cursor for each (`GET /api/activity`) —
/// either may be absent while that side has given nothing yet. Passed back to the server as-is.
public struct FeedCursor: Equatable, Sendable {
    public let beforeMessage: Int?
    public let beforeReaction: Int?

    public init(beforeMessage: Int? = nil, beforeReaction: Int? = nil) {
        self.beforeMessage = beforeMessage
        self.beforeReaction = beforeReaction
    }
}

/// A reaction-to-you row's own facts (iOS #183).
public struct FeedReaction: Equatable, Sendable {
    public let reactionId: Int
    public let value: String
    /// The text of your line it was given on.
    public let lineText: String?

    public init(reactionId: Int, value: String, lineText: String?) {
        self.reactionId = reactionId
        self.value = value
        self.lineText = lineText
    }
}
