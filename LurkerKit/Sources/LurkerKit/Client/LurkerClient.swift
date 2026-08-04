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
    /// Monotonic request id for the `search` verb, echoed by the server so a reply can be
    /// matched to the call that's awaiting it. Deliberately not reset per socket: a token that
    /// outlives its connection must not be reused, or a late reply from the old one could
    /// answer a new question.
    private var searchToken = 0
    /// Searches awaiting a reply, by token. See `search(_:networkId:before:limit:)`.
    private var pendingSearches: [Int: CheckedContinuation<HighlightsPage?, Never>] = [:]

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
        guard await fetchNetworks() else { return }
        // Detached, so it genuinely cannot hold up the socket. `session` has the default 60s
        // request timeout, so a server that accepts the connection but stalls on this path — a
        // slow read, an overloaded cell, a proxy black-holing it — would otherwise leave the
        // app with no socket, no buffers and no messages for up to a minute on every launch.
        //
        // Ordering costs nothing now that values are cached across launches
        // (`SettingsCache`): the rules are already in force when the first backlog renders, so
        // there's nothing to wait for and nothing to reflow.
        Task { await fetchSettings() }
        openSocket()
    }

    /// Reopen the socket after a drop, resuming from `since` so the server ships only the
    /// gap (`?since=N`) rather than re-sending everything. Skips the roster re-fetch —
    /// names don't change and the reconnect snapshot re-sends live network state anyway.
    func reconnect(since: Int) {
        // Settings are re-fetched here, unlike the network roster.
        //
        // They're the one piece of state with no resume path: `settings` frames are live
        // fan-out only and are never replayed (the resume slice carries messages, not
        // settings), so a change made on the web while this phone was backgrounded or in
        // reconnect backoff would otherwise be invisible until the app was relaunched.
        Task { await fetchSettings() }
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

    /// `GET /api/settings/bootstrap` → the registry + the user's stored values (#65).
    ///
    /// Deliberately does NOT report a 401 the way `fetchNetworks` does. That call is the token
    /// check and has already run and passed by the time we get here; a 401 on this one would
    /// mean the token died in the intervening milliseconds, and treating it as an auth failure
    /// would bounce the user to sign-in over a settings fetch. The socket upgrade is the next
    /// thing to run and it will find out for itself.
    private func fetchSettings() async {
        guard let token, let url = URL(string: baseURL + "/api/settings/bootstrap") else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code), let text = String(data: data, encoding: .utf8) else { return }
            onFrame(FrameParser.parseSettingsBootstrap(text))
        } catch {
            // Registry defaults carry the app until the next launch.
        }
    }

    /// `PATCH /api/settings` (#65). The server validates against the registry and fans a
    /// `settings` frame back out to every device — including this one — so the store is
    /// updated by the echo rather than optimistically here. That keeps one path for "a setting
    /// changed" whether it came from this phone, the browser, or another device, and means a
    /// rejected write simply never takes effect rather than needing a rollback.
    ///
    /// Returns the server's error message on failure, nil on success.
    func updateSettings(_ changes: [String: SettingValue]) async -> String? {
        guard let token, let url = URL(string: baseURL + "/api/settings") else { return "Not signed in." }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = changes.mapValues(\.jsonValue)
        guard let payload = try? JSONSerialization.data(withJSONObject: ["changes": body]) else {
            return "Couldn't encode that setting."
        }
        request.httpBody = payload
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 {
                onFrame(.unauthorized)
                return "Signed out."
            }
            if (200..<300).contains(code) {
                // Apply the server's own response rather than waiting for the WS echo.
                //
                // Both arrive, on separate connections, racing each other. When the HTTP reply
                // wins — which it routinely does — a caller that rebuilt its UI at that moment
                // would read the OLD store value and visibly snap the control back before the
                // frame flipped it forward again. Worse, with the socket down (reconnect
                // backoff can run to tens of seconds, and `settings` frames are never
                // replayed) the echo may not arrive at all, leaving a write that succeeded
                // looking like one that failed.
                //
                // `values` is the full stored set, and the reducer patches rather than
                // replaces, so applying it is idempotent with the echo that follows.
                if let text = String(data: data, encoding: .utf8) {
                    onFrame(.settingsValues(FrameParser.parseSettingValues(
                        FrameParser.jsonObject(from: text)?["values"]
                    )))
                }
                return nil
            }
            // The server explains itself on a 400 (`{error, key}`); prefer its wording.
            let text = String(data: data, encoding: .utf8) ?? ""
            return FrameParser.errorMessage(from: text) ?? "Couldn't save that setting."
        } catch {
            return "Couldn't reach the server."
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
        // Same reason as `close()`: the replaced socket's callbacks are ignored from here, so
        // anything awaiting a reply on it has to be released now or it waits out its timeout.
        failPendingSearches()
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
        if let text {
            // A search reply is a reply, not state: it answers one awaiting call and never
            // travels on to the store. Intercepted here rather than routed through
            // `ChatViewModel` because request/reply correlation is this layer's job — the
            // store has no idea a question was asked.
            let frame = FrameParser.parseWs(text)
            if case .searchResult(let token, let page) = frame {
                finishSearch(token, with: page)
            } else {
                onFrame(frame)
            }
        }
        listen(on: task)
    }

    private func handleClose(code: Int?, reason: String, from task: URLSessionWebSocketTask) {
        guard task === socket else { return }
        // Whatever was waiting on this socket isn't being answered over it.
        failPendingSearches()
        // A refused upgrade with 401 means the bearer never resolved — the session is
        // gone, not merely a dropped connection.
        onFrame(code == 401 ? .unauthorized : .socketClosed(reason: reason, code: code))
    }

    // MARK: - Verbs

    /// Ask the server to OPEN a buffer — reopen a closed row, mint a DM row for a bare nick,
    /// or JOIN an unjoined channel. A WRITE, and one the user's other devices are now told
    /// about, so it belongs to deliberate intent only (`/query alice`, tapping a friend whose
    /// DM is closed server-side).
    ///
    /// **Not for hydration** — that's `loadLatest`. Filling in a shell with this verb is what
    /// made merely *opening a screen* reopen a buffer on every device the user owns, and,
    /// because the server's paused-account gate correctly classes writes as writes, made a
    /// paused account unable to read its own history at all.
    func openBuffer(networkId: Int?, target: String, countBy: HistoryCountBy) {
        guard let networkId else { return }
        send([
            "type": "open-buffer", "networkId": networkId, "target": target,
            "countBy": countBy.rawValue,
        ])
    }

    func sendMessage(networkId: Int?, target: String, text: String) {
        guard let networkId else { return }
        // The one write the user made deliberately, and the one with no resend behind it —
        // so a socket-level failure to deliver it is worth telling them about. A `send`
        // that reaches the server but is rejected comes back as a `send-result` instead;
        // this only covers never getting it onto the wire. The server splits on newlines and
        // byte-length, so the whole (possibly multi-line) body goes as one `send`.
        send(["type": "send", "networkId": networkId, "target": target, "text": text], surfacesFailure: true)
    }

    /// CTCP ACTION — `/me` and `/slap`. Surfaces a socket-level failure like `send`: it's a
    /// deliberate line the user typed, with nothing behind it to retry.
    func sendAction(networkId: Int?, target: String, text: String) {
        guard let networkId else { return }
        send(["type": "action", "networkId": networkId, "target": target, "text": text], surfacesFailure: true)
    }

    /// NOTICE — `/notice`. Same failure surfacing rationale as `send`.
    func sendNotice(networkId: Int?, target: String, text: String) {
        guard let networkId else { return }
        send(["type": "notice", "networkId": networkId, "target": target, "text": text], surfacesFailure: true)
    }

    /// A raw IRC line — the escape hatch behind `/nick`, `/mode`, `/kick`, `/whois`, the
    /// service messages, the server queries, and every unrecognized command.
    func sendRaw(networkId: Int?, line: String) {
        guard let networkId else { return }
        send(["type": "raw", "networkId": networkId, "line": line], surfacesFailure: true)
    }

    /// Part a channel with an optional reason. The buffer survives (dimmed); `/close` drops it.
    func part(networkId: Int?, channel: String, reason: String?) {
        guard let networkId else { return }
        var verb: [String: Any] = ["type": "part", "networkId": networkId, "channel": channel]
        if let reason { verb["reason"] = reason }
        send(verb)
    }

    /// A CTCP request aimed at a target — `/ctcp`, `/ping`. `issuingTarget` is the buffer the
    /// command was run in, so a reply can be routed back to it.
    func sendCTCP(networkId: Int?, target: String, issuingTarget: String, ctcpType: String, args: String) {
        guard let networkId else { return }
        send([
            "type": "ctcp",
            "networkId": networkId,
            "target": target,
            "issuingTarget": issuingTarget,
            "ctcpType": ctcpType,
            "args": args,
        ])
    }

    /// Store an ignore rule (`/ignore`, #86).
    ///
    /// **A nil `networkId` is a global rule — every network — not "no network."** That's the
    /// opposite of the guard every conversation verb above takes, and the reason this one has
    /// none: nil is the *default* scope here, and dropping the frame for it would silently
    /// swallow the commonest rule there is. `NSNull` rather than a missing key, so the scope is
    /// stated rather than inferred (the server distinguishes a null id from a malformed one).
    ///
    /// Fire-and-ask: the server re-validates, and the rule only exists once it fans an
    /// `ignore-list-updated` back. Surfaces a socket-level failure like the other deliberate
    /// writes — there's no queue behind it.
    ///
    /// **Returns false when it went nowhere**, and the caller must check: the command that
    /// sent this prints a receipt, and nothing else would contradict it. The window is real —
    /// `start()` awaits a REST call before opening the socket, and the composer is live the
    /// whole time.
    @discardableResult
    func addIgnore(networkId: Int?, rule: IgnoreRule) -> Bool {
        send(
            [
                "type": "add-ignore",
                "networkId": networkId.map { $0 as Any } ?? NSNull(),
                "rule": Self.ruleJSON(rule),
            ],
            surfacesFailure: true
        )
    }

    /// Drop ignore rules (`/unignore`): by `id` — what a listed index resolves to — or by
    /// `mask`, which clears every rule carrying it. `networkId` scopes it, nil meaning the
    /// global bucket; a by-mask removal on a network scope also clears matching globals, which
    /// is the server's behavior and why it answers with both buckets refreshed.
    ///
    /// Returns false when it went nowhere, for the same reason `addIgnore` does — and it
    /// matters more here, where the receipt the caller holds says something was *removed*.
    @discardableResult
    func removeIgnore(networkId: Int?, id: Int?, mask: String?) -> Bool {
        // Naming neither is a frame the server reads and discards, and reporting it as sent
        // would put a "removed …" receipt under it. The reference refuses the same call
        // (`ignores.ts`'s `if (by.id == null && !by.mask) return`).
        guard id != nil || mask != nil else { return false }
        var verb: [String: Any] = [
            "type": "remove-ignore",
            "networkId": networkId.map { $0 as Any } ?? NSNull(),
        ]
        if let id { verb["id"] = id }
        if let mask { verb["mask"] = mask }
        return send(verb, surfacesFailure: true)
    }

    /// A rule as `add-ignore` carries it. Unset dimensions are *omitted* rather than sent as
    /// null: the server reads an absent field as "unconstrained", which is the same thing and
    /// keeps the frame to what the rule actually says.
    ///
    /// `nonisolated static` so a test can assert the payload without a socket or the main
    /// actor — it is pure, and the isolation this class needs is about the socket. It's the
    /// encoder half of a shape `FrameParser.parseIgnoreRule` decodes, and the two are held
    /// together only by agreeing on these key names, so there is a round-trip test.
    nonisolated static func ruleJSON(_ rule: IgnoreRule) -> [String: Any] {
        var out: [String: Any] = [
            "levels": rule.levels,
            "patternKind": rule.patternKind.rawValue,
            "isExcept": rule.isExcept,
        ]
        if let mask = rule.mask { out["mask"] = mask }
        if let channels = rule.channels, !channels.isEmpty { out["channels"] = channels }
        if let pattern = rule.pattern { out["pattern"] = pattern }
        if let expiresAt = rule.expiresAt { out["expiresAt"] = ISOTime.string(from: expiresAt) }
        return out
    }

    /// Set yourself away on every network (`/away`), or clear it (`/back`, or `/away` with no
    /// message). User-scoped, so neither verb carries a networkId — the server keys on the
    /// account and fans out to all connections.
    func setAway(_ message: String) {
        send(["type": "away", "message": message])
    }

    func setBack() {
        send(["type": "back"])
    }

    /// Page older history for a buffer, back from `before` (exclusive message id). The
    /// reply is a `history` frame (mode `before`) the store prepends. System-buffer paging
    /// isn't wired for 1.0.
    func loadOlder(networkId: Int?, target: String, before: Int, countBy: HistoryCountBy, limit: Int = 100) {
        guard let networkId else { return }
        send([
            "type": "history", "networkId": networkId, "target": target,
            "before": before, "limit": limit, "countBy": countBy.rawValue,
        ])
    }

    /// Request a history slice centered on `anchorId` — the message to jump to (#42). The
    /// reply is a `history` frame (mode `around`) with the anchor included in the middle, which
    /// the store applies by replacing the buffer's slice. No `open-buffer` first: the server
    /// serves this straight from the DB. `limit` is per side, so up to `2*limit + 1` events.
    ///
    /// Carries `countBy` (sizing each side) because on this client a jump slice is not merely a
    /// jump: `hydrateIfNeeded` returns early while a jump is pending, so for a buffer entered
    /// from a push tap, a highlight, or jump-to-first-unread, THIS is the first screenful and
    /// no other hydrate precedes it.
    func loadAround(networkId: Int?, target: String, anchorId: Int, countBy: HistoryCountBy, limit: Int = 100) {
        guard let networkId else { return }
        send([
            "type": "history", "mode": "around",
            "networkId": networkId, "target": target, "anchorId": anchorId, "limit": limit,
            "countBy": countBy.rawValue,
        ])
    }

    /// Fetch a buffer's newest slice. Two callers, one request:
    ///
    /// 1. **Hydration** — filling in a shell when a screen opens on a buffer we hold but
    ///    haven't fetched. This is a pure READ: it reopens nothing, mints no row, JOINs
    ///    nothing, is invisible to the user's other devices, and is not blocked for a paused
    ///    account. `open-buffer` is none of those things, which is why hydration doesn't use
    ///    it. The server always answers, even for a buffer with no history at all, so a
    ///    one-shot caller can't be stranded waiting on a reply that will never come.
    /// 2. **Re-attaching** a detached buffer to the live tail (#42), after a jump left the
    ///    screen parked on an older `around` window.
    ///
    /// The reply is a `history` frame (mode `latest`); the store replaces the slice, marks the
    /// buffer hydrated, and clears `hasMoreNewer`. Carries `countBy` because for case 1 this
    /// reply is our first screenful — see `HistoryCountBy`.
    func loadLatest(networkId: Int?, target: String, countBy: HistoryCountBy, limit: Int = 100) {
        guard let networkId else { return }
        send([
            "type": "history", "mode": "latest", "networkId": networkId, "target": target,
            "limit": limit, "countBy": countBy.rawValue,
        ])
    }

    /// Page NEWER history for a detached buffer (scroll-down), forward from `after` (exclusive
    /// message id). The reply is a `history` frame (mode `after`) the store appends; once the
    /// server signals `hasMoreNewer: false` the slice has reached the live tail and the buffer
    /// re-attaches (#45). The mirror of `loadOlder`, and the read path that carries a jump-to-
    /// first-unread back down to the present without the pill's full `latest` re-fetch.
    func loadNewer(networkId: Int?, target: String, after: Int, countBy: HistoryCountBy, limit: Int = 100) {
        guard let networkId else { return }
        send([
            "type": "history", "mode": "after",
            "networkId": networkId, "target": target, "afterId": after, "limit": limit,
            "countBy": countBy.rawValue,
        ])
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

    /// Save or unsave a message. The server answers with a `bookmark-updated` fan-out to
    /// every socket on the account — including this one — so the caller doesn't (and
    /// shouldn't) flip any local state itself.
    ///
    /// Saving is silently refused for a message the account doesn't own, and no echo comes
    /// back for it. That's why the toggle isn't rendered optimistically: the honest failure
    /// is a control that doesn't move, not one that moves and then springs back.
    /// Returns false when the verb couldn't be sent at all (no socket — offline, or the app
    /// has just resumed and the socket isn't back). Nothing queues it, so a caller that has
    /// already taken a row off the screen has to know. `surfacesFailure` covers the rarer
    /// case of a socket that accepts the write and then errors.
    @discardableResult
    func setBookmark(messageId: Int, saved: Bool) -> Bool {
        send(
            ["type": saved ? "set-bookmark" : "unset-bookmark", "messageId": messageId],
            surfacesFailure: true
        )
    }

    /// Fetch a page of bookmarks (`GET /api/bookmarks`). Same cursor contract and same
    /// row shape as `fetchHighlights` — the server builds both from the same query so one
    /// list renderer serves both — so it reuses `HighlightsPage` rather than cloning it.
    ///
    /// Ordering is by *message* id, i.e. by when the line was said, not when it was saved.
    func fetchBookmarks(before: Int? = nil, limit: Int = 50) async -> HighlightsPage? {
        guard let token, var components = URLComponents(string: baseURL + "/api/bookmarks") else { return nil }
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before", value: String(before))) }
        components.queryItems = query
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 {
                onFrame(.unauthorized)
                return nil
            }
            guard (200..<300).contains(code), let text = String(data: data, encoding: .utf8) else { return nil }
            return FrameParser.parseHighlights(text)
        } catch {
            return nil
        }
    }

    // MARK: - Search

    /// Full-text search across every buffer the account owns — the WS `search` verb, awaited
    /// as a request/reply.
    ///
    /// **The only read in this client that isn't REST.** The server's FTS index has no HTTP
    /// route; search has always been a WS verb (the web client's store sends the same frame),
    /// and inventing a REST endpoint for one client would be a server change to avoid writing
    /// twenty lines here. So this is the one place the socket answers a question rather than
    /// announcing state, and the correlation is the client's job: each request carries a
    /// monotonic `token` the server echoes, and the matching reply resumes this call. The
    /// frame never reaches `onFrame` — see `ServerFrame.searchResult`.
    ///
    /// `networkId` is the caller's resolution of the query's `on:` *name*, which only the
    /// roster can turn into an id; the query itself carries the rest.
    ///
    /// Nil means no answer, never "no matches" (that's an empty page): the socket was dead
    /// when we asked, dropped while we waited, or the reply never came. All three leave the
    /// caller free to show an error rather than an empty list — a search that silently reads
    /// as "nothing matched" is the one wrong answer here.
    func search(
        _ query: SearchQuery,
        networkId: Int?,
        before: Int? = nil,
        limit: Int = 50
    ) async -> HighlightsPage? {
        searchToken += 1
        let token = searchToken
        var verb: [String: Any] = ["type": "search", "token": token, "limit": limit]
        // Only what the user actually filtered on. The server treats an absent key as
        // unfiltered and an empty string as a filter that matches nothing, so sending `""`
        // for an unused filter would return no rows for every search.
        if !query.text.isEmpty { verb["query"] = query.text }
        if !query.from.isEmpty { verb["nicks"] = query.from }
        if !query.target.isEmpty { verb["target"] = query.target }
        if let networkId { verb["networkId"] = networkId }
        if let before { verb["before"] = before }
        return await withCheckedContinuation { (continuation: CheckedContinuation<HighlightsPage?, Never>) in
            // Registered BEFORE the send: the reply hops to this actor to be handled, so a
            // continuation filed afterwards would be racing a frame that can't run until we
            // suspend — but the ordering is what makes that true, not luck, and it costs
            // nothing to state it.
            pendingSearches[token] = continuation
            guard send(verb) else {
                finishSearch(token, with: nil)
                return
            }
            // A reply that never comes would otherwise strand this call forever, and with it
            // whatever spinner the caller put up. Nothing retries a search — the user is
            // sitting in front of it and can type again — so the timeout resolves rather
            // than re-sends.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.searchTimeout))
                self?.finishSearch(token, with: nil)
            }
        }
    }

    /// Resolve one pending search, if it's still pending. Idempotent by removal, so the
    /// timeout firing after a reply landed (or a socket drop racing both) is a no-op rather
    /// than a double-resume crash.
    private func finishSearch(_ token: Int, with page: HighlightsPage?) {
        pendingSearches.removeValue(forKey: token)?.resume(returning: page)
    }

    /// Fail every in-flight search. Called when the socket goes away: their replies were
    /// coming over that socket and are not coming now, and a reconnect's `?since=` resume
    /// carries messages, not verb replies.
    private func failPendingSearches() {
        let pending = pendingSearches
        pendingSearches.removeAll()
        for (_, continuation) in pending { continuation.resume(returning: nil) }
    }

    /// Tell the network we're composing. Fire-and-forget: the server turns it into a
    /// `+typing` TAGMSG and there's no ack, so a dropped one simply lapses on the peer's lease
    /// rather than needing a retry.
    ///
    /// Guarded like `closeBuffer`, and for the same reason: this verb is meaningless without a
    /// real conversation on the other end. The app-scoped system buffer has no network to send
    /// over and a `:server:` log is a one-way feed, so both are dropped here rather than put on
    /// the wire as a frame the server would have to reject. That's also why there's no
    /// `NSNull()` branch — a null `networkId` never gets this far.
    func setTyping(networkId: Int?, target: String, signal: TypingSignal) {
        guard let networkId, !target.hasPrefix(":server:") else { return }
        send([
            "type": "typing",
            "networkId": networkId,
            "target": target,
            "state": signal.rawValue,
        ])
    }

    func markAllRead() {
        send(["type": "mark-all-read"])
    }

    /// Join a channel on a network, with an optional key for a `+k` channel. The server sends
    /// its backlog once joined, which materializes the buffer in the list.
    func joinChannel(networkId: Int, channel: String, key: String? = nil) {
        var verb: [String: Any] = ["type": "join", "networkId": networkId, "channel": channel]
        if let key { verb["key"] = key }
        send(verb)
    }

    /// Close a buffer: parts a channel and stops tracking a DM. The server pseudo-buffer
    /// (`:server:`) can't be closed. No-op for the system buffer (networkId nil).
    func closeBuffer(networkId: Int?, target: String) {
        guard let networkId, !target.hasPrefix(":server:") else { return }
        send(["type": "close-buffer", "networkId": networkId, "target": target])
    }

    /// Favorite a buffer (`favorite-buffer`). One flag, two UI surfaces: a channel lands
    /// under Favorites, a DM under Friends. The server refuses pseudo-buffers and CLOSED
    /// buffers, drops any pin the buffer held (one placement per buffer), and echoes the
    /// full `favorites-changed` list to every device.
    func favoriteBuffer(networkId: Int, target: String) {
        send(["type": "favorite-buffer", "networkId": networkId, "target": target])
    }

    /// Remove a favorite (`unfavorite-buffer`). Echoes `favorites-changed`.
    func unfavoriteBuffer(networkId: Int, target: String) {
        send(["type": "unfavorite-buffer", "networkId": networkId, "target": target])
    }

    /// Rewrite the global favorites order (`reorder-favorites`, id-form only — favorites
    /// span networks, so names can't address them). Send the FULL permuted list; a subset
    /// floats to the front and would demote everything unmentioned. The server echoes the
    /// authoritative `favorites-changed` either way (a stale set snaps this device back).
    func reorderFavorites(bufferIds: [Int]) {
        send(["type": "reorder-favorites", "bufferIds": bufferIds])
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

    /// Fetch a page of recent highlights (`GET /api/highlights`). `before` is the cursor
    /// from a prior page's `nextBefore` (nil for the first, newest page); the server pages
    /// backward by message id. Returns nil on any failure so the caller can show an error
    /// state — a 401 additionally bounces the session, matching `fetchNetworks`.
    func fetchHighlights(before: Int? = nil, limit: Int = 50) async -> HighlightsPage? {
        guard let token, var components = URLComponents(string: baseURL + "/api/highlights") else { return nil }
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { query.append(URLQueryItem(name: "before", value: String(before))) }
        components.queryItems = query
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 {
                onFrame(.unauthorized)
                return nil
            }
            guard (200..<300).contains(code), let text = String(data: data, encoding: .utf8) else { return nil }
            return FrameParser.parseHighlights(text)
        } catch {
            return nil
        }
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
    /// Returns whether the verb was actually handed to a socket. **False means it went
    /// nowhere** — there is no queue behind this, so a caller that shows the user a result
    /// has to check. Most callers legitimately don't: a `typing` tag or a `mark-read` that
    /// misses a dead socket is re-derived by the next connect, which is why this is
    /// discardable. Anything that mutates what's on screen is not in that category.
    ///
    /// True is "written to a live socket", not "the server acted on it" — a send that fails
    /// asynchronously still reports true here, and surfaces through `surfacesFailure`.
    @discardableResult
    private func send(
        _ verb: [String: Any],
        surfacesFailure: Bool = false,
        onFlush: (@Sendable () -> Void)? = nil
    ) -> Bool {
        guard let socket,
              let data = try? JSONSerialization.data(withJSONObject: verb),
              let text = String(data: data, encoding: .utf8)
        else {
            onFlush?()
            return false
        }
        socket.send(.string(text)) { [weak self] error in
            defer { onFlush?() }
            guard let error, surfacesFailure else { return }
            // Capture the reason (a String) before hopping — Error isn't Sendable, but its
            // localized description is, and it's what makes an offline/TLS failure legible.
            let reason = error.localizedDescription
            Task { @MainActor in self?.onFrame(.serverError("Send failed: \(reason)")) }
        }
        return true
    }

    /// Drop the socket and forget the token without revoking server-side. For teardown
    /// and the dead-token case (a 401) where there's nothing left to revoke.
    func close() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        token = nil
        hasEmittedOpen = false
        // A cancelled socket fires no `handleClose` (the `task === socket` guard drops it), so
        // this is the only thing that unblocks a search awaiting the socket we just dropped.
        failPendingSearches()
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

    // MARK: - Uploads

    /// Upload a prepared file to `POST /api/uploads` and return the stored object's URL.
    /// The body is streamed from a disk-backed multipart file (see `MultipartBody`), so the
    /// phone never holds the whole payload; `onProgress` reports the device→server leg.
    ///
    /// `filename`/`mime` are advisory — the server re-derives both from the magic bytes — so
    /// a wrong guess here at worst mislabels the history row, never routes around the image
    /// pipeline or the metadata scrub. The caller is responsible for having already
    /// compressed video to fit; a file over the instance cap comes back as `.tooLarge`.
    func upload(
        fileURL: URL,
        filename: String,
        mime: String,
        progressToken: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> UploadResponse {
        guard let token, let url = URL(string: baseURL + "/api/uploads") else {
            throw UploadError.notSignedIn
        }

        let body = try MultipartBody.assemble(
            token: progressToken, fileURL: fileURL, filename: filename, mime: mime
        )
        defer { try? FileManager.default.removeItem(at: body.fileURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        // A large body plus the server's own processing (re-encode / scrub / forward to the
        // provider) can outlast the 60 s default while the connection sits idle waiting for
        // the response. Give an upload real headroom so a big-but-fine file isn't killed.
        request.timeoutInterval = 300

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(
                for: request,
                fromFile: body.fileURL,
                delegate: UploadProgressDelegate(onProgress: onProgress)
            )
        } catch {
            let ns = error as NSError
            NSLog("[upload] transport error domain=%@ code=%d desc=%@", ns.domain, ns.code, ns.localizedDescription)
            throw UploadError.transport(error.localizedDescription)
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 {
            // A dead session on an upload is the same fact `fetchNetworks` reports — bounce
            // to sign-in — but also throw so the in-flight flow stops rather than "succeeding".
            onFrame(.unauthorized)
            throw UploadError.unauthorized
        }
        if code == 413 { throw UploadError.tooLarge }
        guard (200..<300).contains(code) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw UploadError.server(message ?? "Upload failed (HTTP \(code))")
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? Int,
              let storedURL = object["url"] as? String
        else {
            throw UploadError.server("The server accepted the upload but its reply was unreadable.")
        }
        return UploadResponse(
            id: id,
            url: storedURL,
            mime: object["mime"] as? String,
            canDelete: object["can_delete"] as? Bool ?? false,
            thumbnailUrl: object["thumbnail_url"] as? String
        )
    }

    // MARK: - Helpers

    /// How long a `search` waits for its reply before giving up. Generous: an FTS scan over a
    /// deep history on a small self-hosted box is not instant, and the failure this guards
    /// against is a reply that is never coming at all, not a slow one.
    private static let searchTimeout: Double = 20

    private static func sinceQuery(_ since: Int) -> String {
        since > 0 ? "?since=\(since)" : ""
    }

    /// http → ws, https → wss. Replacing only the leading `http` turns the trailing `s`
    /// of `https` into `wss` for free.
    private static func wsBase(_ base: String) -> String {
        base.replacingOccurrences(of: "^http", with: "ws", options: .regularExpression)
    }

}
