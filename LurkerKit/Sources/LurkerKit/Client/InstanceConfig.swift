// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

/// What `GET /api/config` says about the instance: its feature flags, and the protocol it
/// speaks.
struct InstanceConfig: Equatable, Sendable {
    var features = InstanceFeatures()
    /// The protocol the server speaks. Nil when it didn't say.
    var protocolVersion: Int?
    /// The oldest client protocol the server still serves. Nil when it didn't say.
    var minProtocolVersion: Int?

    /// Whether this build can talk to the server, going by what the server advertised (#17).
    var incompatibility: Incompatibility? {
        ProtocolVersion.incompatibility(serverVersion: protocolVersion, serverMinimum: minProtocolVersion)
    }
}
