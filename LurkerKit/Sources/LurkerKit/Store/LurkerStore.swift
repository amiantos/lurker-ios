// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine

/// How the live socket stands, for a connection state the user can actually see.
public enum SocketStatus: Sendable {
    case connecting
    case connected
    case reconnecting
}

/// Immutable snapshot of everything the chat UI renders. The map keys are `BufferKey.id`.
public struct ChatState: Sendable {
    public var connection: SocketStatus = .connecting
    /// Highest persisted message id seen (excluding the system buffer, which has its own
    /// id space) — replayed as `?since=` on reconnect so the server ships only the gap.
    /// Populated now so #4 can resume without a store change.
    public var maxEventId: Int = 0
    public var networks: [Int: Network] = [:]
    public var buffers: [String: Buffer] = [:]
    public var messages: [String: [Message]] = [:]
    public var members: [String: [Member]] = [:]
    public var error: String?

    public init() {}
}

/// Holds the domain state and folds `ServerFrame`s into it. The fold is a pure function
/// (`reduce`) with no I/O, so it is fully unit-testable; the store just wraps it in a
/// `CurrentValueSubject` the UI observes. `@MainActor` because the client marshals every
/// frame to main before applying it, so no locking is needed.
@MainActor
final class LurkerStore {
    private let subject = CurrentValueSubject<ChatState, Never>(ChatState())

    var state: ChatState { subject.value }
    var statePublisher: AnyPublisher<ChatState, Never> { subject.eraseToAnyPublisher() }

    func reset() { subject.value = ChatState() }

    func clearError() { subject.value.error = nil }

    func apply(_ frame: ServerFrame) {
        subject.value = Self.reduce(subject.value, frame)
    }

    /// The pure core. Given the current state and a frame, produce the next state.
    static func reduce(_ state: ChatState, _ frame: ServerFrame) -> ChatState {
        switch frame {
        case .networks(let networks):
            return applyNetworks(state, networks)
        case .snapshot(let networks):
            return applySnapshot(state, networks)
        case .backlog(let buffer, let messages, let hydrated, let append):
            return applyBacklog(state, buffer, messages, hydrated: hydrated, append: append)
        case .live(let networkId, let target, let message):
            return applyLive(state, networkId: networkId, target: target, message: message)
        case .serverError(let text):
            var next = state
            next.error = text
            return next
        case .sendResult(_, let ok, let error):
            var next = state
            next.error = ok ? nil : (error ?? "Send failed")
            return next
        case .socketOpen:
            var next = state
            next.connection = .connected
            next.error = nil
            return next
        case .socketClosed:
            var next = state
            // Once we've been connected, a drop is a reconnect; a drop before the first
            // open is still the initial connect.
            switch next.connection {
            case .connected, .reconnecting: next.connection = .reconnecting
            case .connecting: next.connection = .connecting
            }
            return next
        case .unauthorized, .ignored:
            // Session-level / no-op; the view model intercepts `.unauthorized` first.
            return state
        }
    }

    // MARK: - Reducers

    private static func applyNetworks(_ state: ChatState, _ networks: [Network]) -> ChatState {
        var next = state
        for network in networks {
            // Merge the REST name in without clobbering any live state the snapshot set.
            if var existing = next.networks[network.id] {
                existing.name = network.name
                next.networks[network.id] = existing
            } else {
                next.networks[network.id] = network
            }
        }
        return next
    }

    private static func applySnapshot(_ state: ChatState, _ networks: [NetworkSnapshot]) -> ChatState {
        var next = state
        for snapshot in networks {
            if var existing = next.networks[snapshot.id] {
                existing.state = snapshot.state
                existing.nick = snapshot.nick
                next.networks[snapshot.id] = existing
            } else {
                next.networks[snapshot.id] = Network(
                    id: snapshot.id, name: "network", state: snapshot.state, nick: snapshot.nick
                )
            }
            for channel in snapshot.channels {
                let key = BufferKey(networkId: snapshot.id, target: channel.name).id
                var buffer = next.buffers[key]
                    ?? Buffer(networkId: snapshot.id, target: channel.name, kind: .channel)
                buffer.joined = true
                next.buffers[key] = buffer
                next.members[key] = channel.members
            }
        }
        return next
    }

    private static func applyBacklog(
        _ state: ChatState,
        _ frameBuffer: Buffer,
        _ messages: [Message],
        hydrated: Bool,
        append: Bool
    ) -> ChatState {
        var next = state
        let key = frameBuffer.key.id
        // Never un-hydrate: a later shell for an already-read buffer keeps its history.
        let alreadyHydrated = next.buffers[key]?.hydrated == true
        var buffer = frameBuffer
        buffer.hydrated = hydrated || alreadyHydrated
        next.buffers[key] = buffer

        if !hydrated {
            // Shell: register the buffer but keep any messages we already hold.
            if next.messages[key] == nil { next.messages[key] = [] }
        } else if append {
            // Resume gap slice: append past the tail, de-duping by persisted id.
            next.messages[key] = appendMerged(next.messages[key] ?? [], messages)
        } else {
            // Full / latest / reset backlog: replace wholesale.
            next.messages[key] = messages
        }
        next.maxEventId = maxEventId(next.maxEventId, frameBuffer.networkId, messages)
        return next
    }

    private static func applyLive(
        _ state: ChatState,
        networkId: Int?,
        target: String,
        message: Message
    ) -> ChatState {
        var next = state
        let key = BufferKey(networkId: networkId, target: target).id
        let existing = next.messages[key] ?? []
        // De-dupe backlog/live overlap by persisted id; id 0 is ephemeral and always
        // appended.
        if message.id != 0, existing.contains(where: { $0.id == message.id }) { return next }
        if next.buffers[key] == nil {
            // A live event can be the first sign of a buffer (a new incoming DM), so
            // materialize a row for it. Unhydrated, so tapping it fetches history.
            next.buffers[key] = Buffer(
                networkId: networkId, target: target,
                kind: BufferKind.of(networkId: networkId, target: target)
            )
        }
        next.messages[key] = existing + [message]
        next.maxEventId = maxEventId(next.maxEventId, networkId, [message])
        return next
    }

    /// Append `incoming` onto `existing`, dropping any persisted id already present.
    private static func appendMerged(_ existing: [Message], _ incoming: [Message]) -> [Message] {
        let seen = Set(existing.compactMap { $0.id != 0 ? $0.id : nil })
        return existing + incoming.filter { $0.id == 0 || !seen.contains($0.id) }
    }

    /// The `?since=` watermark. The system buffer (nil networkId) is skipped — it has a
    /// separate id space, so its ids must not pollute the resume cursor.
    private static func maxEventId(_ current: Int, _ networkId: Int?, _ messages: [Message]) -> Int {
        guard networkId != nil else { return current }
        return max(current, messages.map(\.id).max() ?? 0)
    }
}
