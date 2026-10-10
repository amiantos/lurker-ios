// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// An in-app notification: a live line the server says to alert about, while the app is open.
/// The foreground half of the same intent push serves in the background — the server holds push
/// back while a client is visible, so without this an open app says nothing at all.
///
/// A port of the web's `useHighlightNotifier` decision: trust the server's `notify` verdict, pick
/// the kind (kicked > DM > highlight > always-notify), and gate on that kind's
/// `notifications.<kind>.enabled` master toggle.
public struct StatusNotification: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case kicked
        case dm
        case highlight
        case alwaysNotify = "always_notify"
        /// A friend — the peer of a favorited DM — came online. No line behind it.
        case friendOnline = "friend_online"
    }

    public let id = UUID()
    public let kind: Kind
    public let key: BufferKey
    public let nick: String?
    /// Plain text, formatting stripped — a glance, not the message view.
    public let text: String
    public let messageId: Int
    public let date: Date

    /// The notification for `message`, or nil when it isn't one: not flagged, our own line, or
    /// its kind switched off.
    public static func make(
        networkId: Int?, target: String, message: Message, settings: Settings, now: Date = Date()
    ) -> StatusNotification? {
        guard message.notify, !message.isSelf, let networkId else { return nil }
        let kind: Kind
        if message.selfKicked { kind = .kicked }
        else if message.dm { kind = .dm }
        else if message.matched { kind = .highlight }
        else if message.notifyAlways { kind = .alwaysNotify }
        else { return nil }
        // Every kind defaults on in the registry.
        guard settings.bool("notifications.\(kind.rawValue).enabled", default: true) else { return nil }
        return StatusNotification(
            kind: kind,
            key: BufferKey(networkId: networkId, target: target),
            nick: message.nick,
            text: IRCFormatting.strip(message.text ?? ""),
            messageId: message.id,
            date: message.date ?? now
        )
    }

    /// A friend coming online, from a `peer-presence` frame read against the state BEFORE it
    /// applies (the web's came-online toast). Only a witnessed offline→online flip counts: the
    /// server also states a peer's current presence when MONITOR is first seeded and whenever a
    /// nick is added to the watch, and an `online` there is not someone arriving.
    static func cameOnline(_ frame: ServerFrame, before state: ChatState, now: Date = Date()) -> StatusNotification? {
        guard case .peerPresence(let networkId, let nick, .online?) = frame,
              state.peerPresence[networkId]?[nick.lowercased()] == .offline
        else { return nil }
        let key = BufferKey(networkId: networkId, target: nick)
        guard state.isFavorite(key),
              state.settings.bool("notifications.\(Kind.friendOnline.rawValue).enabled", default: true)
        else { return nil }
        return StatusNotification(kind: .friendOnline, key: key, nick: nick, text: "", messageId: 0, date: now)
    }

    /// Which bundled sound this kind plays, or nil when its sound is off. The web's
    /// `notifications.<kind>.sound.enabled` and `.choice`, with the registry's defaults for the
    /// moment before bootstrap — always-notify and kick sound by default, the rest don't, and each
    /// kind has its own default sound so they can be told apart by ear. A volume of 0 is silence.
    public func sound(in settings: Settings) -> String? {
        Self.sound(for: kind, in: settings)
    }

    /// `sound(in:)` for a kind — what the settings screen shows as the sound in force, so the row
    /// reads exactly what will play.
    public static func sound(for kind: Kind, in settings: Settings) -> String? {
        let (enabled, choice): (Bool, String) = switch kind {
        case .highlight: (false, "ping")
        case .dm: (false, "chime")
        case .friendOnline: (false, "knock")
        case .alwaysNotify: (true, "plink")
        case .kicked: (true, "beep")
        }
        let prefix = "notifications.\(kind.rawValue).sound"
        guard settings.bool("\(prefix).enabled", default: enabled),
              settings.int("\(prefix).volume", default: 60) > 0
        else { return nil }
        let picked = settings.string("\(prefix).choice", default: choice)
        return sounds.contains(picked) ? picked : choice
    }

    /// The bundled sounds, the registry's `sound.choice` enum.
    public static let sounds: Set<String> = ["ping", "chime", "pop", "beep", "knock", "plink"]

    public static func == (lhs: StatusNotification, rhs: StatusNotification) -> Bool { lhs.id == rhs.id }
}
