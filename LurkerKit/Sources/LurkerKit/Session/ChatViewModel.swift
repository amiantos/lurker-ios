// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine

/// Owns the client + store for the app's lifetime. The client does I/O and emits
/// frames; the store folds them into `state`; the UI observes `statePublisher`. This is
/// the seam the later foundation issues hook into — session persistence and the
/// 401-bounce (#3), reconnect / resume / background-foreground (#4) — but for #2 it does
/// only the minimum: sign in, then wire frames into the store.
@MainActor
public final class ChatViewModel {

    /// Where the account stands with the server.
    public enum SessionState: Sendable {
        case loggedOut
        case loggingIn
        case loggedIn
    }

    private let store = LurkerStore()
    private lazy var client = LurkerClient(onFrame: { [weak self] frame in self?.handle(frame) })

    private let sessionSubject = CurrentValueSubject<SessionState, Never>(.loggedOut)
    private let statusSubject = CurrentValueSubject<String?, Never>(nil)

    public init() {}

    // MARK: - What the UI observes

    public var state: ChatState { store.state }
    public var statePublisher: AnyPublisher<ChatState, Never> { store.statePublisher }

    public var session: SessionState { sessionSubject.value }
    public var sessionPublisher: AnyPublisher<SessionState, Never> { sessionSubject.eraseToAnyPublisher() }

    /// Transient status/error text for the login screen (the reason a sign-in failed).
    public var statusPublisher: AnyPublisher<String?, Never> { statusSubject.eraseToAnyPublisher() }

    // MARK: - Actions

    /// Password → session token → roster + socket. Returns whether sign-in succeeded; on
    /// failure `statusPublisher` carries the reason.
    @discardableResult
    public func login(backend: Backend, server: String, identifier: String, password: String) async -> Bool {
        sessionSubject.value = .loggingIn
        statusSubject.value = nil
        switch await client.login(backend: backend, server: server, identifier: identifier, password: password) {
        case .success:
            sessionSubject.value = .loggedIn
            await client.start()
            return true
        case .failure(let message):
            sessionSubject.value = .loggedOut
            statusSubject.value = message
            return false
        }
    }

    public func openBuffer(_ key: BufferKey) {
        client.openBuffer(networkId: key.networkId, target: key.target)
    }

    public func send(_ key: BufferKey, text: String) {
        client.sendMessage(networkId: key.networkId, target: key.target, text: text)
    }

    public func clearError() { store.clearError() }

    // MARK: - Frame routing

    private func handle(_ frame: ServerFrame) {
        switch frame {
        case .unauthorized:
            // Full persistence + a graceful bounce are #3; for now a lost session just
            // tears the socket down and drops to sign-in with an explanation.
            client.close()
            store.reset()
            statusSubject.value = "Your session ended — please sign in again."
            sessionSubject.value = .loggedOut
        default:
            store.apply(frame)
        }
    }
}
