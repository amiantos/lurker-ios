// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The one client that owns Lurker's REST + WebSocket contract. Self-hosted and hosted
/// differ only by `Backend` (base URL + where the token is minted); there is deliberately
/// no transport-adapter seam.
///
/// `@MainActor`: reconnect (#4) means the socket is opened, replaced, and torn down from
/// several places, so confining all of that state to the main actor makes it race-free
/// without locks. Network I/O still runs off the main thread — `URLSession`'s async APIs
/// suspend rather than block, and the socket's receive callback hops back to main. The
/// client parses server bytes into `ServerFrame`s and hands them to `onFrame`; it holds
/// no domain state (that lives in the store).
@MainActor
final class LurkerClient {

    enum LoginResult: Sendable {
        case success(token: String)
        case failure(message: String)
    }

    private let onFrame: (ServerFrame) -> Void
    private let session: URLSession
    private var baseURL = ""
    private var token: String?
    private var socket: URLSessionWebSocketTask?
    /// Reset per socket; gates the "socket really opened" signal to the first frame that
    /// actually arrives, rather than optimistically on `resume()`.
    private var hasEmittedOpen = false
    /// Last reported visibility, re-asserted on every new socket. The server starts each
    /// socket at `visible: false` and waits for us to say otherwise, so this has to be
    /// per-socket state rather than something sent once — see `setPresence`.
    ///
    /// Starts false because that's the only value we've been TOLD. Claiming visible before
    /// the app has said so is an assumption that happens to hold today (nothing launches
    /// this app without it becoming active), and it suppresses push when it's wrong —
    /// `enterForeground` reports the truth within milliseconds of the app actually
    /// appearing, so the assumption buys nothing.
    private var presenceVisible = false

    init(onFrame: @escaping (ServerFrame) -> Void) {
        self.onFrame = onFrame
        self.session = URLSession(configuration: .default)
    }

    // MARK: - Auth

    /// Exchange a password for a session token against `backend`.
    func login(backend: Backend, server: String, identifier: String, password: String) async -> LoginResult {
        baseURL = ServerAddress.normalize(server)
        // The transport policy runs before any request so its verdict is sign-in copy,
        // not a failed connect (#29). ATS would block a non-local http load anyway;
        // this is the same rule stated legibly.
        if let reason = ServerAddress.rejection(of: baseURL) {
            return .failure(message: reason)
        }
        guard let url = URL(string: baseURL + backend.loginPath) else {
            return .failure(message: "That server URL doesn't look right.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            backend.identifierField: identifier,
            "password": password,
        ])

        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 {
                // Bad credentials — OR a passkey-only account, since the mint endpoint is
                // password-only and can't tell the two apart. Name the caveat rather than
                // flatly claiming "wrong password".
                return .failure(message:
                    "Sign-in failed — check your password. Passkey-only accounts can't "
                        + "sign in from the app yet (login is password-only).")
            }
            guard code == 200,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let minted = body["token"] as? String, !minted.isEmpty
            else {
                return .failure(message: "Sign-in failed (HTTP \(code))")
            }
            token = minted
            return .success(token: minted)
        } catch {
            // Backstop for the policy above: if ATS blocks a load our check let through
            // (the two definitions of "local" should never drift, but Apple's can move),
            // say what actually happened instead of surfacing NSURLError -1022's prose.
            if (error as? URLError)?.code == .appTransportSecurityRequiresSecureConnection {
                return .failure(message:
                    "iOS blocked the connection because this server isn't using HTTPS.")
            }
            return .failure(message: "Sign-in failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Lifecycle

    /// Re-arm from a persisted session (no password round-trip); follow with `start()`.
    /// If the token is stale, `start()`'s first authenticated call surfaces the 401 as
    /// `.unauthorized`.
    func restore(server: String, token: String) {
        baseURL = ServerAddress.normalize(server)
        self.token = token
    }

    /// After login/restore: fetch the network roster (proves the bearer authenticates
    /// plain REST, and supplies the names the snapshot omits), then open the socket. If
    /// the roster fetch already saw a 401 the token is dead — skip the upgrade.
    func start() async {
        if await fetchNetworks() { openSocket() }
    }

    /// Reopen the socket after a drop, resuming from `since` so the server ships only the
    /// gap (`?since=N`) rather than re-sending everything. Skips the roster re-fetch —
    /// names don't change and the reconnect snapshot re-sends live network state anyway.
    func reconnect(since: Int) {
        openSocket(since: since)
    }

    /// Returns false only when the token was rejected (401); true otherwise, including
    /// transient errors where the socket is still worth trying.
    private func fetchNetworks() async -> Bool {
        guard let token, let url = URL(string: baseURL + "/api/networks") else { return true }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 {
                onFrame(.unauthorized)
                return false
            }
            if (200..<300).contains(code), let text = String(data: data, encoding: .utf8) {
                onFrame(FrameParser.parseNetworks(text))
            }
            return true
        } catch {
            return true // a network hiccup, not an auth failure — let the socket try
        }
    }

    /// A native client CAN set headers on the WS upgrade, so the session token rides as a
    /// bearer where a browser would need a cookie. `since > 0` resumes from that event id.
    private func openSocket(since: Int = 0) {
        guard let token, let url = URL(string: Self.wsBase(baseURL) + "/ws" + Self.sinceQuery(since)) else { return }
        // Replace any prior socket so a reconnect can't leave two live; callbacks from the
        // old one are ignored via the `task === socket` guard below.
        socket?.cancel(with: .goingAway, reason: nil)
        hasEmittedOpen = false
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        socket = task
        task.resume()
        listen(on: task)
    }

    /// `URLSessionWebSocketTask` has no stream — re-arm after each frame. The completion
    /// fires on a background queue; it extracts only `Sendable` values and hops to the
    /// main actor. Because the next `listen` is armed only at the end of `handleOpen`,
    /// receives are strictly serialized, so ordering is preserved.
    private func listen(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            switch result {
            case .success(let message):
                let text: String? = switch message {
                case .string(let string): string
                case .data: nil
                @unknown default: nil
                }
                Task { @MainActor in self?.handleOpen(text: text, from: task) }
            case .failure(let error):
                let code = (task.response as? HTTPURLResponse)?.statusCode
                let reason = error.localizedDescription
                Task { @MainActor in self?.handleClose(code: code, reason: reason, from: task) }
            }
        }
    }

    private func handleOpen(text: String?, from task: URLSessionWebSocketTask) {
        guard task === socket else { return } // a socket we've since replaced — ignore
        if !hasEmittedOpen {
            // First byte through = the upgrade actually succeeded. A refused upgrade never
            // reaches here — it lands in handleClose — so we never falsely report open.
            hasEmittedOpen = true
            // Re-assert visibility: this is a NEW socket and the server starts every
            // socket at `visible: false`. Without this, a reconnect while the user is
            // reading would leave the server thinking nobody's home, and it would push a
            // DM to the phone in their hand.
            send(["type": "presence", "visible": presenceVisible])
            onFrame(.socketOpen)
        }
        if let text { onFrame(FrameParser.parseWs(text)) }
        listen(on: task)
    }

    private func handleClose(code: Int?, reason: String, from task: URLSessionWebSocketTask) {
        guard task === socket else { return }
        // A refused upgrade with 401 means the bearer never resolved — the session is
        // gone, not merely a dropped connection.
        onFrame(code == 401 ? .unauthorized : .socketClosed(reason: reason, code: code))
    }

    // MARK: - Verbs

    /// Ask the server to hydrate a buffer. Channels/DMs arrive as shells, so without this
    /// a tapped buffer renders blank. No-op for the system buffer (already full).
    func openBuffer(networkId: Int?, target: String) {
        guard let networkId else { return }
        send(["type": "open-buffer", "networkId": networkId, "target": target])
    }

    func sendMessage(networkId: Int?, target: String, text: String) {
        guard let networkId else { return }
        // The one write the user made deliberately, and the one with no resend behind it —
        // so a socket-level failure to deliver it is worth telling them about. A `send`
        // that reaches the server but is rejected comes back as a `send-result` instead;
        // this only covers never getting it onto the wire.
        send(["type": "send", "networkId": networkId, "target": target, "text": text], surfacesFailure: true)
    }

    /// Page older history for a buffer, back from `before` (exclusive message id). The
    /// reply is a `history` frame (mode `before`) the store prepends. System-buffer paging
    /// isn't wired for 1.0.
    func loadOlder(networkId: Int?, target: String, before: Int, limit: Int = 100) {
        guard let networkId else { return }
        send(["type": "history", "networkId": networkId, "target": target, "before": before, "limit": limit])
    }

    /// Mark a buffer read up to `messageId`. The server MAX-clamps, so re-sending a lower
    /// id is a safe no-op. The system buffer sends `networkId: null` (hence NSNull, not a
    /// dropped key), so this can't reuse the `guard let networkId` shortcut.
    func markRead(networkId: Int?, target: String, messageId: Int) {
        send([
            "type": "mark-read",
            "networkId": networkId.map { $0 as Any } ?? NSNull(),
            "target": target,
            "messageId": messageId,
        ])
    }

    func markAllRead() {
        send(["type": "mark-all-read"])
    }

    /// Join a channel on a network. The server sends its backlog once joined, which
    /// materializes the buffer in the list.
    func joinChannel(networkId: Int, channel: String) {
        send(["type": "join", "networkId": networkId, "channel": channel])
    }

    /// Close a buffer: parts a channel and stops tracking a DM. The server pseudo-buffer
    /// (`:server:`) can't be closed. No-op for the system buffer (networkId nil).
    func closeBuffer(networkId: Int?, target: String) {
        guard let networkId, !target.hasPrefix(":server:") else { return }
        send(["type": "close-buffer", "networkId": networkId, "target": target])
    }

    /// Report whether the user can actually SEE the app (#490).
    ///
    /// This is the gate the server's push decision hangs on: it suppresses push while any
    /// of a user's clients is visible, and it only knows because we say so. An open socket
    /// is deliberately NOT presence — a backgrounded app holds its socket and must still
    /// receive push, which is exactly the case that makes push worth having.
    ///
    /// Granularity is per-user, not per-buffer: the server tracks "is any client visible",
    /// never which buffer is focused. So this says nothing about *where* the user is
    /// looking, and lurker-ios#15's "no push for a buffer you're actively looking at"
    /// describes something the protocol can't express.
    ///
    /// Latched so a new socket can re-assert it (see `handleOpen`).
    ///
    /// `onFlush` fires when the frame is actually written. Backgrounding needs it: that's
    /// the one frame sent while iOS is trying to suspend us, and losing it suppresses push
    /// until the server's reaper notices (~60s).
    func setPresence(_ visible: Bool, onFlush: (@Sendable () -> Void)? = nil) {
        presenceVisible = visible
        send(["type": "presence", "visible": visible], onFlush: onFlush)
    }

    // MARK: - Push

    /// Which push transports this server can actually deliver on (#490). A self-hosted
    /// server holds no Apple key and answers `["webpush"]` — knowing that BEFORE asking for
    /// notification permission is the difference between "this server doesn't support push"
    /// and a permission prompt followed by silence forever.
    ///
    /// `nil` means we couldn't ask (offline, 401, unparseable); `[]` means the server
    /// answered and named nothing. Deliberately distinct: collapsing both into `[]` makes a
    /// wifi blip during launch indistinguishable from a permanent fact about the server's
    /// configuration, and the log line that follows sends you auditing env vars on a box
    /// that was fine.
    ///
    /// An older server (pre-#490) has no `transports` key and correctly reads as `[]` —
    /// it answered, and it has no native push.
    func pushTransports() async -> [String]? {
        guard let token, let url = URL(string: baseURL + "/api/push/config") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return body["transports"] as? [String] ?? []
    }

    /// File this install's APNs device token against the signed-in account.
    /// Returns false when the server won't take it, so the caller can stop pretending
    /// push works.
    @discardableResult
    func registerDevice(token deviceToken: String) async -> Bool {
        guard let token, let url = URL(string: baseURL + "/api/push/devices") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "token": deviceToken,
            "transport": "apns",
        ])
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Drop this device's registration. Called BEFORE sign-out revokes the session, since
    /// it needs that session to authenticate. Takes an explicit token+base so sign-out can
    /// fire it against the session it is about to destroy.
    static func deregisterDevice(
        session: URLSession, baseURL: String, sessionToken: String, deviceToken: String
    ) async {
        guard let url = URL(string: baseURL + "/api/push/devices") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": deviceToken])
        _ = try? await session.data(for: request)
    }

    /// `onFlush` fires once the frame is written (or has definitively failed), on an
    /// arbitrary queue. Only `setPresence` uses it: the app needs to hold a background-task
    /// assertion open until the write lands, and "the write landed" is a fact only
    /// URLSession can report. Called on EVERY exit path — including the early return —
    /// because a caller holding an OS resource against it must always get it back.
    ///
    /// `surfacesFailure` gates whether a socket-write failure becomes a user-facing error.
    /// Only a message the user typed sets it: everything else here is machinery — presence,
    /// open-buffer, history, mark-read, join — whose write can legitimately fail the instant
    /// a backgrounded socket is torn down, and which the reconnect re-drives anyway. Routing
    /// those failures to the alert is the "Send failed: Software caused connection abort"
    /// modal that pops on foreground: iOS kills the socket while suspended without firing its
    /// failure callback, so the first write on return (a presence re-assert) writes into a
    /// dead socket and fails, over a connection the reconnect is about to replace.
    private func send(
        _ verb: [String: Any],
        surfacesFailure: Bool = false,
        onFlush: (@Sendable () -> Void)? = nil
    ) {
        guard let socket,
              let data = try? JSONSerialization.data(withJSONObject: verb),
              let text = String(data: data, encoding: .utf8)
        else {
            onFlush?()
            return
        }
        socket.send(.string(text)) { [weak self] error in
            defer { onFlush?() }
            guard let error, surfacesFailure else { return }
            // Capture the reason (a String) before hopping — Error isn't Sendable, but its
            // localized description is, and it's what makes an offline/TLS failure legible.
            let reason = error.localizedDescription
            Task { @MainActor in self?.onFrame(.serverError("Send failed: \(reason)")) }
        }
    }

    /// Drop the socket and forget the token without revoking server-side. For teardown
    /// and the dead-token case (a 401) where there's nothing left to revoke.
    func close() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        token = nil
        hasEmittedOpen = false
    }

    /// The deliberate sign-out. Tears the local session down *immediately* (drops the
    /// socket + token) and fires the server-side revoke in the background, so sign-out
    /// feels instant even when the server is slow or unreachable. The revoke uses the
    /// captured token and never touches this client again, so a subsequent sign-in that
    /// mints a fresh session can't be clobbered by an in-flight revoke.
    ///
    /// `deviceToken` (when push is registered) is deregistered FIRST, in the same task and
    /// against the same about-to-die session — a device deregistration needs a live
    /// session to authenticate, so it cannot happen after the revoke. Best-effort: if it
    /// fails (offline, crash, force-quit) the token stays filed against this account, and
    /// the server's native rebind rule is what stops that stranding whoever signs in next
    /// on this phone (#490).
    func logout(deviceToken: String? = nil) {
        let revokeToken = token
        let base = baseURL
        close()
        guard let revokeToken, let url = URL(string: base + "/api/auth/logout") else { return }
        let session = self.session
        Task {
            if let deviceToken {
                await Self.deregisterDevice(
                    session: session, baseURL: base, sessionToken: revokeToken, deviceToken: deviceToken
                )
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(revokeToken)", forHTTPHeaderField: "Authorization")
            _ = try? await session.data(for: request)
        }
    }

    // MARK: - Helpers

    private static func sinceQuery(_ since: Int) -> String {
        since > 0 ? "?since=\(since)" : ""
    }

    /// http → ws, https → wss. Replacing only the leading `http` turns the trailing `s`
    /// of `https` into `wss` for free.
    private static func wsBase(_ base: String) -> String {
        base.replacingOccurrences(of: "^http", with: "ws", options: .regularExpression)
    }

}
