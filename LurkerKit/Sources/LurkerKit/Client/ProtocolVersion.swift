// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// Why this app and the server it's signed in to can't talk (#17).
///
/// An App Store build makes both of these ordinary: people take app updates when the store
/// offers them, and update a self-hosted server whenever they get to it. The server's half of
/// the contract is lurker's `server/protocol.ts`.
public enum Incompatibility: Equatable, Sendable {
    /// The server no longer serves the protocol this build speaks. An app update fixes it.
    case appTooOld
    /// The server speaks an older protocol than this build supports. A server update fixes it.
    case serverTooOld
}

/// The protocol version this build speaks, and the check against what a server advertises.
///
/// The server bumps its version only for a change its additive-only rule can't express, which
/// is meant to be never. So both numbers are 1, and nothing here fires against any server that
/// exists today. It ships anyway, because what a build announces is fixed the day it ships: a
/// build that never sent `?v` is one every future server has to treat as current.
enum ProtocolVersion {
    /// Announced as `?v=` on every socket upgrade. A server whose `minProtocolVersion` is higher
    /// refuses the upgrade with 426.
    static let spoken = 1

    /// The oldest server protocol this build works with. Raise it only when this build has
    /// dropped something an older server needs.
    static let oldestServer = 1

    /// Compare what `/api/config` advertises with this build. Nil when they can talk, and when
    /// the server didn't say: a missing field is not a version.
    ///
    /// `spoken` and `oldestServer` are parameters so both directions can be tested while both
    /// constants are 1.
    static func incompatibility(
        serverVersion: Int?,
        serverMinimum: Int?,
        spoken: Int = ProtocolVersion.spoken,
        oldestServer: Int = ProtocolVersion.oldestServer
    ) -> Incompatibility? {
        if let serverMinimum, serverMinimum > spoken { return .appTooOld }
        if let serverVersion, serverVersion < oldestServer { return .serverTooOld }
        return nil
    }
}
