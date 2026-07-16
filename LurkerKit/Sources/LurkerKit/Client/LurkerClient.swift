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

    init(onFrame: @escaping (ServerFrame) -> Void) {
        self.onFrame = onFrame
        self.session = URLSession(configuration: .default)
    }

    // MARK: - Auth

    /// Exchange a password for a session token against `backend`.
    func login(backend: Backend, server: String, identifier: String, password: String) async -> LoginResult {
        baseURL = Self.normalize(server)
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
            return .failure(message: "Sign-in failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Lifecycle

    /// Re-arm from a persisted session (no password round-trip); follow with `start()`.
    /// If the token is stale, `start()`'s first authenticated call surfaces the 401 as
    /// `.unauthorized`.
    func restore(server: String, token: String) {
        baseURL = Self.normalize(server)
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
        send(["type": "send", "networkId": networkId, "target": target, "text": text])
    }

    private func send(_ verb: [String: Any]) {
        guard let socket,
              let data = try? JSONSerialization.data(withJSONObject: verb),
              let text = String(data: data, encoding: .utf8)
        else { return }
        socket.send(.string(text)) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in self?.onFrame(.serverError("Send failed")) }
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
    func logout() {
        let revokeToken = token
        let base = baseURL
        close()
        guard let revokeToken, let url = URL(string: base + "/api/auth/logout") else { return }
        let session = self.session
        Task {
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

    private static func normalize(_ server: String) -> String {
        var trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }
}
