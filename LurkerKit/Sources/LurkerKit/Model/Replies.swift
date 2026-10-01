// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The line an IRCv3 reply answers, as the server found it by msgid in the reply's own buffer
/// (lurker#995, iOS #184). Its `text` is clipped to 300 characters with formatting codes intact.
public struct ReplyParent: Equatable, Sendable {
    /// The jump target.
    public let id: Int
    public let nick: String
    public let type: EventType
    public let text: String
    /// For the ignore check: a line from someone ignored since shows as unavailable.
    public let userhost: String?
    /// One of your own lines.
    public let isSelf: Bool

    public init(id: Int, nick: String, type: EventType, text: String, userhost: String? = nil, isSelf: Bool = false) {
        self.id = id
        self.nick = nick
        self.type = type
        self.text = text
        self.userhost = userhost
        self.isSelf = isSelf
    }
}

/// On a message row that is a reply. `parent` is nil when no line we hold carries that msgid —
/// retention took it, it predates our history, it was a reaction, or its author was ignored when
/// it arrived — and the reply then shows without its context.
public struct ReplyContext: Equatable, Sendable {
    public let msgid: String
    public let parent: ReplyParent?

    public init(msgid: String, parent: ReplyParent?) {
        self.msgid = msgid
        self.parent = parent
    }
}

/// The answered line as a reply's quote shows it: when it came through a marked relay bot, as the
/// person inside the envelope, with the bot and the `[source]` kept (lurker#996).
public struct ReplyQuote: Equatable, Sendable {
    public let id: Int
    public let nick: String
    public let type: EventType
    public let text: String
    /// Whether the person quoted is you — for a relayed line, whether the person INSIDE it is.
    public let isSelf: Bool
    public let relayBot: String?
    public let relaySource: String?
}

/// The reply a composer is writing (the web's `PendingReply`): the line it answers, and whether
/// the Reply put `nick: ` into the draft — only then does cancelling take it back out.
public struct PendingReply: Equatable, Sendable {
    /// The stored line being answered — what `replyTo` names on the wire.
    public let messageId: Int
    public let nick: String
    public let type: EventType
    public let text: String
    /// A reply to your own line — the bar says "yourself".
    public let isSelf: Bool
    public var addressed: Bool

    public init(messageId: Int, nick: String, type: EventType, text: String, isSelf: Bool, addressed: Bool = false) {
        self.messageId = messageId
        self.nick = nick
        self.type = type
        self.text = text
        self.isSelf = isSelf
        self.addressed = addressed
    }
}

/// The rules about IRCv3 replies that don't belong to any one screen — the web's `replyText.ts`,
/// `useReplyQuote` and the reply half of `useMessageActions`.
public enum Replies {

    /// Whether a Reply can make a real reply of this line: it needs the msgid the reply names and a
    /// channel or DM to send it in. Not an E2E line — the server sends no reply tags on an
    /// encrypted channel — and not the `:server:` console or a `=nick` DCC chat. The server
    /// re-checks all of it and sends a plain line when it can't; this decides what Reply does.
    public static func replyable(_ message: Message, target: String) -> Bool {
        message.id != 0
            && !(message.msgid ?? "").isEmpty
            && !message.isE2E
            && message.type.isSpeech
            && Reactions.isConversation(target)
    }

    /// A DM or a DCC chat: the line goes to the one other person anyway, so a Reply there puts no
    /// `nick: ` in the draft (lurker#1015 — halloy skips it in queries too).
    public static func isPrivate(_ target: String) -> Bool {
        !target.isEmpty && !target.hasPrefix(":") && !ChannelName.isChannelTarget(target)
    }

    /// Whether the composer line `text` would go out as a reply if one is pending: a plain line,
    /// a `//`-escaped one, or a `/me` with something in it. Every other command leaves the reply
    /// pending — the web's rule, so a `/whois` typed mid-reply doesn't spend it.
    public static func consumes(_ text: String) -> Bool {
        if text.hasPrefix("//") || !text.hasPrefix("/") { return !text.isEmpty }
        let body = text.dropFirst()
        let verb = body.prefix { !$0.isWhitespace }
        guard verb.lowercased() == "me" else { return false }
        return !body.dropFirst(verb.count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The answered line as one line of plain text: formatting codes dropped, line breaks folded
    /// to spaces. The view clips it to its width.
    public static func excerpt(_ text: String) -> String {
        IRCFormatting.strip(text)
            .replacingOccurrences(of: #"\s*\n+\s*"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A reply's text without the `nick: ` it opens with when it names the author it answers —
    /// how halloy, goguma and our own composer send one, so a client without replies still sees
    /// who it's for. The quote above already names them. Only a nick followed by punctuation
    /// counts: a reply to `will` saying "will you come?" keeps its first word. Never strips to
    /// nothing.
    ///
    /// The scalar walk is `NickCompletion`'s, so what Reply writes, what Cancel takes back and
    /// what this hides agree on what a nick and a mark are — and it costs no regex per reply on a
    /// list that's re-presented on every frame.
    public static func stripAddress(_ text: String, nick: String) -> String {
        NickCompletion.removingReplyAddress(text, to: nick)
    }

    /// How a reply reads — its quote, and its own text — the ONE rule, so a reply reads the same
    /// in the timeline and wherever else it turns up (the web's `useReplyQuote.shownReply`).
    ///
    /// - The quote is nil ("unavailable") when the server found no line, and also when its author
    ///   is ignored NOW: the server only screens out who was ignored when the reply arrived. Your
    ///   own line is never hidden. Judged as the line it was, in the reply's buffer.
    /// - A quoted line from a marked relay bot shows the person inside its envelope, as the
    ///   timeline shows that line; `isSelf` then says whether that person is you.
    /// - The text loses the `alice: ` it opens with when the quote names her — or the bot, which a
    ///   client that knows nothing of relay marks addresses instead. Only on a `message`, and only
    ///   when there's a quote: with none, that address is the only sign of who it's to.
    public static func shown(
        _ context: ReplyContext,
        line: Message,
        networkId: Int?,
        target: String,
        ignores: IgnoreSet,
        relayBots: RelayBotSet,
        ownNick: String?,
        now: Date = Date()
    ) -> (quote: ReplyQuote?, text: String?) {
        guard let parent = context.parent else { return (nil, line.text) }
        let asLine = Message(
            id: parent.id, type: parent.type, nick: parent.nick, text: parent.text,
            isSelf: parent.isSelf, userhost: parent.userhost
        )
        if !parent.isSelf, ignores.isMessageHidden(networkId: networkId, message: asLine, target: target, now: now) {
            return (nil, line.text)
        }
        let unwrapped = relayBots.reattributing([asLine], networkId: networkId).first ?? asLine
        let relayed = unwrapped.relayBot != nil
        let quote = ReplyQuote(
            id: parent.id,
            nick: unwrapped.nick ?? parent.nick,
            type: parent.type,
            text: unwrapped.text ?? parent.text,
            isSelf: relayed
                ? (ownNick.map { NickCompletion.sameNick($0, unwrapped.nick ?? "") } ?? false)
                : parent.isSelf,
            relayBot: unwrapped.relayBot,
            relaySource: unwrapped.relaySource
        )
        guard line.type == .message, let text = line.text else { return (quote, line.text) }
        var stripped = stripAddress(text, nick: quote.nick)
        if stripped == text, let bot = quote.relayBot { stripped = stripAddress(text, nick: bot) }
        return (quote, stripped)
    }

    /// `shown` over a list the screen is about to draw: every reply gets its quote and its
    /// stripped text, everything else passes through. Run after relay re-attribution, so a reply
    /// that came through a bridge is judged as the line it reads as.
    public static func presenting(
        _ messages: [Message], networkId: Int?, target: String,
        ignores: IgnoreSet, relayBots: RelayBotSet, ownNick: String?, now: Date = Date()
    ) -> [Message] {
        guard messages.contains(where: { $0.replyTo != nil }) else { return messages }
        return messages.map { line in
            guard let context = line.replyTo else { return line }
            let result = shown(
                context, line: line, networkId: networkId, target: target,
                ignores: ignores, relayBots: relayBots, ownNick: ownNick, now: now
            )
            return line.showingReply(quote: result.quote, text: result.text)
        }
    }

    /// Whether a reply should show its quote again, or is the next chunk of one already quoted:
    /// obby and goguma tag every chunk of a long reply where Lurker and halloy tag the first. Only
    /// while it reads as one run of the same speaker's lines (the caller's author run), answering
    /// the same msgid with the same kind of line. A divider, anyone else's line, or a later reply
    /// to the same line, and the quote shows again.
    public static func continues(_ line: Message, after previous: Message?) -> Bool {
        guard let previous, let mine = line.replyTo, let theirs = previous.replyTo else { return false }
        return mine.msgid == theirs.msgid
            && previous.type == line.type
            && previous.isSelf == line.isSelf
            && previous.relaySource == line.relaySource
            && NickCompletion.sameNick(previous.nick ?? "", line.nick ?? "")
    }

    /// The pending reply a Reply on `message` starts, drawn from the line as it's SHOWN — a relayed
    /// line as the person inside it, whom the Reply addresses and a cancel un-addresses.
    public static func pending(for message: Message, addressed: Bool = false) -> PendingReply {
        PendingReply(
            messageId: message.id,
            nick: message.nick ?? "",
            type: message.type,
            text: message.text ?? "",
            isSelf: message.isSelf,
            addressed: addressed
        )
    }
}
