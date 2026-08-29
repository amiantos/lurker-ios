// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// What one row of the networks screen says about a network, and what it therefore offers to
/// do to it (#11).
///
/// A model rather than a `switch` inside the view controller, for the same reason
/// `BufferListPlaceholder` and `StatusLight` are: which actions a row offers is a rule about
/// connection state, not about table cells, and it's the part with cases a person can get
/// wrong. The strings stay in the view controller — copy is the screen's business.
public enum NetworkRowStatus: Equatable, Sendable {
    case connected
    case connecting
    case reconnecting
    case disconnected
    /// The instance admin's allowlist excludes this network's host (#298). Its own case
    /// rather than a flag beside `disconnected`, because it changes what the row can do, not
    /// just what it says: the server refuses the connect, so offering one is offering nothing.
    case blocked

    /// Resolve a row's status. `blocked` outranks the connection: an off-list network may
    /// still be connected (the allowlist gates new connections, not existing ones), and in
    /// that state the fact worth leading with is that it can't come back if it drops.
    public static func of(connection: ConnectionState, blocked: Bool) -> NetworkRowStatus {
        if blocked { return .blocked }
        switch connection {
        case .connected: return .connected
        case .connecting: return .connecting
        case .reconnecting: return .reconnecting
        case .disconnected: return .disconnected
        }
    }

    /// The dot, sharing the buffer pill's three-state vocabulary so one colour means one
    /// thing across the app. Amber is "still trying", red is "not fixing itself".
    public var light: StatusLight {
        switch self {
        case .connected: .good
        case .connecting, .reconnecting: .warn
        case .disconnected, .blocked: .bad
        }
    }

    /// What this row offers, in the order it should be offered.
    ///
    /// Deliberately not "every action, some disabled". A disabled Connect on a blocked
    /// network reads as a thing the user could fix by tapping harder; the row's subtitle is
    /// where that story belongs. Delete is always available — a network you can't connect to
    /// is exactly one you might want gone — and always last, away from the rest.
    public var actions: [NetworkAction] {
        switch self {
        // Reconnect as well as disconnect: the connection is up, but a config change (or a
        // wedged connection that hasn't noticed) needs a way to cycle it.
        case .connected: [.disconnect, .reconnect, .delete]
        // Disconnect while an attempt is in flight is a cancel — the one thing worth being
        // able to do to a network that is stuck retrying.
        case .connecting, .reconnecting: [.disconnect, .delete]
        case .disconnected: [.connect, .delete]
        // No connect and no reconnect: the server refuses both (403), so the row would be
        // offering an action whose only outcome is an error message.
        case .blocked: [.delete]
        }
    }
}

/// One thing a networks-screen row can do. Editing isn't here: it's the row's own tap, not an
/// item in a menu of state changes.
public enum NetworkAction: Equatable, Sendable, CaseIterable {
    case connect
    case disconnect
    case reconnect
    case delete

    /// Whether this action destroys something the user can't get back. The screen owes these
    /// a confirmation; nothing else here needs one, since every other action is reversible by
    /// its opposite.
    public var isDestructive: Bool { self == .delete }
}
