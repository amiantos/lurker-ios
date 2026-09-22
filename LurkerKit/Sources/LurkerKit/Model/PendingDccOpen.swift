// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// A DCC chat this device opened or accepted, waiting for its `=nick` buffer so the app can go
/// there (lurker#270).
///
/// ⚠ It waits because the server doesn't answer the open with the buffer. It mints the row when it
/// writes the chat's first notice, and `open-buffer` can't make one (it reopens a `=nick` row it
/// has and otherwise does nothing). Going there before the row lands pops straight back: a chat
/// screen whose buffer is absent from a settled roster reads that as a close.
///
/// A separate, pure type for the reason `PendingJoins` is one: the rule is small, it has a way to
/// be wrong, and a test can drive it here where it can't reach a private frame handler.
struct PendingDccOpen: Equatable {

    /// How long to wait. The server writes its first notice as it acts, so the row is normally
    /// there in well under a second; past this, nobody is still watching for it.
    static let patience: TimeInterval = 15

    let key: BufferKey
    let deadline: Date

    init(networkId: Int, nick: String, now: Date) {
        key = BufferKey(networkId: networkId, target: DccChat.target(for: nick))
        deadline = now.addingTimeInterval(Self.patience)
    }

    enum Outcome: Equatable {
        case waiting
        /// Go there — the stored row's key, in the server's spelling of the name.
        case open(BufferKey)
        /// Stop waiting, and go nowhere.
        case expired
    }

    /// ⚠ The deadline FIRST. A row that lands after it belongs to a chat the user has stopped
    /// waiting for, and going there would pull them out of whatever they're reading now. Checked
    /// after the row, the limit only applied when nothing had arrived — and nothing prunes this
    /// between frames, so a row arriving a minute later still navigated.
    func settle(buffers: [String: Buffer], now: Date) -> Outcome {
        guard now <= deadline else { return .expired }
        if let row = buffers[key.id] { return .open(row.key) }
        return .waiting
    }
}
