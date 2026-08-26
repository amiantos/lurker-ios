// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Which composer line a `send-result` is answering.
///
/// The server acknowledges a send by echoing back the `clientId` the request carried, and nothing
/// else — not the buffer, not the text. So the correlation has to be held here, and it is the only
/// thing that knows how to give a refused line back to the person who typed it (#128).
///
/// ⚠⚠ A separate type, and pure, because the alternative is a dictionary inside `ChatViewModel`
/// reachable only through a private frame handler — untestable, which is how the last round of
/// this subsystem shipped a rule nobody could exercise. The invariants below are small and each
/// one has a way to be wrong; they belong somewhere a test can drive them.
struct UnsentCorrelator {

    /// The buffer a line was TYPED IN, and the line AS TYPED.
    ///
    /// ⚠⚠ Neither is recoverable from the wire verb, which is the whole reason to keep them.
    /// `/msg bob hi` typed in `#chat` puts `hi` on the wire addressed to `bob` — so the verb's
    /// target is the DM, while the composer that should get the text back belongs to `#chat`, and
    /// the text to give back is the whole `/msg bob hi` rather than the `hi` that went out.
    /// Restoring the payload to the destination would strand a fragment in the wrong conversation.
    struct Origin: Equatable {
        let key: BufferKey
        let line: String
    }

    private var inFlight: [String: Origin] = [:]
    private var seq = 0

    /// Whether anything is waiting on an answer. Test seam for the leak the removals prevent.
    var pendingCount: Int { inFlight.count }

    /// Mint a correlator for one composer line and remember where it came from.
    ///
    /// ⚠ Per LINE, not per wire verb. One command can put several sends on the wire, and the
    /// caller is expected to share this id across them: there is one line in the composer to give
    /// back, so it should come back once.
    ///
    /// A counter rather than a UUID — it only has to be unique within a socket's lifetime, and a
    /// readable id is worth something in a frame log.
    mutating func track(_ key: BufferKey, line: String) -> String {
        seq += 1
        let id = "ios-\(seq)"
        inFlight[id] = Origin(key: key, line: line)
        return id
    }

    /// Answer a `send-result`: the line to give back, or nil if there is nothing to do.
    ///
    /// ⚠⚠ Forgets the entry on EITHER verdict. A success has nothing to restore, but leaving its
    /// entry behind grows the map for the life of the socket — and the second refusal of a line
    /// whose siblings already resolved must not restore it twice.
    ///
    /// Nil for an unknown id, which covers both the second answer to a multi-send line and any
    /// ack this client never asked for.
    mutating func resolve(clientId: String?, ok: Bool) -> Origin? {
        guard let clientId, let origin = inFlight.removeValue(forKey: clientId) else { return nil }
        return ok ? nil : origin
    }

    /// Follow a buffer rename, so a line still in flight comes home to the surviving buffer.
    ///
    /// ⚠⚠ An `Origin` captured before a rename holds the OLD key, and a rename landing between a
    /// send and its ack is exactly when this matters. The screen follows the rename, so it only
    /// ever asks for the new key — a hold written under the old one is unreachable forever and
    /// the line is lost silently. `ChatState.rekeyBuffer` moves the holds already written; this
    /// moves the ones not written yet, and both are needed to cover the window.
    mutating func rekey(from: BufferKey, to: BufferKey) {
        for (id, origin) in inFlight where origin.key == from {
            inFlight[id] = Origin(key: to, line: origin.line)
        }
    }

    /// Give up on everything outstanding — the socket died, so no answer is coming.
    ///
    /// ⚠⚠ Deliberately does NOT hand the lines back, and that is a choice between two bad
    /// outcomes. A send the socket died under may or may not have reached IRC; the ack is exactly
    /// what would have said, and it is what is not coming. Restoring risks the user sending the
    /// same line twice, to a channel, with no way to take it back. Not restoring risks losing a
    /// line. Duplicate-in-public is the worse one, and it is the call the web makes too.
    mutating func abandonAll() {
        inFlight.removeAll()
    }
}
