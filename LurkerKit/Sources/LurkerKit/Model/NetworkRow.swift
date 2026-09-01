// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// What one row of the networks screen says about a network, and what it therefore offers to
/// do to it (#11).
///
/// A model rather than a `switch` inside the view controller, for the same reason
/// `BufferListPlaceholder` and `StatusLight` are: which actions a row offers is a rule about
/// connection state, not about table cells, and it's the part with cases a person can get
/// wrong. It's also the part you can't see in a screenshot — an action that shouldn't be
/// there is only found by tapping it and reading the server's refusal, and one that should be
/// there and isn't is found by needing it. The strings stay in the app target
/// (`NetworkCopy.swift`); copy is the screens' business.
public struct NetworkRow: Equatable, Sendable {
    public let connection: ConnectionState
    /// True when the instance admin's allowlist excludes this network's host (#298).
    ///
    /// ⚠⚠ An attribute of the row, **not** a status that replaces the connection. The
    /// allowlist gates *new* connections — `POST /:id/connect` and `/:id/reconnect` check it,
    /// `/:id/disconnect` does not — so a network can be blocked and connected at the same
    /// time, which is exactly what an admin tightening the list under a live connection
    /// produces. Modelled as a fifth status, it painted a red "not allowed here" over a
    /// network that was up and receiving messages, and withheld the one action the server
    /// would still have honoured. The web treats it as a tag beside the state for the same
    /// reason.
    public let isBlocked: Bool

    public init(connection: ConnectionState, isBlocked: Bool) {
        self.connection = connection
        self.isBlocked = isBlocked
    }

    /// The dot, sharing the buffer pill's three-state vocabulary so one colour means one
    /// thing across the app. Amber is "still trying", red is "not fixing itself".
    ///
    /// Follows the connection alone. Blocked is a fact about what this network can do *next*,
    /// not about whether it works now, and a row that is connected works now.
    public var light: StatusLight {
        switch connection {
        case .connected: .good
        case .connecting, .reconnecting: .warn
        case .disconnected: .bad
        }
    }

    /// What this row offers, in the order it should be offered.
    ///
    /// Deliberately not "every action, some disabled". A disabled Connect reads as a thing
    /// the user could fix by tapping harder; the row's own subtitle is where that story
    /// belongs. Delete is always available — a network you can't connect to is exactly one
    /// you might want gone — and always last, away from the action someone came to tap.
    public var actions: [NetworkAction] {
        var actions: [NetworkAction]
        switch connection {
        // Reconnect as well as disconnect: the connection is up, but a config change (or a
        // wedged connection that hasn't noticed) needs a way to cycle it.
        case .connected: actions = [.disconnect, .reconnect]
        // Disconnect while an attempt is in flight is a cancel — the one thing worth being
        // able to do to a network that is stuck retrying.
        case .connecting, .reconnecting: actions = [.disconnect]
        case .disconnected: actions = [.connect]
        }
        // The server answers connect and reconnect with 403 on an off-list host, so offering
        // either would be offering an action whose only outcome is an error message. It does
        // NOT gate disconnect, so that one survives — see `isBlocked`.
        if isBlocked { actions.removeAll { $0 == .connect || $0 == .reconnect } }
        actions.append(.delete)
        return actions
    }

    /// `actions` without the destructive one: what a surface that manages the *connection*
    /// but not the row offers — the server buffer's info sheet (#152). Deleting a network is
    /// the networks screen's business, where the confirmation and the roster re-read live.
    /// Can be empty (blocked and offline), and the surface says why rather than padding it.
    public var connectionActions: [NetworkAction] { actions.filter { !$0.isDestructive } }
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
