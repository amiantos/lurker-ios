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
    ///
    /// The device token goes with it: this phone must stop receiving the departing user's
    /// DMs. Handed to the client rather than deregistered here, because it has to happen
    /// against the session being revoked and therefore before the revoke lands (#490).
    public func logout() {
        cancelReconnect()
        client.logout(deviceToken: deviceToken)
        deviceToken = nil
        // The next sign-in may be against a different server, whose answer differs.
        apnsSupported = nil
        sessions.clear()
        store.reset()
        loadingOlder.removeAll()
        lastMarked.removeAll()
        statusSubject.value = nil
        sessionSubject.value = .loggedOut
    }

    // MARK: - Push (#490)

    /// This install's APNs device token, once the OS has issued one. Held so sign-out can
    /// deregister it, and so a re-register after reconnect doesn't need the app layer to
    /// remember.
    private var deviceToken: String?

    /// Cached answer to "does this server speak APNs". Fixed for a given server, and the
    /// question is asked on every activation — without this that's an HTTP round trip every
    /// time the user opens the app, to re-learn something that cannot have changed.
    /// Only a real answer is cached: a failed ask stays unknown and is retried.
    private var apnsSupported: Bool?

    /// Does this server speak APNs at all? A self-hosted server holds no Apple key and
    /// says so via `/api/push/config`, in which case asking the user for notification
    /// permission would be a lie — we'd get the grant and never deliver anything.
    ///
    /// `nil` means we couldn't ask. Deliberately NOT folded into `false`: the two are one
    /// wifi blip apart and would read identically at the call site, so collapsing them
    /// makes a transient failure report a permanent fact about the server's configuration
    /// — and sends whoever reads that line off auditing env vars on a box that was fine.
    /// Only a real answer is cached, so an unreachable server is asked again next time.
    public func serverSupportsAPNs() async -> Bool? {
        if let apnsSupported { return apnsSupported }
        guard let transports = await client.pushTransports() else { return nil }
        let supported = transports.contains("apns")
        apnsSupported = supported
        return supported
    }

    /// Hand the OS-issued device token to the server. Idempotent — iOS re-issues the same
    /// token on most launches, and the server upserts.
    @discardableResult
    public func registerPushDevice(token: String) async -> Bool {
        deviceToken = token
        guard session == .loggedIn else { return false }
        return await client.registerDevice(token: token)
    }

    public func openBuffer(_ key: BufferKey) {
        client.openBuffer(networkId: key.networkId, target: key.target)
    }

    public func send(_ key: BufferKey, text: String) {
        // The system buffer is the app's command console on the web (#355); this client
        // doesn't run commands yet (#10). Until it does, answer any input with a local
        // line — the web's own pattern for non-command input there — rather than silently
        // dropping the one write the user made deliberately.
        guard key.networkId != nil else {
            store.appendLocal(key, text: "Commands haven't arrived in the app yet.")
            return
        }
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
        // Tell the server we're looking, so it stops pushing (#490). Sent before the
        // reconnect check below because the common case is a LIVE socket — we're back and
        // nothing needs reopening — and that path returns early. A new socket re-asserts
        // presence itself, so sending here too is at worst a duplicate the server folds.
        client.setPresence(true)
        let stale = backgroundedAt.map { Date().timeIntervalSince($0) > Self.staleAfter } ?? false
        if store.state.connection == .connected, !stale { return }
        reconnectAttempt = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        doReconnect(force: true)
    }

    /// `onFlush` fires once the presence frame is on the wire — the app holds a
    /// background-task assertion until then, because this frame is sent in the one window
    /// where iOS is actively trying to suspend us. Always called, including when there was
    /// nothing to send, so the caller can't leak the assertion.
    public func enterBackground(onFlush: (@Sendable () -> Void)? = nil) {
        isForeground = false
        backgroundedAt = Date()
        // The moment that makes push work: until the server hears this it believes a
        // client is watching and suppresses every notification. The socket usually
        // survives backgrounding for a while, so waiting for it to drop would mean up to
        // ~60s of silence (the server pings every 30s and reaps on the second miss).
        //
        // Not covered here: a force-quit or a tunnel, where nothing gets sent and that
        // reaper IS the backstop. That gap is real and known — see #490.
        guard session == .loggedIn else {
            onFlush?()
            return
        }
        client.setPresence(false, onFlush: onFlush)
    }

    /// The OS's network path came or went. Fed in from the app (which owns the
    /// `NWPathMonitor`) for the same reason foreground/background is — it keeps this
    /// package off the `Network` framework, whose `NWPath` types would also have to share
    /// a namespace with our own `Network` model.
    ///
    /// Regaining a path also short-circuits the backoff: the reason we were waiting just
    /// went away, and a user who reconnects to wifi shouldn't watch a 30s timer run down.
    public func setReachable(_ reachable: Bool) {
        let was = store.state.reachable
        store.setReachable(reachable)
        guard reachable, !was, session == .loggedIn, isForeground else { return }
        reconnectAttempt = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        doReconnect(force: false)
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
        // A session persisted before the transport policy (#29) can name a server the
        // policy now rejects — a non-local http:// address the old blanket ATS exemption
        // allowed. Restoring it would go loggedIn and then spin ATS-blocked reconnects
        // forever. Bounce to sign-in with the same copy login would give, and drop the
        // session: its token belongs to a server we can no longer talk to. The server
        // field still prefills from preferences, so the address stays visible to fix.
        if let reason = ServerAddress.rejection(of: ServerAddress.normalize(saved.server)) {
            sessions.clear()
            statusSubject.value = reason
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
