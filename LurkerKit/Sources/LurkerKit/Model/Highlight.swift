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

    public init(message: Message, networkId: Int?, target: String, networkName: String?) {
        self.message = message
        self.networkId = networkId
        self.target = target
        self.networkName = networkName
    }

    /// The buffer this match belongs to, for jumping back to the conversation.
    public var bufferKey: BufferKey { BufferKey(networkId: networkId, target: target) }
}

/// A page of highlights. `nextBefore` is the cursor for the next (older) page — the id to
/// pass as `before=` — or nil when this page reached the end (the server returned fewer
/// rows than the limit). Mirrors the server's `{ items, nextBefore }` response.
public struct HighlightsPage: Equatable, Sendable {
    public let items: [HighlightItem]
    public let nextBefore: Int?

    public init(items: [HighlightItem], nextBefore: Int?) {
        self.items = items
        self.nextBefore = nextBefore
    }

    /// Whether another (older) page exists. The server signals the end by dropping
    /// `nextBefore` (null) once a page doesn't fill the limit.
    public var hasMore: Bool { nextBefore != nil }
}
