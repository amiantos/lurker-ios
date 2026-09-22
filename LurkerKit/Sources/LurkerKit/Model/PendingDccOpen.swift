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

    /// Whether this is the wait for a chat with `nick` on that network — folded, as `BufferKey` is.
    func isFor(networkId: Int, nick: String) -> Bool {
        key.id == BufferKey(networkId: networkId, target: DccChat.target(for: nick)).id
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

/// The DCC chats this device asked to open, from the request until the app has gone there — the
/// bookkeeping around `PendingDccOpen`, kept pure so a test can drive the races.
///
/// Every open takes a number, and only the reply to the LATEST one may install a wait. That one
/// rule settles three races:
///  - two opens whose replies come back out of order: the earlier request's late reply is stale,
///    so it can't take the user to the chat they asked for first;
///  - a reply that outlives the session: `reset` moves the number on, so an open sent before a
///    sign-out can't install a wait into whoever signs in next;
///  - a close that beats an open still in flight: `closing` moves the number on when the open in
///    flight is for the chat being closed.
///
/// ⚠ ONE wait, deliberately. A second open replaces the first: there is one screen to land on, and
/// the chat asked for last is the one the user is looking for.
///
/// ⚠⚠ A close does its bookkeeping BEFORE its request goes out, not when the reply comes back. The
/// server writes "Cancelled…" into `=nick` as it acts, over the socket, and that frame usually
/// lands before the HTTP reply — so marking on the reply let the notice mint the row and satisfy
/// the wait first, taking the user into the chat they had just ended. A refused close puts the wait
/// back (`closeRefused`).
struct DccOpens {
    /// An open request, as the reply to it will present itself.
    struct Ticket: Equatable {
        fileprivate let number: Int
        fileprivate let networkId: Int
        fileprivate let nick: String
    }

    /// What a close took away, for putting back if the server refuses it.
    struct CloseMark: Equatable {
        fileprivate let number: Int
        fileprivate let waiting: PendingDccOpen?
    }

    private(set) var waiting: PendingDccOpen?
    /// The latest open request's number — or a number no request holds, once something has made
    /// every request so far stale.
    private var latest = 0
    /// The chat the latest open request is for, while it's still in flight.
    private var inFlight: BufferKey?

    /// An open is about to go out.
    mutating func begin(networkId: Int, nick: String) -> Ticket {
        latest += 1
        inFlight = Self.key(networkId, nick)
        return Ticket(number: latest, networkId: networkId, nick: nick)
    }

    /// An open succeeded: wait for its row, if nothing has overtaken it.
    mutating func opened(_ ticket: Ticket, now: Date) {
        guard ticket.number == latest else { return }
        inFlight = nil
        waiting = PendingDccOpen(networkId: ticket.networkId, nick: ticket.nick, now: now)
    }

    /// A close is about to go out: stop waiting for that chat, and make an open for it that is
    /// still in flight stale.
    mutating func closing(networkId: Int, nick: String) -> CloseMark {
        let key = Self.key(networkId, nick)
        if inFlight?.id == key.id {
            latest += 1
            inFlight = nil
        }
        let taken = waiting?.isFor(networkId: networkId, nick: nick) == true ? waiting : nil
        if taken != nil { waiting = nil }
        return CloseMark(number: latest, waiting: taken)
    }

    /// The server refused the close, so the chat is still coming: put back the wait it took —
    /// unless the user has asked for something else since.
    mutating func closeRefused(_ mark: CloseMark) {
        guard let taken = mark.waiting, waiting == nil, latest == mark.number else { return }
        waiting = taken
    }

    /// Sign-out: nothing asked for in this session may land in the next one.
    mutating func reset() {
        latest += 1
        inFlight = nil
        waiting = nil
    }

    /// The buffer to go to, if the wait just ended in one. Clears the wait either way it ends.
    mutating func settle(buffers: [String: Buffer], now: Date) -> BufferKey? {
        guard let pending = waiting else { return nil }
        switch pending.settle(buffers: buffers, now: now) {
        case .waiting:
            return nil
        case .expired:
            waiting = nil
            return nil
        case .open(let key):
            waiting = nil
            return key
        }
    }

    private static func key(_ networkId: Int, _ nick: String) -> BufferKey {
        BufferKey(networkId: networkId, target: DccChat.target(for: nick))
    }
}
