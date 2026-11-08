// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// A deleted line's mark (IRCv3 `draft/message-redaction`, lurker#1013 / #1277): the server NULLed
/// its text and stamped who sent the REDACT, when, and the reason if one came. The web's
/// `shared/redaction.ts`. Absent on every line that wasn't deleted, like `bookmarked`.
public struct Redaction: Equatable, Sendable {
    /// The nick that sent the REDACT: the author, or an op who removed it.
    public let by: String
    /// The REDACT's optional trailing reason, as given. Never a default one.
    public let reason: String?
    /// When, as server-time (or arrival) — ISO 8601, like a row's `time`.
    public let time: String?

    public init(by: String, reason: String? = nil, time: String? = nil) {
        self.by = by
        self.reason = reason
        self.time = time
    }

    /// The placeholder a deleted line shows in place of its text: "message deleted", naming who did
    /// it when it wasn't the author, and the reason when one came. The web's `redactionLabel`.
    ///
    /// Case-insensitive on the nick — the deleter is named the way the REDACT came, which can
    /// differ in case from the line's stored nick.
    public func label(authorNick: String?) -> String {
        let own = authorNick.map { NickCompletion.sameNick($0, by) } ?? false
        var label = own || by.isEmpty ? Redactions.placeholder : "message deleted by \(by)"
        if let reason, !reason.isEmpty { label += ": \(reason)" }
        return label
    }
}

/// A live `message-redacted` frame (§7.1): the line `messageId` was deleted. Mark it wherever it's
/// shown; never a reason to reopen a closed buffer. The frame's `self` isn't carried: nothing here
/// reads it — the mark names the deleter, and `isSelf` on the row says whose line it was.
public struct MessageRedacted: Equatable, Sendable {
    public let networkId: Int
    public let target: String
    public let messageId: Int
    public let by: String
    public let reason: String?
    public let time: String?

    public init(networkId: Int, target: String, messageId: Int, by: String, reason: String? = nil, time: String? = nil) {
        self.networkId = networkId
        self.target = target
        self.messageId = messageId
        self.by = by
        self.reason = reason
        self.time = time
    }

    public var redaction: Redaction { Redaction(by: by, reason: reason, time: time) }
}

/// The rules about deleted lines that don't belong to any one screen — the web's `redaction.ts`
/// and the delete half of `useMessageActions`.
public enum Redactions {

    /// What a deleted line says where its words were, and what a reply's quote of one says.
    public static let placeholder = "message deleted"

    /// The lines as the screen draws them: every line the store knows was deleted — by the row it
    /// came in on, or by a frame since — shows as deleted, its words gone. A display transform like
    /// relay re-attribution: the stored row is never patched (see `ChatState.redactions`).
    ///
    /// After relay re-attribution, as the web orders it: a bridged line keeps the speaker its
    /// envelope named, and the placeholder stands where their words were.
    ///
    /// Returns the SAME array when nothing in it is deleted — the common case for every buffer but
    /// the one a deletion happened in — so a pipeline built on list identity stays cheap.
    public static func presenting(_ messages: [Message], redactions: [Int: Redaction]) -> [Message] {
        guard messages.contains(where: { mark(for: $0, in: redactions) != nil }) else { return messages }
        return messages.map { line in
            guard let redaction = mark(for: line, in: redactions) else { return line }
            // Already shown as deleted (a row that arrived that way): nothing to take off it.
            return line.redaction == redaction && line.text == nil ? line : line.deleted(redaction)
        }
    }

    /// The line's mark: the store's, else the row's own. An ephemeral line (`id == 0`) has no row
    /// in the store to be marked by.
    private static func mark(for line: Message, in redactions: [Int: Redaction]) -> Redaction? {
        (line.id != 0 ? redactions[line.id] : nil) ?? line.redaction
    }

    /// Whether Delete is offered on this line (lurker#1013): a line a REDACT could name — a msgid,
    /// in a channel or DM, not already deleted — on a network that negotiated the cap
    /// (`canRedact`), and one of ours, or anyone's in a channel where we hold a prefix mode
    /// (`moderating`), which is who ergo lets delete. The network has the last word (a FAIL comes
    /// back as an error line); this only keeps the action off lines where it could do nothing.
    ///
    /// Not `Replies.replyable`: that rule refuses an E2E line because a reply TAG would be
    /// cleartext about it, and a REDACT carries no content (its reason stays off the wire on an
    /// E2E channel — the server's `redact`). Your own encrypted line can go like any other.
    public static func deletable(
        _ message: Message, target: String, support: TagSupport, moderating: Bool
    ) -> Bool {
        guard message.id != 0, !(message.msgid ?? "").isEmpty, message.redaction == nil,
              message.type.isSpeech, Reactions.isConversation(target), support.canRedact
        else { return false }
        if message.isSelf { return true }
        return moderating && ChannelName.isChannelTarget(target)
    }

    /// What `/delete` lands on: your most recent line here that's still standing — and when it
    /// can't be deleted, why not. The web's `runDelete`. `messages` as the screen shows them
    /// (after `presenting`), so a line deleted while held isn't picked again.
    public static func commandTarget(in messages: [Message]) -> Result<Message, Reactions.CommandRefusal> {
        guard let own = messages.last(where: { $0.id != 0 && $0.isSelf && $0.type.isSpeech && $0.redaction == nil })
        else { return .failure(Reactions.CommandRefusal("nothing of yours here to delete")) }
        if (own.msgid ?? "").isEmpty {
            return .failure(Reactions.CommandRefusal("can't delete that line (no message id)"))
        }
        return .success(own)
    }
}
