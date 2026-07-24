// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// A friend, as the server stores it.
///
/// "Friends" is the user-facing name; the wire and server call it a `contact`. A contact is
/// a *person*, network-agnostic — a display name plus a "toast me when they come online"
/// flag — with a set of `targets`, the (network, nick) pairs to watch. The same person can
/// be followed under different nicks on different networks (alts/ghosts), so presence and the
/// DM that opens on tap are resolved through the *primary* target, not the contact itself.
///
/// The list ships in the `contacts-snapshot` connect frame and is kept in sync by
/// `contact-updated` / `contact-deleted` echoes, so every device agrees; the client never
/// invents a contact locally.
public struct Contact: Equatable, Sendable, Identifiable {
    public let id: Int
    public let displayName: String
    /// Whether a came-online notification should fire for this friend (the per-friend opt-in;
    /// a global setting is the master switch).
    public let notifyOnline: Bool
    public let targets: [ContactTarget]

    public init(id: Int, displayName: String, notifyOnline: Bool, targets: [ContactTarget]) {
        self.id = id
        self.displayName = displayName
        self.notifyOnline = notifyOnline
        self.targets = targets
    }

    /// The target whose DM opens when the friend is tapped, and whose presence the row's dot
    /// shows: the one flagged primary, else the first. Nil only for a target-less contact
    /// (which the server won't create, but a defensive read shouldn't crash on).
    public var primaryTarget: ContactTarget? {
        targets.first(where: { $0.isPrimary }) ?? targets.first
    }
}

/// One (network, nick) a contact is watched under. `isPrimary` marks the single target whose
/// DM the friend row opens; the server guarantees exactly one primary per contact.
public struct ContactTarget: Equatable, Sendable {
    public let networkId: Int
    public let nick: String
    public let isPrimary: Bool

    public init(networkId: Int, nick: String, isPrimary: Bool) {
        self.networkId = networkId
        self.nick = nick
        self.isPrimary = isPrimary
    }
}
