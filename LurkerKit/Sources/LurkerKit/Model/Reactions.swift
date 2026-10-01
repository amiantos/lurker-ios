// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// One IRCv3 reaction (`+draft/react`) standing on a line, as it rides a message row: who, what,
/// and whether it's ours (lurker#990, iOS #183).
public struct MessageReaction: Equatable, Sendable {
    public let nick: String
    /// An emoji or a short bit of text — the spec allows either, and IRC people use both.
    public let value: String
    /// Ours, from any of our clients. ⚠ Judged by the server, never by comparing `nick` to our
    /// own: a reaction given before a nick change is still ours, and only this flag says so.
    public let isSelf: Bool

    public init(nick: String, value: String, isSelf: Bool) {
        self.nick = nick
        self.value = value
        self.isSelf = isSelf
    }
}

/// One chip on a line: a value, everyone who reacted with it (first-reacted first), and whether
/// we're among them.
public struct ReactionGroup: Equatable, Sendable {
    public let value: String
    public var nicks: [String]
    public var mine: Bool

    public init(value: String, nicks: [String], mine: Bool) {
        self.value = value
        self.nicks = nicks
        self.mine = mine
    }
}

/// A live `reaction` frame: one reaction added or taken back on the line `messageId`.
public struct ReactionChange: Equatable, Sendable {
    public let networkId: Int
    public let target: String
    public let messageId: Int
    public let nick: String
    public let value: String
    public let isSelf: Bool
    public let remove: Bool
    /// The line is ours, so this belongs in the activity feed.
    public let toSelf: Bool

    public init(
        networkId: Int, target: String, messageId: Int, nick: String, value: String,
        isSelf: Bool, remove: Bool, toSelf: Bool
    ) {
        self.networkId = networkId
        self.target = target
        self.messageId = messageId
        self.nick = nick
        self.value = value
        self.isSelf = isSelf
        self.remove = remove
        self.toSelf = toSelf
    }
}

/// The rules about reactions that don't belong to any one screen.
public enum Reactions {

    /// The picks a reaction sheet offers before anything is typed — the web's list, so the two
    /// clients nudge people toward the same handful.
    public static let quickPicks = ["👍", "❤️", "😂", "🎉", "😮", "😢", "👀", "🙏"]

    /// The server's `MAX_REACTION_GRAPHEMES`. Longer values are dropped, not truncated, on the
    /// way in from the network (halloy's rule), and refused on the way out.
    public static let maxGraphemes = 64

    /// How many of each buffer's newest lines a resume re-reads, and how many in all — the
    /// latter is the server's `MAX_REACTION_SYNC_IDS`, past which it ignores the rest.
    public static let syncPerBuffer = 200
    public static let syncMaxIds = 5000

    /// Whether `value` can go out as a reaction: something visible, on one line, no longer than
    /// the server takes. Swift's `count` is grapheme clusters, which is the unit the server
    /// counts in, so a flag or a family emoji is one.
    public static func isValidValue(_ value: String) -> Bool {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard !value.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) else { return false }
        return value.count <= maxGraphemes
    }

    /// Reactions grouped by value for display: groups in the order their first reaction arrived,
    /// nicks within a group the same.
    public static func groups(_ list: [MessageReaction]) -> [ReactionGroup] {
        var groups: [ReactionGroup] = []
        for reaction in list {
            if let index = groups.firstIndex(where: { $0.value == reaction.value }) {
                groups[index].nicks.append(reaction.nick)
                if reaction.isSelf { groups[index].mine = true }
            } else {
                groups.append(ReactionGroup(value: reaction.value, nicks: [reaction.nick], mine: reaction.isSelf))
            }
        }
        return groups
    }

    /// Whether a line can carry reactions at all — the chat lines a reaction can name, on a
    /// network. Not the same as being able to *send* one: a notice someone else's client reacted
    /// to still shows its chips, and so does an encrypted line (see `canSend`).
    public static func canCarry(_ message: Message, networkId: Int?) -> Bool {
        message.id != 0 && networkId != nil
            && (message.type == .message || message.type == .action || message.type == .notice)
    }

    /// Whether this client may send a reaction on `message`: a `message`/`action` the server
    /// named with a msgid, in a channel or DM, not end-to-end encrypted. The server re-checks all
    /// of it (`reactionSendTarget`) and refuses in silence — so this is what keeps a control off a
    /// line where it could only do nothing. `networkCanReact` is `ChatState.canReact`.
    public static func canSend(on message: Message, target: String, networkCanReact: Bool) -> Bool {
        networkCanReact && lineTakes(message, target: target)
    }

    /// The line half of `canSend`: whether this line could ever take a reaction from here,
    /// whatever the network is doing right now. False for a notice, an encrypted line, a line
    /// with no msgid, or one outside a channel or DM — which is what says to the sheet whether
    /// to blame the line or the network, and to the row whether to offer an add chip at all.
    public static func lineTakes(_ message: Message, target: String) -> Bool {
        message.id != 0
            && !(message.msgid ?? "").isEmpty
            && !message.isE2E
            && (message.type == .message || message.type == .action)
            && isConversation(target)
    }

    /// What `/react` lands on: the last line someone else said here — and when THAT one can't
    /// take a reaction, why not, rather than quietly reaching back to an older line the user
    /// never meant (an encrypted run, a trailing notice, a line with no msgid). The web's rule.
    public static func commandTarget(in messages: [Message]) -> Result<Message, CommandRefusal> {
        guard let line = messages.last(where: {
            $0.id != 0 && !$0.isSelf && ($0.type == .message || $0.type == .action || $0.type == .notice)
        }) else { return .failure(CommandRefusal("nothing here to react to")) }
        if line.type == .notice { return .failure(CommandRefusal("can't react to a notice")) }
        if line.isE2E { return .failure(CommandRefusal("can't react to an encrypted line")) }
        if (line.msgid ?? "").isEmpty { return .failure(CommandRefusal("can't react to that line (no message id)")) }
        return .success(line)
    }

    /// Why `/react` found nothing to land on, in the words the buffer prints.
    public struct CommandRefusal: Error, Equatable {
        public let text: String
        public init(_ text: String) { self.text = text }
    }

    /// A channel or a DM — an IRC target a tag can ride to. Not the `:server:` console, the
    /// app-scoped system buffer, or a `=nick` DCC chat, none of which a TAGMSG can reach.
    public static func isConversation(_ target: String) -> Bool {
        !target.isEmpty && !target.hasPrefix(":") && !DccChat.isTarget(target)
    }
}
