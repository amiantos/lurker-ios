// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit
import UIKit

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

extension NetworkRow {
    /// Why Connect and Reconnect are missing on a blocked network — said once per screen,
    /// under the list or the section, because it explains a policy, and a policy repeated
    /// per row reads as a per-row problem.
    static let blockedExplanation = "This server's administrator limits which networks can be connected to."
}

extension UIListContentConfiguration {
    /// The status dot both screens lead with. The colour carries the state; the text beside
    /// it repeats the state for anyone who can't use colour.
    mutating func setStatusDot(_ light: StatusLight) {
        image = UIImage(systemName: "circle.fill")
        imageProperties.tintColor = Palette.color(for: light)
        imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 10)
    }
}
