// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit

/// The words for a network's connection and for the verbs that change it.
///
/// Shared by the networks screen and the server buffer's info sheet (#152) — the same
/// connection is managed from both, and "Offline" and "Disconnect" mustn't drift between
/// them. `NetworkRow` keeps the rule about which verbs a state offers; this keeps the copy,
/// which is the split that model's doc comment asks for, lifted out of the one screen once
/// there were two.
extension ConnectionState {
    var label: String {
        switch self {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .reconnecting: "Reconnecting…"
        case .disconnected: "Offline"
        }
    }
}

extension NetworkAction {
    var title: String {
        switch self {
        case .connect: "Connect"
        case .disconnect: "Disconnect"
        case .reconnect: "Reconnect"
        case .delete: "Delete"
        }
    }

    var symbolName: String {
        switch self {
        case .connect: "bolt"
        case .disconnect: "bolt.slash"
        case .reconnect: "arrow.clockwise"
        case .delete: "trash"
        }
    }
}
