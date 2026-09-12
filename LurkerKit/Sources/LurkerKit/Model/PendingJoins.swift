// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The joins this device asked for and hasn't heard back about (#57).
///
/// A JOIN is a request the server can refuse, forward, or never answer, and every reply is a frame
/// naming a channel: `channel-joined`, `join-error`, `channel-parted`. Which of those answers
/// something the user did has to be remembered here. A separate, pure type for the reason
/// `UnsentCorrelator` is one: the rules are small, each has a way to be wrong, and a test can drive
/// them here where it can't reach a private frame handler.
///
/// Keyed by `BufferKey.id`, which folds case, so the server's `#Lurker` answers a typed `#lurker`.
struct PendingJoins {

    /// How long a join may go unanswered before the user hears "No response". The web's figure.
    static let timeout: TimeInterval = 10

    /// The channels a join names, one per entry. `/join #a,#b` is one JOIN on the wire, but the
    /// server answers each channel on its own, so waiting on the list as typed waited on a name
    /// nothing ever answers: a "No response" toast for two joins that both worked. (A channel name
    /// can't contain a comma, so there's nothing to escape.)
    static func channels(in list: String) -> [String] {
        list.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// What became of a join, for the view model to act on.
    enum Outcome: Equatable {
        /// We're in. `opens` is whether the asker wanted to be taken there.
        case joined(BufferKey, opens: Bool)
        /// The server said no, and why.
        case refused(BufferKey, reason: String)
        /// Nothing answered in time.
        case timedOut(BufferKey)
    }

    private struct Request {
        let key: BufferKey
        var opens: Bool
        var deadline: Date
    }

    private var requests: [String: Request] = [:]

    /// Whether anything is waiting on an answer. Test seam.
    var pendingCount: Int { requests.count }

    /// Remember a join that was just sent.
    ///
    /// Asking again for the same channel restarts the clock, and opens if either request wanted to:
    /// tapping Join on a parted row and then typing `/join` for it still takes you there.
    mutating func request(_ key: BufferKey, opens: Bool, now: Date) {
        let deadline = now.addingTimeInterval(Self.timeout)
        if var existing = requests[key.id] {
            existing.opens = existing.opens || opens
            existing.deadline = deadline
            requests[key.id] = existing
        } else {
            requests[key.id] = Request(key: key, opens: opens, deadline: deadline)
        }
    }

    /// A `channel-joined`. Nil for a join nobody here asked for — a reconnect's rejoin, or one made
    /// on another device — which must not move the user anywhere.
    mutating func joined(_ key: BufferKey) -> Outcome? {
        guard let request = requests.removeValue(forKey: key.id) else { return nil }
        return .joined(key, opens: request.opens)
    }

    /// A `join-error`. Nil for a join nobody here asked for: a rejoin refused on reconnect already
    /// shows as a parted row, and another device's refusal is that device's to report.
    mutating func refused(_ key: BufferKey, reason: String) -> Outcome? {
        guard let request = requests.removeValue(forKey: key.id) else { return nil }
        return .refused(request.key, reason: reason)
    }

    /// A `channel-parted` for a name we asked to join: a 470 forward. The join WAS answered, under a
    /// name whose own `channel-joined` arrives separately, so this is dropped without a word rather
    /// than left to time out into a "No response" that isn't true.
    mutating func parted(_ key: BufferKey) {
        requests.removeValue(forKey: key.id)
    }

    /// The joins whose deadline has passed, oldest first, forgotten as they're returned.
    mutating func expire(now: Date) -> [Outcome] {
        let expired = requests.filter { $0.value.deadline <= now }
        for id in expired.keys { requests.removeValue(forKey: id) }
        return expired.values
            .sorted { $0.deadline < $1.deadline }
            .map { .timedOut($0.key) }
    }

    /// Forget everything: the socket died or the account signed out, so no answer is coming.
    mutating func removeAll() {
        requests.removeAll()
    }
}

/// A join this device asked for that didn't happen, to tell the user in passing (#57). The app
/// shows it as a toast.
public enum JoinNotice: Equatable, Sendable {
    /// The server refused. `reason` is its own sentence, such as "This channel is invite-only."
    case refused(channel: String, reason: String)
    /// Nothing came back within `PendingJoins.timeout`.
    case noResponse(channel: String)
    /// Never sent: the network isn't connected, or there was no socket to carry the JOIN.
    case notConnected(channel: String, network: String)

    /// What the toast says.
    public var message: String {
        switch self {
        case .refused(let channel, let reason): "Couldn't join \(channel): \(reason)"
        case .noResponse(let channel): "No response joining \(channel)"
        case .notConnected(let channel, let network): "Can't join \(channel) while \(network) is offline"
        }
    }
}
