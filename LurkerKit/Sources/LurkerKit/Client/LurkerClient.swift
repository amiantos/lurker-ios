// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The one client that owns Lurker's REST + WebSocket contract. Self-hosted and
/// hosted differ only by `Backend` (base URL + where the token is minted); there is
/// deliberately no transport-adapter seam (#2).
///
/// I/O only: it parses server bytes into `ServerFrame`s and delivers them to `onFrame`
/// — always on the main queue, so the `@MainActor` store/UI can consume them directly.
/// It holds NO domain state; that lives in the store.
///
/// Not yet here (later foundation issues): persisted tokens and 401-bounce (#3),
/// reconnect / `?since=` resume / background-foreground (#4), history pagination (#6).
final class LurkerClient {

    enum LoginResult: Sendable {
        case success(token: String)
        case failure(message: String)
    }

    private let onFrame: @MainActor (ServerFrame) -> Void
    private let session: URLSession
    private var baseURL = ""
    private var token: String?
    private var socket: URLSessionWebSocketTask?

    init(onFrame: @escaping @MainActor (ServerFrame) -> Void) {
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
                // Bad credentials — OR a passkey-only account, since the mint endpoint
                // is password-only and can't tell the two apart. Name the caveat rather
                // than flatly claiming "wrong password".
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
                // A revoked/expired token trips here first (before the WS upgrade).
                emit(.unauthorized)
                return false
            }
            if (200..<300).contains(code), let text = String(data: data, encoding: .utf8) {
                emit(FrameParser.parseNetworks(text))
            }
            return true
        } catch {
            return true // a network hiccup, not an auth failure — let the socket try
        }
    }

    /// A native client CAN set headers on the WS upgrade, so the session token rides as
    /// a bearer where a browser would need a cookie.
    private func openSocket() {
        guard let token, let url = URL(string: Self.wsBase(baseURL) + "/ws") else { return }
        socket?.cancel(with: .goingAway, reason: nil)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        socket = task
        task.resume()
        // Optimistic: URLSession has no delegate-free "did open" signal, so we report
        // the socket up on resume like the prototype did. A refused upgrade surfaces as
        // the receive() failure below. A true open signal is #4's concern.
        emit(.socketOpen)
        receive(on: task)
    }

    /// `URLSessionWebSocketTask` has no stream — re-arm receive() after each frame.
    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message {
                    self.emit(FrameParser.parseWs(text))
                }
                self.receive(on: task)
            case .failure(let error):
                // A refused upgrade lands here. A 401 means the bearer never resolved —
                // the session is gone, not merely a dropped connection.
                let code = (task.response as? HTTPURLResponse)?.statusCode
                if code == 401 {
                    self.emit(.unauthorized)
                } else {
                    self.emit(.socketClosed(reason: error.localizedDescription, code: code))
                }
            }
        }
    }

    // MARK: - Verbs

    /// Ask the server to hydrate a buffer. Channels/DMs arrive as shells, so without
    /// this a tapped buffer renders blank. No-op for the system buffer (already full).
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
            guard let error else { return }
            self?.emit(.serverError("Send failed: \(error.localizedDescription)"))
        }
    }

    /// Drop the socket and forget the token without revoking server-side. For teardown
    /// and the dead-token case (a 401) where there's nothing left to revoke.
    func close() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        token = nil
    }

    /// The deliberate sign-out. Tears the local session down *immediately* (drops the
    /// socket + token) and fires the server-side revoke in the background, so sign-out
    /// feels instant even when the server is slow or unreachable. `POST /api/auth/logout`
    /// accepts the bearer. The revoke uses the captured token and never touches this
    /// client again, so a subsequent sign-in that mints a fresh session can't be
    /// clobbered by an in-flight revoke.
    func logout() {
        let revokeToken = token
        let base = baseURL
        close()
        guard let revokeToken, let url = URL(string: base + "/api/auth/logout") else { return }
        Task { [session] in
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(revokeToken)", forHTTPHeaderField: "Authorization")
            _ = try? await session.data(for: request)
        }
    }

    // MARK: - Helpers

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

    /// Frames arrive on URLSession's background delegate queue; hop to main so the
    /// `@MainActor` consumer can touch state and UIKit directly.
    private func emit(_ frame: ServerFrame) {
        let onFrame = self.onFrame
        DispatchQueue.main.async { MainActor.assumeIsolated { onFrame(frame) } }
    }
}
