// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// The indicator light shown in a buffer's title pill, mirroring the web client's
/// `.indicator` dots (`good` / `warn` / `bad`).
///
/// Three states, not two: amber is the honest default while something is still trying,
/// and it's what the web client shows for a connecting/reconnecting network. Red is
/// reserved for "this is actually broken and isn't fixing itself".
public enum StatusLight: Equatable, Sendable {
    case good
    case warn
    case bad
}

extension StatusLight {
    /// Resolve the light for a buffer.
    ///
    /// The layers are checked outside-in, because an outer failure makes every inner
    /// state meaningless:
    ///  1. **No network path at all** → red. Nothing else can be true, and it's the one
    ///     failure the user can act on (turn on wifi).
    ///  2. **The Lurker socket** → amber while connecting/reconnecting. Note there's no
    ///     red here: a dropped socket is always retrying, so it's amber, not broken.
    ///  3. **The IRC network** → green connected, amber connecting/reconnecting, red
    ///     disconnected. Red means the server gave up and isn't coming back on its own.
    ///
    /// `network` is nil for the system buffer, whose whole story is the socket — so once
    /// the socket is up, it's green.
    ///
    /// DM buffers deliberately pass their *network's* state like a channel does. Real
    /// peer presence ("is this nick online right now") is 1.1 (APP_1.0_SCOPE.md defers
    /// it), and it slots into this same dot as an extra inner layer without a redesign.
    public static func of(
        reachable: Bool,
        connection: SocketStatus,
        network: ConnectionState?
    ) -> StatusLight {
        guard reachable else { return .bad }
        switch connection {
        case .connecting, .reconnecting: return .warn
        case .connected: break
        }
        guard let network else { return .good }
        switch network {
        case .connected: return .good
        case .connecting, .reconnecting: return .warn
        case .disconnected: return .bad
        }
    }
}
