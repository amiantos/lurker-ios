// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine

/// Owns the client + store for the app's lifetime. The client does I/O and emits
/// frames; the store folds them into `state`; the UI observes `statePublisher`. This is
/// the seam the foundation issues hook into.
///
/// #2 was sign-in-only. #3 adds the session lifecycle: restore a Keychain-persisted
/// token on launch, revoke on sign-out, and bounce cleanly to sign-in on a mid-session
/// 401. Reconnect / resume / background-foreground is still #4.
@MainActor
public final class ChatViewModel {

    /// Where the account stands with the server.
    public enum SessionState: Sendable {
        case loggedOut
        case loggingIn
        case loggedIn
    }

    private let store = LurkerStore()
    private let sessions: SessionStore
    private lazy var client = LurkerClient(onFrame: { [weak self] frame in self?.handle(frame) })

    private let sessionSubject = CurrentValueSubject<SessionState, Never>(.loggedOut)
    private let statusSubject = CurrentValueSubject<String?, Never>(nil)

    public init(sessions: SessionStore = SessionStore()) {
        self.sessions = sessions
        restoreSession()
    }

    // MARK: - What the UI observes

    public var state: ChatState { store.state }
    public var statePublisher: AnyPublisher<ChatState, Never> { store.statePublisher }

    public var session: SessionState { sessionSubject.value }
    public var sessionPublisher: AnyPublisher<SessionState, Never> { sessionSubject.eraseToAnyPublisher() }

    /// Transient status/error text for the login screen (why a sign-in failed, or why a
    /// session ended).
    public var statusPublisher: AnyPublisher<String?, Never> { statusSubject.eraseToAnyPublisher() }

    // MARK: - Actions

    /// Password → session token → roster + socket, and persist the session so the next
    /// launch reconnects without re-login. Returns whether sign-in succeeded; on failure
    /// `statusPublisher` carries the reason.
    @discardableResult
    public func login(backend: Backend, server: String, identifier: String, password: String) async -> Bool {
        sessionSubject.value = .loggingIn
        statusSubject.value = nil
        switch await client.login(backend: backend, server: server, identifier: identifier, password: password) {
        case .success(let token):
            sessions.save(PersistedSession(backend: backend, server: server, token: token))
            sessionSubject.value = .loggedIn
            await client.start()
            return true
        case .failure(let message):
            sessionSubject.value = .loggedOut
            statusSubject.value = message
            return false
        }
    }

    /// The deliberate sign-out. Local teardown is immediate — the client revokes
    /// server-side in the background — so the bounce to sign-in never waits on the
    /// network.
    public func logout() {
        client.logout()
        sessions.clear()
        store.reset()
        statusSubject.value = nil
        sessionSubject.value = .loggedOut
    }

    public func openBuffer(_ key: BufferKey) {
        client.openBuffer(networkId: key.networkId, target: key.target)
    }

    public func send(_ key: BufferKey, text: String) {
        client.sendMessage(networkId: key.networkId, target: key.target, text: text)
    }

    public func clearError() { store.clearError() }

    // MARK: - Session restore

    /// On launch, re-arm from a Keychain-persisted session if one exists. Optimistic: go
    /// `loggedIn` before connecting, so a stale token's 401 (fired during `start()`)
    /// lands afterward and deterministically wins the bounce back to sign-in rather than
    /// racing a `loggedIn` that arrives later.
    private func restoreSession() {
        guard let saved = sessions.load() else {
            sessionSubject.value = .loggedOut
            return
        }
        sessionSubject.value = .loggedIn
        client.restore(server: saved.server, token: saved.token)
        Task { await client.start() }
    }

    // MARK: - Frame routing

    private func handle(_ frame: ServerFrame) {
        switch frame {
        case .unauthorized:
            // The token expired or was revoked from another device. Forget it and bounce
            // to sign-in with an explanation rather than leaving a dead, stale screen.
            client.close()
            sessions.clear()
            store.reset()
            statusSubject.value = "Your session ended — please sign in again."
            sessionSubject.value = .loggedOut
        default:
            store.apply(frame)
        }
    }
}
