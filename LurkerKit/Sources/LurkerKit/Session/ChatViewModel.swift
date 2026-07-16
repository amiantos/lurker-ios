// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Combine
import Foundation

/// Owns the client + store for the app's lifetime. The client does I/O and emits frames;
/// the store folds them into `state`; the UI observes `statePublisher`. This is the seam
/// the foundation issues hook into.
///
/// Owns two lifecycles:
///  - **session (#3):** restore a Keychain-persisted token on launch; a mid-session 401
///    bounces cleanly to sign-in.
///  - **connection (#4):** reconnect with backoff when the socket drops, resuming from the
///    highest event id seen (`?since=`); and on return-to-foreground, reconnect a socket
///    that died while backgrounded. The app feeds foreground/background via
///    `enterForeground()`/`enterBackground()` (keeping this package UIKit-free).
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

    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var isForeground = true
    private var backgroundedAt: Date?
    /// Buffer keys with an older-history page in flight, so scroll-up can't spam requests.
    private var loadingOlder: Set<String> = []
    /// Highest message id we've already marked read per buffer, to dedupe mark-read spam.
    private var lastMarked: [String: Int] = [:]

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
    /// server-side in the background — so the bounce to sign-in never waits on the network.
    public func logout() {
        cancelReconnect()
        client.logout()
        sessions.clear()
        store.reset()
        loadingOlder.removeAll()
        lastMarked.removeAll()
        statusSubject.value = nil
        sessionSubject.value = .loggedOut
    }

    public func openBuffer(_ key: BufferKey) {
        client.openBuffer(networkId: key.networkId, target: key.target)
    }

    public func send(_ key: BufferKey, text: String) {
        client.sendMessage(networkId: key.networkId, target: key.target, text: text)
    }

    /// Page older history for a buffer (scroll-up). Uses the oldest held message id as an
    /// exclusive cursor; no-ops if nothing older exists, nothing is held yet, or a page is
    /// already in flight.
    public func loadOlder(_ key: BufferKey) {
        guard !loadingOlder.contains(key.id),
              let buffer = store.state.buffers[key.id], buffer.hasMoreOlder,
              let oldest = store.state.messages[key.id]?.first(where: { $0.id != 0 })?.id
        else { return }
        loadingOlder.insert(key.id)
        client.loadOlder(networkId: key.networkId, target: key.target, before: oldest)
    }

    /// Mark a buffer read up to its latest loaded message. Server-authoritative and
    /// MAX-clamped, and deduped here, so calling it on every state change while viewing a
    /// buffer is cheap. The `read-state` echo updates the counts.
    public func markRead(_ key: BufferKey) {
        guard let latest = store.state.messages[key.id]?.compactMap({ $0.id != 0 ? $0.id : nil }).max(),
              latest > (lastMarked[key.id] ?? 0)
        else { return }
        lastMarked[key.id] = latest
        client.markRead(networkId: key.networkId, target: key.target, messageId: latest)
    }

    public func markAllRead() {
        client.markAllRead()
    }

    public func joinChannel(networkId: Int, channel: String) {
        let name = channel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        client.joinChannel(networkId: networkId, channel: name)
    }

    /// Close a buffer (part a channel / drop a DM) and remove its row immediately.
    public func closeBuffer(_ key: BufferKey) {
        client.closeBuffer(networkId: key.networkId, target: key.target)
        store.removeBuffer(key)
    }

    /// The networks the user is on, for the join picker and buffer-list grouping.
    public var networks: [Network] { Array(store.state.networks.values) }

    public func clearError() { store.clearError() }

    // MARK: - App lifecycle (fed by the SceneDelegate)

    /// Back on screen: a socket that died in the background often hasn't fired its failure
    /// yet (the connection is suspended while backgrounded), so the status can still read
    /// Connected over a dead socket. Reconnect if we're disconnected OR were backgrounded
    /// long enough that the socket may be stale; a brief app-switch leaves a healthy
    /// socket alone.
    public func enterForeground() {
        isForeground = true
        guard session == .loggedIn else { return }
        let stale = backgroundedAt.map { Date().timeIntervalSince($0) > Self.staleAfter } ?? false
        if store.state.connection == .connected, !stale { return }
        reconnectAttempt = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        doReconnect(force: true)
    }

    public func enterBackground() {
        isForeground = false
        backgroundedAt = Date()
    }

    // MARK: - Session restore

    /// On launch, re-arm from a Keychain-persisted session if one exists. Optimistic: go
    /// `loggedIn` before connecting, so a stale token's 401 (fired during `start()`) lands
    /// afterward and deterministically wins the bounce back to sign-in rather than racing a
    /// `loggedIn` that arrives later.
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
            onAuthLost()
        case .socketOpen:
            store.apply(frame)
            reconnectAttempt = 0 // a clean connection resets the backoff
        case .socketClosed:
            loadingOlder.removeAll() // in-flight history pages won't get a reply now
            store.apply(frame)
            onSocketDropped()
        case .history(let networkId, let target, _, _, _, _):
            loadingOlder.remove(BufferKey(networkId: networkId, target: target).id)
            store.apply(frame)
        default:
            store.apply(frame)
        }
    }

    // MARK: - Reconnect

    /// A drop while signed-in + foregrounded schedules a backed-off reconnect.
    private func onSocketDropped() {
        guard session == .loggedIn, isForeground else { return }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return } // one attempt already in flight
        let wait = backoff(reconnectAttempt)
        reconnectAttempt += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            self.doReconnect(force: false)
        }
    }

    /// The single reconnect path. `force` reconnects even when the status reads Connected
    /// (the stale-socket case); otherwise a scheduled attempt bails if the connection came
    /// back meanwhile, so a pending timer can't tear down a good socket.
    private func doReconnect(force: Bool) {
        guard session == .loggedIn, isForeground else { return }
        if !force, store.state.connection == .connected { return }
        client.reconnect(since: store.state.maxEventId)
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
    }

    /// The token expired or was revoked elsewhere. Drop the (already-dead) session without
    /// a revoke round-trip and bounce to sign-in with an explanation.
    private func onAuthLost() {
        guard session != .loggedOut else { return } // handle the first 401, ignore the rest
        cancelReconnect()
        client.close()
        sessions.clear()
        store.reset()
        loadingOlder.removeAll()
        lastMarked.removeAll()
        statusSubject.value = "Your session ended — please sign in again."
        sessionSubject.value = .loggedOut
    }

    /// 1s, 2s, 4s … capped at 30s.
    private func backoff(_ attempt: Int) -> Double {
        min(Self.baseBackoff * pow(2, Double(min(attempt, Self.maxShift))), Self.maxBackoff)
    }

    private static let baseBackoff: Double = 1
    private static let maxBackoff: Double = 30
    private static let maxShift = 5 // 1s << 5 = 32s, clamped to 30s
    private static let staleAfter: TimeInterval = 30
}
