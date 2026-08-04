// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// One entry in the user's buffer-favorites list — the Friends/Contacts successor.
///
/// The server owns ONE global ordered list spanning networks (`favorites-changed`
/// ships it wholesale, connect burst included); the UI renders it as two
/// kind-filtered sections — DMs under Friends, channels under Favorites. `bufferId`
/// is the identity (it survives renames); `target` is the server-canonical name at
/// the time the frame was composed, a display hint corrected by `buffer-renamed`.
public struct FavoriteEntry: Equatable, Sendable {
    public let networkId: Int
    public let target: String
    public let bufferId: Int

    public init(networkId: Int, target: String, bufferId: Int) {
        self.networkId = networkId
        self.target = target
        self.bufferId = bufferId
    }

    public var key: BufferKey { BufferKey(networkId: networkId, target: target) }
}
