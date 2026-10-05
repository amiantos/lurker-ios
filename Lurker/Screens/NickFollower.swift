// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import LurkerKit

/// A person's profile following them through a nick change.
///
/// Pages about a buffer follow a rename by its id (`ChatViewController.handleBufferDisappeared`),
/// but a person's page is keyed by a nick, which has no id. Their conversation does: a DM or DCC
/// chat's rename IS their nick change, so the page follows that buffer's id through `keysById`.
/// Left on the old nick, the profile's whois said they'd gone. (Android's `DialogRenames.nick`,
/// which follows the same renames.)
///
/// ⚠⚠ The note editor does NOT follow. The server keeps a nick note under the nick it was written
/// for (`NICK_KEYED_TABLES` in lurker's `server/db/bufferKeyedTables.ts`), so the note on screen is
/// still the old nick's row: following would make Delete miss it and Save write a second one.
///
/// ⚠ Someone with no conversation open has no rename to follow — the same limit as Android's.
struct NickFollower {
    let networkId: Int
    private(set) var nick: String
    /// Their conversation's id, once one exists — looked for again on every state until it does,
    /// since a DM can be opened while the page is up.
    private var bufferId: Int?

    init(state: ChatState, networkId: Int, nick: String) {
        self.networkId = networkId
        self.nick = nick
        bufferId = Self.conversationId(state, networkId: networkId, nick: nick)
    }

    /// True when the person's conversation now names them differently, which `nick` holds now.
    mutating func follow(_ state: ChatState) -> Bool {
        guard let id = bufferId else {
            bufferId = Self.conversationId(state, networkId: networkId, nick: nick)
            return false
        }
        guard let key = state.keysById[id], let buffer = state.buffers[key],
              buffer.kind == .dm || buffer.kind == .dcc
        else { return false }
        let peer = DccChat.peer(buffer.target)
        // Folded, as the buffer key is: a profile opened as `Bob` over a DM keyed `bob` is no
        // rename.
        guard peer.lowercased() != nick.lowercased() else { return false }
        nick = peer
        return true
    }

    private static func conversationId(_ state: ChatState, networkId: Int, nick: String) -> Int? {
        for target in [nick, DccChat.target(for: nick)] {
            if let id = state.buffers[BufferKey(networkId: networkId, target: target).id]?.bufferId { return id }
        }
        return nil
    }
}
