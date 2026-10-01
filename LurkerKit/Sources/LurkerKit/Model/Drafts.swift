// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// A draft's reply as the server sends it back (lurker#1021): the line it answers, whether the
/// Reply put `nick: ` into the text, and that line resolved the way a reply's quote is. `parent`
/// is nil when the line is gone or no longer one a reply can name — the text stays either way.
public struct DraftReply: Equatable, Sendable {
    public let messageId: Int
    public let addressed: Bool
    public let parent: ReplyParent?

    public init(messageId: Int, addressed: Bool, parent: ReplyParent?) {
        self.messageId = messageId
        self.addressed = addressed
        self.parent = parent
    }
}

/// One buffer's draft on the wire: a `draft-snapshot` entry or a `draft-updated` frame.
public struct DraftEntry: Equatable, Sendable {
    public let networkId: Int
    public let target: String
    public let body: String
    public let reply: DraftReply?
    /// Whether the frame said anything about a reply. A server from before replies sends none,
    /// and a `draft-updated` without the key leaves the reply we hold alone — absence is not a
    /// statement that there is none.
    public let carriesReply: Bool

    public init(networkId: Int, target: String, body: String, reply: DraftReply?, carriesReply: Bool = true) {
        self.networkId = networkId
        self.target = target
        self.body = body
        self.reply = reply
        self.carriesReply = carriesReply
    }

    public var key: BufferKey { BufferKey(networkId: networkId, target: target) }
}

/// What a buffer's composer holds while you're away from it (iOS #188): the text, and the reply
/// it's being written as. One draft — a reply that came back without its `alice: `, or the
/// `alice: ` without its reply, would go out as something it wasn't.
public struct ComposerDraft: Equatable, Sendable {
    public var body: String
    public var reply: PendingReply?

    public init(body: String = "", reply: PendingReply? = nil) {
        self.body = body
        self.reply = reply
    }

    /// Nothing worth keeping. A reply with nothing typed yet (on your own line, in a DM) is a
    /// draft.
    public var isEmpty: Bool { body.isEmpty && reply == nil }
}

public enum Drafts {
    /// How long typing has to pause before the draft goes to the server — the web's 500ms. A
    /// burst of keystrokes is one write; a pause between sentences is plenty to persist the line.
    /// Leaving the buffer, ending the edit and sending all flush at once.
    public static let flushDelay: Duration = .milliseconds(500)

    /// Whether this buffer keeps a synced draft. The system buffer has no network to key one to,
    /// and the server refuses one for a `:server:` log — both are command consoles, and command
    /// typing needn't follow you around.
    public static func syncs(_ key: BufferKey) -> Bool {
        key.networkId != nil && !key.target.hasPrefix(":")
    }

    /// The pending reply a stored draft reply stands for, or nil for none — and for a line the
    /// server couldn't resolve, which is no reply at all to send.
    ///
    /// Named as the timeline quotes it (`Replies.shown`, the one rule): a marked relay bot's line
    /// as the person inside it — whom the Reply addressed, and whose `nick: ` a cancel takes back
    /// — and a line from someone ignored since without their words. It's still a reply to them;
    /// the strip just doesn't quote them. The web's `pendingReplyFrom`.
    public static func pendingReply(
        from reply: DraftReply?,
        networkId: Int,
        target: String,
        ignores: IgnoreSet,
        relayBots: RelayBotSet,
        ownNick: String?,
        now: Date = Date()
    ) -> PendingReply? {
        guard let reply, let parent = reply.parent else { return nil }
        let quote = Replies.shown(
            ReplyContext(msgid: "", parent: parent),
            line: Message(id: 0, type: .message, nick: nil, text: ""),
            networkId: networkId,
            target: target,
            ignores: ignores,
            relayBots: relayBots,
            ownNick: ownNick,
            now: now
        ).quote
        return PendingReply(
            messageId: reply.messageId,
            nick: quote?.nick ?? parent.nick,
            type: parent.type,
            text: quote?.text ?? "",
            isSelf: quote?.isSelf ?? parent.isSelf,
            addressed: reply.addressed
        )
    }
}

/// The client half of draft sync: which drafts this device has written and the server hasn't
/// heard yet, and which buffer is mid-IME-composition. Pure bookkeeping — the view model owns
/// the timers and the socket. The web keeps the same two things module-local in `drafts.ts`.
///
/// Both protect the composer from the server. An unflushed edit is newer than any snapshot or
/// remote update by definition (last write wins), and a composition in flight is newer still —
/// a remote write landing there would repaint the field under a live preedit and destroy the
/// word. And the flush waits for the composition to end, so raw phonetic preedit never becomes
/// the draft every other device sees.
struct DraftSync: Equatable {
    struct Edit: Equatable, Sendable {
        let key: BufferKey
        let draft: ComposerDraft
    }

    /// By `BufferKey.id`. An entry stays until a send for it reached a socket — or, with none,
    /// until the next connect's snapshot gives it one to go out on.
    private(set) var unflushed: [String: Edit] = [:]
    /// The buffer whose composer is IME-composing, or nil.
    private(set) var composing: String?

    /// Whether a server write for this buffer must be dropped.
    func isProtected(_ id: String) -> Bool { unflushed[id] != nil || composing == id }

    var protectedIds: Set<String> {
        var ids = Set(unflushed.keys)
        if let composing { ids.insert(composing) }
        return ids
    }

    /// The draft as this device last wrote it, if the server hasn't heard it yet.
    func local(_ id: String) -> ComposerDraft? { unflushed[id]?.draft }

    /// Record an edit. `composing` starts or ends that buffer's composition; ending one in a
    /// buffer that isn't the composing one leaves the other alone.
    mutating func edit(_ key: BufferKey, _ draft: ComposerDraft, composing isComposing: Bool) {
        unflushed[key.id] = Edit(key: key, draft: draft)
        if isComposing {
            composing = key.id
        } else if composing == key.id {
            composing = nil
        }
    }

    /// Whether a flush has to wait — the buffer is composing.
    func defersFlush(_ id: String) -> Bool { composing == id }

    /// End whatever composition is marked — leaving the field and leaving the buffer do, so a
    /// missed commit can't hold off remote updates forever. Returns the buffer whose deferred
    /// flush is now due, if it has an edit waiting.
    mutating func endComposition() -> BufferKey? {
        guard let id = composing else { return nil }
        composing = nil
        return unflushed[id]?.key
    }

    /// Take a buffer's edit to send it.
    mutating func take(_ id: String) -> Edit? { unflushed.removeValue(forKey: id) }

    /// Every edit waiting to go out, the composing buffer's included — for a flush that can't
    /// wait (the app leaving the foreground), which takes them all.
    mutating func takeAll() -> [Edit] {
        let edits = Array(unflushed.values)
        unflushed = [:]
        composing = nil
        return edits
    }

    /// The buffers with an edit waiting, except one whose composition holds its flush.
    var flushableIds: [String] { unflushed.keys.filter { $0 != composing } }

    /// Put an edit back that found no socket — unless a newer one was made in the meantime.
    mutating func restore(_ edit: Edit) {
        if unflushed[edit.key.id] == nil { unflushed[edit.key.id] = edit }
    }

    /// An edit that was put back reached the server another way: forget it, unless a newer one
    /// has replaced it since.
    mutating func settle(_ edit: Edit) {
        if unflushed[edit.key.id] == edit { unflushed[edit.key.id] = nil }
    }

    /// A closed buffer's draft goes with it; the server clears its row on the close.
    mutating func drop(_ id: String) {
        unflushed[id] = nil
        if composing == id { composing = nil }
    }

    /// Follow a rename. On a merge the destination wins if it has an edit of its own — the
    /// server keeps the survivor's draft too, and what the user typed there is theirs.
    mutating func rekey(from: BufferKey, to: BufferKey) {
        guard from.id != to.id else {
            // Same storage key, new display name: the flush has to name the buffer as it is now.
            if let edit = unflushed[from.id] { unflushed[to.id] = Edit(key: to, draft: edit.draft) }
            return
        }
        let moving = unflushed.removeValue(forKey: from.id)
        if composing == from.id { composing = to.id }
        guard let moving, unflushed[to.id] == nil else { return }
        unflushed[to.id] = Edit(key: to, draft: moving.draft)
    }

    mutating func reset() { self = DraftSync() }
}
