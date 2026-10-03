// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// A buffer this device asked to open, waiting for its row so the app can go there: a DCC chat
/// opened or accepted (lurker#270), or a DM or query (iOS #201).
///
/// ⚠ It waits because asking for a buffer doesn't put a row in the store. A DM's `open-buffer` is
/// a write whose answer, the `backlog` that mints the row, comes back later on the socket. A DCC
/// chat's open gets no buffer at all: the server mints the row when it writes the chat's first
/// notice, and `open-buffer` can't make one (it reopens a `=nick` row it has and otherwise does
/// nothing). Going there before the row lands pops straight back: a chat screen whose buffer is
/// absent from a settled roster reads that as a close.
///
/// A separate, pure type for the reason `PendingJoins` is one: the rule is small, it has a way to
/// be wrong, and a test can drive it here where it can't reach a private frame handler.
struct PendingOpen: Equatable {

    /// How long to wait. The server answers an open as it acts, so the row is normally there in
    /// well under a second; past this, nobody is still watching for it.
    static let patience: TimeInterval = 15

    let key: BufferKey
    let deadline: Date

    init(key: BufferKey, now: Date) {
        self.key = key
        deadline = now.addingTimeInterval(Self.patience)
    }

    /// Whether this is the wait for `key` — folded, as `BufferKey.id` is.
    func isFor(_ key: BufferKey) -> Bool {
        self.key.id == key.id
    }

    enum Outcome: Equatable {
        case waiting
        /// Go there — the stored row's key, in the server's spelling of the name.
        case open(BufferKey)
        /// Stop waiting, and go nowhere.
        case expired
    }

    /// ⚠ The deadline FIRST. A row that lands after it belongs to a buffer the user has stopped
    /// waiting for, and going there would pull them out of whatever they're reading now. Checked
    /// after the row, the limit only applied when nothing had arrived — and nothing prunes this
    /// between frames, so a row arriving a minute later still navigated.
    ///
    /// Looked up by `BufferKey.id`, the way the store resolves every buffer, so a DM asked for as
    /// `Bob` is satisfied by the server's `bob` row and goes there under that name.
    func settle(buffers: [String: Buffer], now: Date) -> Outcome {
        guard now <= deadline else { return .expired }
        if let row = buffers[key.id] { return .open(row.key) }
        return .waiting
    }
}

/// The buffers this device asked to open, from the request until the app has gone there — the
/// bookkeeping around `PendingOpen`, kept pure so a test can drive the races.
///
/// Every open takes a number, and only the reply to the LATEST one may install a wait. That one
/// rule settles three races:
///  - two opens whose replies come back out of order: the earlier request's late reply is stale,
///    so it can't take the user to the chat they asked for first;
///  - a reply that outlives the session: `cancel` moves the number on, so an open sent before a
///    sign-out can't install a wait into whoever signs in next;
///  - a close that beats an open still in flight: `closing` moves the number on when the open in
///    flight is for the chat being closed.
///
/// A DM has no reply to wait for — its `open-buffer` goes out on the socket and the row is the
/// answer — so it takes its number and installs its wait in one step (`waitFor`). Taking the
/// number is still the point: a DCC open still in flight is then stale, because the DM was asked
/// for after it.
///
/// ⚠ ONE wait, deliberately, shared by DMs and DCC chats. A second open replaces the first: there
/// is one screen to land on, and the buffer asked for last is the one the user is looking for. It
/// replaces it as it is ASKED (`begin`), not when its reply comes back — a wait left standing
/// meanwhile could land, and the newer open's reply would then yank the user on a second time.
/// For the same reason the view model `cancel`s this for a join that opens, and for the user's own
/// move to a buffer.
///
/// ⚠⚠ A close does its bookkeeping BEFORE its request goes out, not when the reply comes back. The
/// server writes "Cancelled…" into `=nick` as it acts, over the socket, and that frame usually
/// lands before the HTTP reply — so marking on the reply let the notice mint the row and satisfy
/// the wait first, taking the user into the chat they had just ended. A refused close puts the wait
/// back (`closeRefused`).
struct PendingOpens {
    /// An open request, as the reply to it will present itself.
    struct Ticket: Equatable {
        fileprivate let number: Int
        fileprivate let key: BufferKey
    }

    /// What a close took away, for putting back if the server refuses it.
    struct CloseMark: Equatable {
        fileprivate let number: Int
        fileprivate let waiting: PendingOpen?
    }

    private(set) var waiting: PendingOpen?
    /// The latest open request's number — or a number no request holds, once something has made
    /// every request so far stale.
    private var latest = 0
    /// The buffer the latest open request is for, while it's still in flight.
    private var inFlight: BufferKey?

    /// What it takes to open `key` and go there.
    enum Plan: Equatable {
        /// Nothing: we're already waiting for it. A re-tap must not send another `open-buffer`,
        /// which every other device is told about, nor restart the clock.
        case alreadyWaiting
        /// No write — the row is here, and `open-buffer` is a write the server refuses outright
        /// for a paused account. Just go.
        case show
        /// Ask for it, then wait for the row.
        case write
    }

    /// See `Plan`. `held` is whether the store has the row; a wait past its deadline is no wait.
    func plan(_ key: BufferKey, held: Bool, now: Date) -> Plan {
        if let waiting, waiting.isFor(key), now <= waiting.deadline { return .alreadyWaiting }
        return held ? .show : .write
    }

    /// An open is about to go out. It replaces any wait still standing — see the type's note.
    mutating func begin(_ key: BufferKey) -> Ticket {
        latest += 1
        inFlight = key
        waiting = nil
        return Ticket(number: latest, key: key)
    }

    /// An open succeeded: wait for its row, if nothing has overtaken it.
    mutating func opened(_ ticket: Ticket, now: Date) {
        guard ticket.number == latest else { return }
        inFlight = nil
        waiting = PendingOpen(key: ticket.key, now: now)
    }

    /// An open that is answered by its row alone — a DM's `open-buffer` (iOS #201): wait for it
    /// now, as the latest request.
    mutating func waitFor(_ key: BufferKey, now: Date) {
        opened(begin(key), now: now)
    }

    /// A close is about to go out: stop waiting for that buffer, and make an open for it that is
    /// still in flight stale.
    mutating func closing(_ key: BufferKey) -> CloseMark {
        if inFlight?.id == key.id {
            latest += 1
            inFlight = nil
        }
        let taken = waiting?.isFor(key) == true ? waiting : nil
        if taken != nil { waiting = nil }
        return CloseMark(number: latest, waiting: taken)
    }

    /// The server refused the close, so the buffer is still coming: put back the wait it took —
    /// unless the user has asked for something else since.
    mutating func closeRefused(_ mark: CloseMark) {
        guard let taken = mark.waiting, waiting == nil, latest == mark.number else { return }
        waiting = taken
    }

    /// Nothing asked for so far may land: something newer has the user's attention — a join that
    /// opens, a buffer they went to themselves — or they signed out, and nothing from this session
    /// may land in the next.
    mutating func cancel() {
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
}

