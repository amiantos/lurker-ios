// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// What a toast surface can flash for a few seconds: the chat screen's status row, or the capsule
/// over the buffer list.
public enum StatusToast: Equatable, Sendable {
    /// Something in another conversation; a tap goes there.
    case notification(StatusNotification)
    /// Something you just did that didn't work: "Not connected — try again when you're back
    /// online". A tap just clears it.
    case notice(String)

    public var isNotification: Bool {
        if case .notification = self { true } else { false }
    }

    /// The same person, buffer and kind — or the same notice. What a newer toast updates in
    /// place rather than queueing behind.
    public func sameSource(as other: StatusToast) -> Bool {
        switch (self, other) {
        case let (.notification(a), .notification(b)):
            a.key.id == b.key.id && a.kind == b.kind
                && a.nick?.lowercased() == b.nick?.lowercased()
        case let (.notice(a), .notice(b)):
            a == b
        default:
            false
        }
    }
}

/// The toast showing now, and the ones waiting their turn, oldest first. One surface shows one
/// at a time; the surface owns the timing and asks this what comes next.
///
/// - A newer line from the same person in the same buffer updates their toast where it is,
///   showing or waiting, rather than queueing behind it or being dropped: a burst (ChanServ
///   answering /HELP) is one toast that reads its latest line. It doesn't buy more time.
/// - A notice is about something you just did, so it goes first, and a notification showing
///   gives way to it.
public struct StatusToastQueue: Sendable {
    /// How many notifications may wait. Past it the oldest goes: its line is still in its
    /// buffer, and the highlight counts still show it.
    public static let cap = 3
    /// How long a toast holds the surface.
    public static let hold: TimeInterval = 4
    /// Shorter while others wait, so a burst drains rather than backing up.
    public static let holdBusy: TimeInterval = 2.5

    public private(set) var active: StatusToast?
    public private(set) var waiting: [StatusToast] = []

    public init() {}

    /// What `offer` did, and so what the surface has to do about it.
    public enum Offer: Equatable, Sendable {
        /// The toast showing was replaced in place: redraw and announce it, keep its timer.
        case updatedActive
        /// A waiting toast was replaced in place: nothing to do yet.
        case updatedWaiting
        /// A notice took over from the notification showing: stop its timer, then present.
        case preemptedActive
        /// Added to the queue: present, if the surface is free.
        case queued
    }

    public mutating func offer(_ toast: StatusToast) -> Offer {
        if let active, active.sameSource(as: toast) {
            self.active = toast
            return .updatedActive
        }
        if let index = waiting.firstIndex(where: { $0.sameSource(as: toast) }) {
            waiting[index] = toast
            return .updatedWaiting
        }
        if case .notice = toast {
            waiting.insert(toast, at: 0)
            if case .notification? = active {
                active = nil
                return .preemptedActive
            }
            return .queued
        }
        waiting.append(toast)
        while waiting.filter(\.isNotification).count > Self.cap,
              let oldest = waiting.firstIndex(where: \.isNotification) {
            waiting.remove(at: oldest)
        }
        return .queued
    }

    /// Make the next waiting toast the active one, with how long it should hold. Nil while one
    /// is already showing or nothing waits.
    public mutating func presentNext() -> (toast: StatusToast, hold: TimeInterval)? {
        guard active == nil, !waiting.isEmpty else { return nil }
        let next = waiting.removeFirst()
        active = next
        return (next, waiting.isEmpty ? Self.hold : Self.holdBusy)
    }

    /// The active toast ran out its time, or was tapped.
    public mutating func endActive() {
        active = nil
    }

    /// Put the active toast back at the front, to be shown in full later — the completion chips
    /// took the row before it had its time.
    public mutating func requeueActive() {
        guard let active else { return }
        self.active = nil
        waiting.insert(active, at: 0)
    }

    /// Drop whatever waits: passing news, gone stale while nobody could see it.
    public mutating func dropWaiting() {
        waiting.removeAll()
    }
}
