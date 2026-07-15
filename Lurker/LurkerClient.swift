// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Prototype client for Lurker's WS + REST contract. Proves the bearer-auth work
/// end to end from a real iOS app against BOTH backends:
///   - self-hosted: mint a token at the cell (`POST /api/auth/login/token`,
///     lurker#489 / PR #570),
///   - hosted lurker.chat: mint at the control plane (`POST /_cp/auth/app/login`,
///     CP#58) — the CP verifies the account and hands back the same signed claim,
///     which its reverse proxy accepts as a Bearer and routes to the account's
///     cell. Everything after login is byte-identical: the same Bearer opens the
///     WebSocket and authenticates REST, because the proxy resolves it and injects
///     the real cell session transparently.
///
/// Deliberately NOT the shape the real app should take — no persistence, no
/// reconnect/resume, no `?since=` gap handling, no internal-model/transport-adapter
/// seam. State lives here and dies with the process. It answers one question: does
/// the contract work from a native client?
///
/// Callbacks are always delivered on the main queue, so view controllers can touch
/// UIKit directly from them.

struct Buffer: Hashable {
    /// nil for the app-scoped system buffer, which is read-only.
    let networkId: Int?
    let target: String
    let networkName: String

    var key: String { "\(networkId.map(String.init) ?? "sys")::\(target)" }
}

struct Msg: Hashable {
    let id: Int
    let type: String
    let nick: String
    let text: String
    let isSelf: Bool
}

/// The event types worth rendering in a prototype. The server sends far more
/// (join/part/quit/mode/names/typing/presence/…); a real client renders those as
/// inline system lines, but they'd just be noise here.
private let renderableTypes: Set<String> = ["message", "action", "notice", "error"]

final class LurkerClient: NSObject {
    private(set) var buffers: [Buffer] = []
    private(set) var messagesByBuffer: [String: [Msg]] = [:]

    /// Fires when the buffer list gains a row.
    var onBuffersChanged: (() -> Void)?
    /// Fires when a buffer's messages change, with that buffer's key.
    var onMessagesChanged: ((String) -> Void)?
    /// Fires on connect/disconnect of the WebSocket.
    var onConnectionChanged: ((Bool) -> Void)?
    /// Fires with a human-readable error, or nil to clear it.
    var onStatus: ((String?) -> Void)?

    private var token: String?
    private var baseURL: String = ""
    private var networkNames: [Int: String] = [:]
    private var socket: URLSessionWebSocketTask?
    private lazy var session = URLSession(configuration: .default)

    // MARK: - Auth

    /// Mint a session token from a password.
    ///
    /// - hosted=false → `POST /api/auth/login/token` on the cell (PR #570):
    ///   `{username, password}` in, `{token}` out.
    /// - hosted=true → `POST /_cp/auth/app/login` on the control plane (CP#58):
    ///   `{email, password}` in, `{token}` out. The token is a CP claim the proxy
    ///   accepts as a Bearer; from here on the flow is identical to self-hosted.
    func login(
        server: String,
        username: String,
        password: String,
        hosted: Bool = false,
        completion: @escaping (Bool) -> Void
    ) {
        let base = server.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        baseURL = base

        let loginPath = hosted ? "/_cp/auth/app/login" : "/api/auth/login/token"
        guard let url = URL(string: "\(base)\(loginPath)") else {
            fail("That server URL doesn't look right.", completion)
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(
            withJSONObject: [(hosted ? "email" : "username"): username, "password": password]
        )

        session.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                self.fail("Sign-in failed: \(error.localizedDescription)", completion)
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200,
                  let data,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = body["token"] as? String
            else {
                // 401 here means the password was wrong — or the account is
                // passkey-only, since the mint endpoint is password-only today.
                self.fail("Sign-in failed (HTTP \(code))", completion)
                return
            }
            self.token = token
            self.fetchNetworkNames {
                DispatchQueue.main.async {
                    self.onStatus?(nil)
                    completion(true)
                }
                self.openSocket()
            }
        }.resume()
    }

    private func fail(_ message: String, _ completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            self.onStatus?(message)
            completion(false)
        }
    }

    /// The WS snapshot identifies networks by id only — names live on the REST side.
    /// Doubles as proof that the same bearer authenticates plain REST calls, not just
    /// the socket.
    private func fetchNetworkNames(then: @escaping () -> Void) {
        guard let token, let url = URL(string: "\(baseURL)/api/networks") else {
            then()
            return
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        session.dataTask(with: req) { [weak self] data, _, _ in
            defer { then() }
            guard let self,
                  let data,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let networks = body["networks"] as? [[String: Any]]
            else { return }
            for network in networks {
                if let id = network["id"] as? Int {
                    self.networkNames[id] = network["name"] as? String ?? "network"
                }
            }
        }.resume()
    }

    // MARK: - WebSocket

    /// The whole point: a native client CAN set headers on the upgrade, so the session
    /// token rides as a bearer where a browser would be forced to use a cookie.
    private func openSocket() {
        guard let token else { return }
        // http -> ws, https -> wss.
        let wsBase = baseURL.replacingOccurrences(
            of: "^http", with: "ws", options: .regularExpression
        )
        guard let url = URL(string: "\(wsBase)/ws") else { return }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: req)
        socket = task
        task.resume()
        DispatchQueue.main.async { self.onConnectionChanged?(true) }
        receive()
    }

    /// URLSessionWebSocketTask has no "stream" — you re-arm receive() after each frame.
    private func receive() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message {
                    DispatchQueue.main.async { self.handle(frame: text) }
                }
                self.receive() // re-arm
            case .failure(let error):
                // A refused upgrade lands here. If the bearer never resolved to a
                // session, the response is a 401 and the socket dies immediately.
                let code = (self.socket?.response as? HTTPURLResponse)?.statusCode
                DispatchQueue.main.async {
                    self.onConnectionChanged?(false)
                    self.onStatus?(
                        code == 401
                            ? "WebSocket refused (401 — bad token)"
                            : "WebSocket closed: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func handle(frame text: String) {
        guard let data = text.data(using: .utf8),
              let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = frame["kind"] as? String
        else { return }

        switch kind {
        // One backlog frame per buffer arrives on connect. Channel and DM buffers come
        // as SHELLS (events: []) — the server doesn't read a buffer's history until the
        // client actually opens it. So this populates the buffer LIST, and open(_:) is
        // what fills a buffer in.
        case "backlog":
            guard let target = frame["target"] as? String, !target.isEmpty else { return }
            let networkId = frame["networkId"] as? Int
            let buffer = Buffer(
                networkId: networkId,
                target: target,
                networkName: networkId.flatMap { networkNames[$0] } ?? "system"
            )
            if !buffers.contains(where: { $0.key == buffer.key }) {
                buffers.append(buffer)
                onBuffersChanged?()
            }
            messagesByBuffer[buffer.key] = parse(events: frame["events"] as? [[String: Any]] ?? [])
            onMessagesChanged?(buffer.key)

        // Live traffic — including the echo of our OWN sends (self=true), which is why
        // this prototype needs no optimistic-bubble bookkeeping.
        case "irc":
            guard let target = frame["target"] as? String, !target.isEmpty else { return }
            let networkId = frame["networkId"] as? Int
            let key = "\(networkId.map(String.init) ?? "sys")::\(target)"
            guard let msg = parse(event: frame) else { return }
            messagesByBuffer[key, default: []].append(msg)
            onMessagesChanged?(key)

        case "error":
            onStatus?(frame["text"] as? String)

        default:
            break
        }
    }

    private func parse(events: [[String: Any]]) -> [Msg] {
        events.compactMap(parse(event:))
    }

    private func parse(event: [String: Any]) -> Msg? {
        guard let type = event["type"] as? String, renderableTypes.contains(type) else { return nil }
        return Msg(
            id: event["id"] as? Int ?? 0,
            type: type,
            nick: event["nick"] as? String ?? "*",
            text: event["text"] as? String ?? "",
            isSelf: event["self"] as? Bool ?? false
        )
    }

    // MARK: - Verbs

    /// Ask the server to hydrate a buffer. Shells arrive empty, so without this a tapped
    /// channel renders blank. The server replies with a real `backlog` frame, which
    /// handle(frame:) swaps in over the shell.
    func open(_ buffer: Buffer) {
        guard let networkId = buffer.networkId else { return } // system buffer is already full
        send(verb: ["type": "open-buffer", "networkId": networkId, "target": buffer.target])
    }

    func send(_ buffer: Buffer, text: String) {
        guard let networkId = buffer.networkId else { return }
        send(verb: [
            "type": "send",
            "networkId": networkId,
            "target": buffer.target,
            "text": text,
        ])
    }

    private func send(verb: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: verb),
              let text = String(data: data, encoding: .utf8)
        else { return }
        socket?.send(.string(text)) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async { self?.onStatus?("Send failed: \(error.localizedDescription)") }
        }
    }

    func messages(for buffer: Buffer) -> [Msg] {
        messagesByBuffer[buffer.key] ?? []
    }
}
