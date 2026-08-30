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
    /// Preview bytes only, so its cache can be purged on sign-out without touching API state.
    private let mediaSession: URLSession
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
    /// Uploads currently in flight, by the `progressToken` each one put in its multipart body
    /// — the sink for that upload's server-side progress (#47).
    ///
    /// This registry is also the filter. `upload-progress` fans out to every socket the user
    /// has open, so the phone gets frames for an upload the *browser* is running; matching on
    /// a token we ourselves minted is what keeps someone else's bytes off this readout. An
    /// unrecognized token is dropped, silently and correctly.
    private var uploadProgressSinks: [String: @Sendable (UploadServerProgress) -> Void] = [:]

    init(onFrame: @escaping (ServerFrame) -> Void) {
        self.onFrame = onFrame
        self.session = URLSession(configuration: .default)

        // ⚠⚠ Preview BYTES get their own session, and the separation is not tidiness.
        //
        // The cache has to be big: `URLCache` refuses to store any single response over ~5% of
        // its capacity, so against the shared 10 MB disk budget the ceiling is ~512 KB — under a
        // typical full-width preview image, which meant the proxy's `max-age=86400, immutable`
        // bought nothing and every image was re-fetched on every launch. 200 MB puts the
        // per-response ceiling around 10 MB, above the proxy's own 8 MB cap.
        //
        // But that cache was installed on the ONE session behind every authenticated endpoint —
        // login, settings, highlights, bookmarks, push, uploads, the socket upgrade — and
        // nothing purged it on sign-out. So while sign-out carefully cleared the preview
        // METADATA on the grounds that it is "the previous account's reading history", the
        // largest and most identifying artefact of that history, the pictures themselves, stayed
        // in Library/Caches for whoever signed in next. On its own session the purge is a
        // one-liner (`clearMediaCache`), and a 200 MB byte budget stops competing with API JSON
        // for the same eviction.
        let mediaConfiguration = URLSessionConfiguration.default
        mediaConfiguration.urlCache = URLCache(
            memoryCapacity: 16 * 1024 * 1024,
            diskCapacity: 200 * 1024 * 1024
        )
        self.mediaSession = URLSession(configuration: mediaConfiguration)
    }

    /// Drop every cached preview image. Sign-out only — see the session's own note.
    func clearMediaCache() {
        mediaSession.configuration.urlCache?.removeAllCachedResponses()
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
    /// gap (`?since=N`) rather than re-sending everything.
    ///
    /// Settings and the network roster are both re-read here, and for the same reason: they
    /// are the state with no resume path. `settings` frames are live fan-out only and are
    /// never replayed (the resume slice carries messages), and the roster is REST-only —
    /// nothing on the socket carries a network's name or its position.
    ///
    /// ⚠⚠ The roster read used to be skipped here, on the grounds that "names don't change".
    /// True, and twice beside the point. The *set* of networks changes (#136 — a network
    /// added elsewhere arrives nameless and stays that way), and so does their **order**: a
    /// drag-reorder on the web writes `position` with no frame of any kind, unlike pins,
    /// which at least have `pins-changed`. Skipped, the phone kept yesterday's order until
    /// the app was relaunched — on a screen whose whole point is that the two clients agree.
    ///
    /// Not awaited: a slow or failing roster read must not hold the socket down. It lands as
    /// a `networks` frame whenever it arrives, and the list re-sorts then.
    func reconnect(since: Int) {
        Task { await fetchSettings() }
        Task { await refreshNetworks() }
        openSocket(since: since)
    }

    /// Which roster read is the current one.
    ///
    /// ⚠⚠ Needed because `applyNetworks` is authoritative over membership in both directions
    /// — a network absent from a response is deleted, buffers and pins with it — and several
    /// reads can now be in flight at once (every reconnect attempt starts one, alongside the
    /// ones a create, a delete or a nameless network start). Land them out of order and the
    /// older answer wins: a network deleted a moment ago reappears in the buffer list, the
    /// join menu and `on:` search, or one added on the web is dropped along with its buffers.
    /// The networks screen keeps the same guard over its own fetches for the same reason.
    private var rosterGeneration = 0

    /// Returns false only when the token was rejected (401) *and* the caller asked to hear
    /// about it; true otherwise, including transient errors where the socket is still worth
    /// trying.
    ///
    /// `reportingUnauthorized` is true only for the connect-time read, which is the token
    /// check — see `refreshNetworks` for why every other caller wants it off.
    private func fetchNetworks(reportingUnauthorized: Bool = true) async -> Bool {
        guard let token, let url = URL(string: baseURL + "/api/networks") else { return true }
        rosterGeneration += 1
        let generation = rosterGeneration
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401, reportingUnauthorized {
                onFrame(.unauthorized)
                return false
            }
            // A read that a newer one has already superseded is dropped rather than applied:
            // see `rosterGeneration`. Checked here rather than earlier so a 401 on the token
            // check still reports, superseded or not.
            guard generation == rosterGeneration else { return true }
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

    // MARK: - Networks (#11)

    /// Re-read the network roster: after a network is created or deleted from this app, when
    /// a `snapshot` names one we hold no name for (#136), and on every reconnect (see
    /// `reconnect` for why that one is not the waste it looks like).
    ///
    /// ⚠⚠ Does NOT report a 401, unlike the connect-time read. There it IS the token check
    /// and a rejection has to end the session; here it is a background refresh that can run
    /// during a flapping reconnect, and bouncing the user to sign-in over a roster GET is
    /// exactly what `fetchSettings` refuses to do three functions down, for the same reason.
    /// The socket is the thing that finds out whether the session is still good.
    func refreshNetworks() async {
        _ = await fetchNetworks(reportingUnauthorized: false)
    }

    /// `GET /api/networks`, read as editable configuration rather than as the roster.
    ///
    /// Nil means no answer — unauthenticated, offline, unreadable — never "no networks",
    /// which is an empty array and a legitimate state for a fresh account. The screen has to
    /// tell those apart: one is an error, the other is the empty state that invites you to
    /// add your first network.
    func networkConfigs() async -> [NetworkConfig]? {
        switch await rest("GET", "/api/networks") {
        case .ok(let text): return FrameParser.parseNetworkConfigs(text)  // nil if unreadable
        case .failure: return nil
        }
    }

    /// `GET /api/network-presets` — what this instance recommends, and whether anything else
    /// is allowed.
    ///
    /// Nil is "we couldn't ask". The picker falls back to the bundled catalogue on nil rather
    /// than showing an error: the builtins are already on the device, and a failed request
    /// for the instance's *extra* suggestions is no reason to refuse to add a network.
    func networkPresets() async -> NetworkPresets? {
        switch await rest("GET", "/api/network-presets") {
        case .ok(let text): return FrameParser.parseNetworkPresets(text)
        case .failure: return nil
        }
    }

    /// `POST /api/networks`. The server connects the new network immediately, regardless of
    /// `autoconnect` — that flag governs cold start, not this.
    func createNetwork(_ draft: NetworkDraft) async -> NetworkSaveResult {
        if let problem = draft.validationError { return .failure(message: problem) }
        return await save("POST", "/api/networks", body: draft.jsonBody(includeDefaultChannel: true))
    }

    /// `PATCH /api/networks/:id`. Takes effect on the next connection: the server updates the
    /// row, and an established connection keeps whatever it registered with.
    func updateNetwork(id: Int, draft: NetworkDraft) async -> NetworkSaveResult {
        // ⚠ Checked here and not only on create: `PATCH` sets whatever keys it is given and
        // validates none of them, so this client is the only thing standing between an edit
        // and a network stored with no name. See `NetworkDraft.validationError`.
        if let problem = draft.validationError { return .failure(message: problem) }
        return await save("PATCH", "/api/networks/\(id)", body: draft.jsonBody(includeDefaultChannel: false))
    }

    private func save(_ method: String, _ path: String, body: [String: Any]) async -> NetworkSaveResult {
        switch await rest(method, path, body: body) {
        case .ok(let text):
            guard let config = FrameParser.parseNetworkReply(text) else {
                // ⚠ A 2xx we can't read is a write that HAPPENED — its own case, so a caller
                // can dismiss rather than invite the retry that creates the network twice.
                // The roster is re-read here rather than in the caller's `.saved` branch:
                // it's how a new network becomes visible at all, and nothing else fetches it
                // before the next reconnect.
                await refreshNetworks()
                return .savedWithoutDetail
            }
            return .saved(config)
        case .failure(let message):
            return .failure(message: message)
        }
    }

    /// Delete the network and everything under it. Nil on success, a message otherwise.
    func deleteNetwork(id: Int) async -> String? {
        await act("DELETE", "/api/networks/\(id)")
    }

    /// Start, stop, or restart the connection. Nil on success, a message otherwise.
    ///
    /// None of these returns the resulting state: the server answers `{ok:true}` the moment
    /// it has told the connection manager, and the transition itself arrives over the socket
    /// as `state` events. So the caller's job is to report a refusal, not to update a light.
    func connectNetwork(id: Int) async -> String? {
        await act("POST", "/api/networks/\(id)/connect")
    }

    func disconnectNetwork(id: Int, reason: String? = nil) async -> String? {
        await act("POST", "/api/networks/\(id)/disconnect", body: reason.map { ["reason": $0] })
    }

    func reconnectNetwork(id: Int) async -> String? {
        await act("POST", "/api/networks/\(id)/reconnect")
    }

    private func act(_ method: String, _ path: String, body: [String: Any]? = nil) async -> String? {
        switch await rest(method, path, body: body) {
        case .ok: return nil
        case .failure(let message): return message
        }
    }

    // MARK: - REST

    private enum RestResult {
        case ok(String)
        case failure(String)
    }

    /// One authenticated JSON round trip: bearer header, optional JSON body, and a reply that
    /// is either the 2xx body text or a message fit to put in front of the user.
    ///
    /// Written for #11, which adds seven endpoints to a file that had been hand-rolling the
    /// same `URLRequest` per call. It is not a migration — the existing calls keep their own
    /// bodies until something needs to touch them anyway — but nothing new should be adding
    /// an eighth copy of bearer-plus-status-code.
    ///
    /// ⚠ A 401 bounces the session, matching `fetchNetworks`. Everything routed through here
    /// is a deliberate user action, so a dead token has to end the session rather than read
    /// as "that network wouldn't save". (`fetchSettings` deliberately does the opposite and
    /// keeps its own path — see its note for why.)
    private func rest(_ method: String, _ path: String, body: [String: Any]? = nil) async -> RestResult {
        guard let token, let url = URL(string: baseURL + path) else {
            return .failure("Not signed in.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
                return .failure("Couldn't encode that request.")
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = payload
        }
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data, encoding: .utf8) ?? ""
            if code == 401 {
                onFrame(.unauthorized)
                return .failure("Signed out.")
            }
            if (200..<300).contains(code) { return .ok(text) }
            // The server explains its own refusals — a host the admin's allowlist excludes, a
            // missing field, a paused account — and its wording is better than anything this
            // layer could infer from a status code.
            return .failure(FrameParser.errorMessage(from: text) ?? "The server refused that (\(code)).")
        } catch {
            return .failure("Couldn't reach the server.")
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
        if let text {
            // Upload progress is a reply, not state: it answers about one thing this device
            // started, matched by the token that started it, and never travels on to the store.
            // Intercepted here rather than routed through `ChatViewModel` because request/reply
            // correlation is this layer's job — the store has no idea a question was asked.
            //
            // ⚠ It used to have company: a WS `search-result` was correlated the same way. Search
            // is a REST read now (#123), so this is the last frame on the socket that answers a
            // question rather than announcing something.
            let frame = FrameParser.parseWs(text)
            switch frame {
            case .uploadProgress(let token, let progress):
                uploadProgressSinks[token]?(progress)
            default:
                onFrame(frame)
            }
        }
        listen(on: task)
    }

    private func handleClose(code: Int?, reason: String, from task: URLSessionWebSocketTask) {
        guard task === socket else { return }
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

    /// The wire form of a `send`/`action`/`notice`, with the ACK correlator attached.
    ///
    /// ⚠⚠ `clientId` is what makes a refused send visible AT ALL. `wsHub` emits `send-result`
    /// only when the request carried one, so without this the frame is never sent — and every
    /// failure the server declines to also announce as a bare `error` frame (`not-connected`,
    /// notably, which is the ordinary outcome of any reconnect since lurker#809's writable-
    /// connection gate) reached this client as silence: composer cleared, no self row fanned
    /// back, message gone. `FrameParser`, `ServerFrame` and `LurkerStore` all handled
    /// `send-result` correctly the whole time; nothing ever asked for one (#128).
    private func verb(
        _ type: String, networkId: Int, target: String, text: String, clientId: String?
    ) -> [String: Any] {
        var out: [String: Any] = [
            "type": type, "networkId": networkId, "target": target, "text": text,
        ]
        // Omitted rather than sent as null when absent: the server tests presence.
        if let clientId { out["clientId"] = clientId }
        return out
    }

    @discardableResult
    func sendMessage(networkId: Int?, target: String, text: String, clientId: String? = nil) -> Bool {
        guard let networkId else { return false }
        // The one write the user made deliberately, and the one with no resend behind it —
        // so a socket-level failure to deliver it is worth telling them about. A `send`
        // that reaches the server but is rejected comes back as a `send-result` instead;
        // this only covers never getting it onto the wire. The server splits on newlines and
        // byte-length, so the whole (possibly multi-line) body goes as one `send`.
        return send(
            verb("send", networkId: networkId, target: target, text: text, clientId: clientId),
            surfacesFailure: true)
    }

    /// CTCP ACTION — `/me` and `/slap`. Surfaces a socket-level failure like `send`: it's a
    /// deliberate line the user typed, with nothing behind it to retry.
    @discardableResult
    func sendAction(networkId: Int?, target: String, text: String, clientId: String? = nil) -> Bool {
        guard let networkId else { return false }
        return send(
            verb("action", networkId: networkId, target: target, text: text, clientId: clientId),
            surfacesFailure: true)
    }

    /// NOTICE — `/notice`. Same failure surfacing rationale as `send`.
    @discardableResult
    func sendNotice(networkId: Int?, target: String, text: String, clientId: String? = nil) -> Bool {
        guard let networkId else { return false }
        return send(
            verb("notice", networkId: networkId, target: target, text: text, clientId: clientId),
            surfacesFailure: true)
    }

    /// A raw IRC line — the escape hatch behind `/nick`, `/mode`, `/kick`, `/whois`, the
    /// service messages, the server queries, and every unrecognized command.
    ///
    /// **Returns false when it went nowhere.** Most callers rightly ignore that — a raw line
    /// is fire-and-forget and its answer is whatever the server buffer prints. The WHOIS
    /// behind the profile screen is the exception, and it is why this returns at all: it
    /// claims an in-flight slot that only a reply can free, so a line that never left the
    /// socket would wedge that nick's lookup for the session (see `whoisPending`).
    @discardableResult
    func sendRaw(networkId: Int?, line: String) -> Bool {
        guard let networkId else { return false }
        return send(["type": "raw", "networkId": networkId, "line": line], surfacesFailure: true)
    }

    /// Write or clear the account's note about a nick (#12).
    ///
    /// Fire-and-ask, exactly like `setRelayBot` above: the server caps the note at 4 KB,
    /// stores it, and fans a `nick-note-updated` back to every device — the note exists only
    /// once that lands. Nothing is written locally, so a save the server refuses never appears.
    ///
    /// ⚠ **An empty `note` is the delete**, and that's the server's encoding rather than a
    /// convention chosen here: `set_nick_note` drops the row for an empty string and echoes
    /// back `note: ''`, so the clear and the write are one verb and one frame shape.
    /// ⚠ Refuses a blank nick rather than sending one. The server trims and throws
    /// `invalid_input`, and the WS handler swallows that throw (`wsHub.ts:3491`) — so no frame
    /// comes back, and since nothing is written optimistically the editor would show a save
    /// that silently did nothing. Same guard `requestWhois` makes, for the same reason.
    @discardableResult
    func setNickNote(networkId: Int, nick: String, note: String) -> Bool {
        let nick = nick.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nick.isEmpty else { return false }
        return send(
            ["type": "set-nick-note", "networkId": networkId, "nick": nick, "note": note],
            surfacesFailure: true
        )
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

    /// Mark or unmark a nick as a relay/bridge bot on a network (#277) — what `/relay add` and
    /// `/relay remove` send. `pattern` is the custom envelope template; empty means the built-in
    /// formats, which is what a bare mark stores.
    ///
    /// Fire-and-ask, like the ignore verbs above: the server validates, stores, and fans a
    /// `relay-bot-updated` back to every device, and the mark exists only once that lands. Nothing
    /// is written locally, so a mark the server refuses never appears — and one made in a browser
    /// arrives here by the identical route.
    ///
    /// **Returns false when it went nowhere**, and the caller must check, for the same reason
    /// `addIgnore` does: `/relay` prints a receipt and nothing else would contradict it.
    @discardableResult
    func setRelayBot(networkId: Int, nick: String, marked: Bool, pattern: String) -> Bool {
        send(
            [
                "type": "set-relay-bot",
                "networkId": networkId,
                "nick": nick,
                "marked": marked,
                "pattern": pattern,
            ],
            surfacesFailure: true
        )
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

    /// Full-text search across every buffer the account owns — `GET /api/search`.
    ///
    /// ⚠⚠ A REST read since lurker#800, and the change is a DELETION: this used to be the one
    /// read in this client that wasn't. As a WS verb it needed a monotonic token echoed by the
    /// server, a pending-continuation map, a timeout to stop an unanswered call stranding its
    /// spinner forever, and a sweep to fail everything in flight when the socket dropped. HTTP
    /// gives every request its own reply, so all of that goes.
    ///
    /// ⚠⚠ And a superseded search now actually STOPS. Cancelling the enclosing task cancels the
    /// URLSession request, the route checks `req.destroyed` before spending the query, and the
    /// server does no work for a question nobody is waiting on. There was no WS cancel frame — a
    /// stale search ran to completion and the reply was discarded — which mattered because the
    /// FTS query runs on the same event loop that services every IRC connection on the cell.
    ///
    /// `networkId` is the caller's resolution of the query's `on:` *name*, which only the roster
    /// can turn into an id; the query itself carries the rest.
    ///
    /// Nil means no answer, never "no matches" (that's an empty page): unauthenticated, offline,
    /// or a response we couldn't read. All three leave the caller free to show an error rather
    /// than an empty list — a search that silently reads as "nothing matched" is the one wrong
    /// answer here.
    func search(
        _ query: SearchQuery,
        networkId: Int?,
        before: Int? = nil,
        limit: Int = 50
    ) async -> HighlightsPage? {
        guard let token,
            let url = SearchRequest.url(
                base: baseURL, query: query, networkId: networkId, before: before, limit: limit)
        else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            // ⚠ `scoped:` is what makes a 404 readable here — see `SearchRequest.outcome`, where
            // the rule lives so it can be tested.
            switch SearchRequest.outcome(status: code, scoped: networkId != nil) {
            case .unauthorized:
                onFrame(.unauthorized)
                return nil
            case .emptyPage: return HighlightsPage(items: [], nextBefore: nil)
            case .failed: return nil
            case .page: break
            }
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            // Same `{items, nextBefore}` envelope as highlights and bookmarks, and the same
            // decorated rows — the route and the WS verb call the same `search_messages`. The
            // cursor is now the server's rather than one synthesized from `hasMore` plus the last
            // row's id, which is the other half of the deletion.
            return FrameParser.parseHighlights(text)
        } catch {
            return nil
        }
    }

    // MARK: - Upload history

    /// One page of the account's upload history — `GET /api/uploads` (#138).
    ///
    /// A plain REST read like bookmarks and search, and for the same reason: the client only
    /// holds the pages it has scrolled through, so the filename search and the kind filter are
    /// questions for the server rather than predicates over what happens to be in memory.
    ///
    /// Nil means no answer, never "nothing matched" (that's an empty page): unauthenticated,
    /// offline, or a response we couldn't read. All three leave the caller free to offer a retry
    /// rather than claiming the browse came back empty.
    func fetchUploads(
        filter: UploadsFilter,
        before: Int? = nil,
        limit: Int
    ) async -> UploadsPage? {
        guard let token,
            let url = UploadsRequest.url(base: baseURL, filter: filter, before: before, limit: limit)
        else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch UploadsRequest.outcome(status: code) {
            case .unauthorized:
                onFrame(.unauthorized)
                return nil
            case .failed: return nil
            case .page: break
            }
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            return FrameParser.parseUploads(text)
        } catch {
            return nil
        }
    }

    /// Star or unstar an upload. Nil on success, else a sentence to put in front of the user.
    ///
    /// ⚠ Its own subpath rather than a field on a PATCH of the row, matching the route:
    /// everything else about an upload is immutable once captured, and a general-purpose PATCH
    /// would imply otherwise.
    func setUploadFavorite(id: Int, favorite: Bool) async -> String? {
        await act(favorite ? "PUT" : "DELETE", "/api/uploads/\(id)/favorite")
    }

    /// Destroy an upload's bytes and drop its row. Nil on success, else the server's own reason.
    ///
    /// ⚠⚠ Only ever called for a row whose `canDelete` is set. There is deliberately no
    /// remove-the-record-but-leave-the-file path — the route answers 409 for a row whose bytes
    /// can't be destroyed, so asking for one is a bug on this side, not a case to handle.
    func deleteUpload(id: Int) async -> String? {
        await act("DELETE", "/api/uploads/\(id)")
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

    /// A URL `AVPlayer` can actually open for a preview's `src`.
    ///
    /// ⚠⚠ `AVURLAsset` cannot carry our Authorization header — the supported way to inject one is
    /// an `AVAssetResourceLoaderDelegate`, and the header key that looks like a shortcut is
    /// undocumented. So the two cases are handled honestly rather than papered over:
    ///
    ///   - **An ABSOLUTE url** hands straight to `AVPlayer`, which then gets real streaming and
    ///     seeking for free. ⚠⚠ It is a THIRD-PARTY address, not ours: the only caller passes
    ///     `preview.url`, because the server stopped minting a `src` for video and audio and the
    ///     bytes now stream from the origin. It was the byte cache's own CDN url when this was
    ///     written, which is the reading to be careful of — nothing here has been vetted, so it
    ///     must never be given a credential, a cache policy, or any trust that belonged to the
    ///     old branch. Carrying no Authorization header stopped being a nicety and became the
    ///     requirement.
    ///   - **A PROXY PATH** is bearer-gated, so the bytes are streamed through the authenticated
    ///     path we already have and staged to a file. No seeking until it lands.
    ///
    /// ⚠ That staging used to be justified here as "bounded by the proxy's 8 MB cap". It is not:
    /// 8 MB is the cap for IMAGES, and video and audio get `MAX_MEDIA_PROXY_BYTES` — sixty-four.
    /// The reassurance was about a different limit than the branch it was written on.
    ///
    /// ⚠ The extension is carried over from the server's `mime`, because AVFoundation sniffs the
    /// path: a temp file called `x.tmp` fails to open as an MP4 that plays perfectly as `x.mp4`.
    func playableMediaURL(path: String, mime: String?) async -> URL? {
        // ⚠ LOWERCASED, because `URL.scheme` keeps the case it was written in (measured:
        // `URL(string: "HTTPS://h/a.mp4")?.scheme` is `"HTTPS"`) and `isViewable` — the gate that
        // decides this is worth opening at all — folds case before it compares. Raw, the two
        // disagreed on exactly the addresses `LinkPreviewViewableTests.testSchemeMatchIs-
        // CaseInsensitive` admits: into the gallery, past the tap, missed here, refused by
        // `mediaRequest` as well, and the page dead-ended on "There's nothing to play here" for
        // an address that plays perfectly.
        if let absolute = URL(string: path), let scheme = absolute.scheme?.lowercased(),
            scheme == "https" || scheme == "http"
        {
            // ⚠⚠ The same cleartext rule `LinkPreview.isViewable` gates on, asked of the same
            // `LocalNetworking`, because this is the function that hands an address to
            // AVFoundation. `isViewable` is the gate — nothing reaches a player page without
            // passing it — and this is the backstop: a second caller, or the two drifting, would
            // otherwise put back the ATS dead end this change exists to remove. One authority,
            // asked twice, is the only version of that which can't disagree with itself.
            if scheme == "http" {
                // Strict about a missing host too, the way `isViewable` is: `http:///a.mp4` has
                // nothing to reach, so there is nothing to permit.
                guard let host = absolute.host, LocalNetworking.permitsCleartext(host: host)
                else { return nil }
            }
            return absolute
        }
        guard let request = Self.mediaRequest(for: path, baseURL: baseURL, token: token) else {
            return nil
        }

        // ⚠⚠ STREAMED to disk, never buffered. This used to read the whole clip into a `Data`
        // and then write a second copy, both on the main actor, justified by a comment claiming
        // "the proxy's 8 MB cap" — which is the cap for IMAGES. Video and audio get
        // MAX_MEDIA_PROXY_BYTES, sixty-four megabytes, so the reassurance was about a different
        // limit than the branch it was written on: 128 MB of main-actor allocation while the
        // viewer animates in.
        let staged = Self.stagedMediaURL(for: path, mime: mime)
        // ⚠ Named from a STABLE digest. `String.hashValue` is reseeded every launch, so the
        // reuse check could never hit across cold starts: every clip was re-downloaded and
        // re-written while the previous launch's copies stayed on disk under names nothing would
        // ever look for again. (It also trapped on `Int.min` through `abs`.)
        if FileManager.default.fileExists(atPath: staged.path) { return staged }
        do {
            let (temporary, response) = try await mediaSession.download(for: request)
            guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else {
                try? FileManager.default.removeItem(at: temporary)
                return nil
            }
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.moveItem(at: temporary, to: staged)
            return staged
        } catch {
            return nil
        }
    }

    /// Where a proxied clip is staged for playback.
    ///
    /// ⚠ `Library/Caches`, not `temporaryDirectory` — the previous comment claimed the former and
    /// used the latter. This is a copy of something the server will hand over again, so the OS
    /// reclaiming it under pressure is exactly right.
    nonisolated private static func stagedMediaURL(for path: String, mime: String?) -> URL {
        // FNV-1a: stable across launches, unlike `String.hashValue`, and enough to name a file.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(path.utf8) {
            hash = (hash ^ UInt64(byte)) &* 0x1000_0000_01b3
        }
        let name = String(hash, radix: 36) + "." + fileExtension(for: mime)
        return stagedMediaDirectory().appendingPathComponent(name)
    }

    nonisolated private static func stagedMediaDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("preview-media", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Delete every staged clip. Sign-out only.
    ///
    /// ⚠⚠ Without this the departing account's VIDEOS sat on disk in the clear for whoever
    /// signed in next — while the same teardown carefully cleared the metadata store, the
    /// decoded-image cache and the media `URLCache` on the grounds that they were that person's
    /// reading history. The heaviest and most identifying artefact was the one nobody deleted.
    /// The `mediaSession` split closed this exact hole one layer up; this is the layer below it.
    func clearStagedMedia() {
        try? FileManager.default.removeItem(at: Self.stagedMediaDirectory())
    }

    /// ⚠ Only what AVFoundation can actually open. webm and ogg are deliberately absent: the
    /// server will happily proxy them (`kindForContentType` passes any `video/*`) and this
    /// platform cannot decode either, so they fall through to `bin` and the caller's
    /// "can't play this" path — which offers the browser — rather than a player that spins.
    nonisolated private static func fileExtension(for mime: String?) -> String {
        switch mime?.lowercased() {
        case "video/mp4": "mp4"
        case "video/quicktime": "mov"
        case "video/x-m4v": "m4v"
        case "audio/mpeg", "audio/mp3": "mp3"
        case "audio/mp4", "audio/x-m4a": "m4a"
        case "audio/aac": "aac"
        case "audio/wav", "audio/x-wav": "wav"
        case "audio/flac", "audio/x-flac": "flac"
        default: "bin"
        }
    }

    /// The instance's feature flags, or **nil if we didn't get an answer**.
    ///
    /// ⚠⚠ Optional deliberately. This used to collapse a transport error, a non-2xx, an
    /// unparseable body and a genuinely-off flag into the same all-off value — so one 502 or DNS
    /// hiccup on the single call at cold launch silently disabled link previews for the whole
    /// app session on an instance that has them on, with nothing to notice and no retry. A
    /// default is not a statement: the caller needs to tell "the server says no" from "the
    /// server didn't say", because only one of those is worth latching.
    ///
    /// ⚠ Short timeout, against the session's 60s default. Nothing waits on this to render, and
    /// a flag that decides whether to DECORATE messages must never be in a position to delay
    /// getting them.
    func fetchFeatures() async -> InstanceFeatures? {
        guard let request = Self.configRequest(baseURL: baseURL, token: token) else { return nil }
        do {
            let (data, response) = try await session.data(for: request)
            return Self.parseFeatures(data, code: (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            return nil
        }
    }

    /// The request for `/api/config`.
    ///
    /// ⚠⚠ It carries the bearer token, even though the server calls this endpoint "public,
    /// unauthenticated bootstrap config the client can read before login". That is true of a
    /// self-hosted instance and false of a hosted one: on lurker.chat the control plane proxies
    /// `/api/*` to a CELL, and it works out which cell from the caller's session. An anonymous
    /// request has nothing to route on, so it comes back `401 {"error":"not routable"}` — which
    /// this client correctly reads as "no answer", leaving previews off forever on precisely the
    /// deployment most people use. The browser never noticed because its fetch carries the
    /// session cookie; native auth is a Bearer header and has to be asked for.
    ///
    /// ⚠ Harmless where it genuinely is public — an instance that ignores the header returns the
    /// same body — so there is one code path rather than a deployment test the client would have
    /// to get right.
    ///
    /// `nonisolated static` for the same reason as `mediaRequest`: the property worth asserting
    /// is invisible through the awaiting method, which can only answer "no flags".
    nonisolated static func configRequest(baseURL: String, token: String?) -> URLRequest? {
        guard let url = URL(string: baseURL + "/api/config") else { return nil }
        var request = URLRequest(url: url)
        // Nothing waits on this to render, and a flag deciding whether to DECORATE messages must
        // never be in a position to delay getting them.
        request.timeoutInterval = 10
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// `/api/config` → flags, or **nil for "that wasn't an answer"**.
    ///
    /// ⚠ An absent `features` object IS an answer: an older instance that doesn't have the
    /// feature. Only a failure to obtain a well-formed response is unknown — and the difference
    /// decides whether the caller latches the result or retries it on the next reconnect.
    ///
    /// `nonisolated static` per `mediaRequest`'s note: this is the half worth asserting and it
    /// is unreachable through the awaiting method without a live server.
    nonisolated static func parseFeatures(_ data: Data, code: Int) -> InstanceFeatures? {
        guard (200..<300).contains(code),
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let features = body["features"] as? [String: Any]
        return InstanceFeatures(linkPreviews: features?["linkPreviews"] as? Bool == true)
    }

    // MARK: - Link previews

    /// Resolve a batch of URLs to preview descriptors (`POST /api/link-preview/resolve`).
    ///
    /// Returns whatever the server could answer; a URL it couldn't resolve simply comes back
    /// with `status: .unavailable`, and a failed request comes back as an empty array. Both
    /// mean "draw nothing", which is the only outcome a message row cares about — a preview
    /// is decoration, and an error state in the timeline would be worse than a missing card.
    func resolveLinkPreviews(_ urls: [String]) async -> [LinkPreview] {
        guard !urls.isEmpty, let token, let url = URL(string: baseURL + "/api/link-preview/resolve")
        else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["urls": urls])
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 {
                onFrame(.unauthorized)
                return []
            }
            guard (200..<300).contains(code) else { return [] }
            return Self.decodePreviews(data)
        } catch {
            return []
        }
    }

    /// The resolve response's descriptors, skipping any this build cannot understand.
    ///
    /// ⚠⚠ Decoded ELEMENT BY ELEMENT, not as `[LinkPreview]` in one go. `kind` and `status` are
    /// non-optional raw-value enums with no unknown case, so a single descriptor carrying a
    /// value this build doesn't know would throw inside the array decode and take the whole
    /// batch of twenty with it — indistinguishable, one layer up, from a transport failure. The
    /// store would then arm all twenty for retry, and because a decode failure is deterministic
    /// every retry fails identically: nineteen perfectly good previews never rendering, and all
    /// twenty polling to the 300s ceiling forever.
    ///
    /// It cannot fire against today's server, whose union matches the Swift enum exactly. It is
    /// pinned because this is a self-hosted product where operators upgrade on their own
    /// schedule and App Store builds lag, and the repo treats that skew as normal elsewhere.
    ///
    /// ⚠ `nonisolated static` for the same reason as `mediaRequest`: the behaviour worth
    /// asserting is invisible through `resolveLinkPreviews`, which only answers `[LinkPreview]`
    /// and cannot be reached without a live session. A test that rebuilt this envelope itself
    /// would assert a fact about `FailableDecodable` rather than about what this client does
    /// with it — which is exactly what the first version of its test did, and the revert drill
    /// said so.
    nonisolated static func decodePreviews(_ data: Data) -> [LinkPreview] {
        struct Envelope: Decodable { let previews: [FailableDecodable<LinkPreview>] }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?
            .previews.compactMap(\.value) ?? []
    }

    /// Resolve a `LinkPreview`'s `src`/`thumb` into a request.
    ///
    /// ⚠⚠ THE VALUE IS OPAQUE, and this is the only place that may interpret it. The server
    /// mints it and documents it as a string a client never constructs or parses; today it is
    /// either a proxy path (`/api/link-preview/media/<token>`) or, when the instance has a
    /// bucket-backed byte cache configured, an absolute URL on that bucket's public CDN. Both
    /// arrive in the same field and nothing distinguishes them on the wire.
    ///
    /// ⚠⚠ Concatenating unconditionally is what this replaces, and it did not fail loudly:
    /// `baseURL + "https://cdn.example.com/..."` yields `https://instance.examplehttps://...`,
    /// which `URL(string:)` rejects, so `fetchProxiedMedia` returned nil and
    /// `PreviewImageLoader` latched the path into `failed` — every cached preview permanently
    /// blank for the rest of the session, with no error surfaced anywhere.
    ///
    /// ⚠⚠ AN ABSOLUTE URL GETS NO BEARER TOKEN. It is a third-party host by construction, and
    /// `URLSession` forwards manually-set headers to whatever it is given — so sending one here
    /// would put the user's session token in a CDN operator's access log for every image. The
    /// header belongs only to requests aimed at this instance.
    ///
    /// ⚠ `nonisolated static`, taking the base and the token rather than reading them off
    /// `self`. Both are `private` state on a `@MainActor` class, so an instance method could
    /// only be exercised by driving a whole configured client from the main actor — and the two
    /// properties worth asserting (an absolute URL is not concatenated onto the base, and never
    /// carries the token) are invisible from `fetchProxiedMedia`, which only answers `Data?`. A
    /// wrong URL and an unreachable server look identical through it. The function touches no
    /// actor state, so isolating it buys nothing and costs testability.
    nonisolated static func mediaRequest(
        for path: String,
        baseURL: String,
        token: String?
    ) -> URLRequest? {
        if let absolute = URL(string: path), absolute.scheme != nil {
            guard absolute.scheme == "https" || absolute.scheme == "http" else { return nil }
            return URLRequest(url: absolute)
        }
        // ⚠⚠ The relative branch must be genuinely relative TO THE ROOT, or the concatenation
        // moves the host. `baseURL + "api/media/x"` is `https://chat.exampleapi/media/x`, whose
        // host is `chat.exampleapi` — a domain someone else can register — and this is the
        // branch that attaches the Bearer token. Nothing the current server mints looks like
        // that, which is exactly why it needs stating: it is the one path where a change at the
        // other end of the wire turns a cosmetic bug into handing out the session token.
        guard path.hasPrefix("/") else { return nil }
        guard let token, let url = URL(string: baseURL + path) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Fetch bytes for a preview image.
    ///
    /// `path` is a server-minted value out of a `LinkPreview` — never something built here.
    /// A proxy path needs a `URLRequest` rather than a plain `UIImage(contentsOf:)` because the
    /// proxy is authenticated and native auth is a Bearer header, not a cookie.
    ///
    /// Caching is the shared `URLCache`'s job — the server marks these `immutable` with a long
    /// max-age, and the token is a pure function of the URL so it always denotes the same bytes.
    ///
    /// ⚠ That only works because `previewCache` below is sized for it. `URLCache.shared` refuses
    /// to store any single response larger than ~5% of its capacity, which against the default
    /// 10 MB disk budget is roughly 512 KB — under the size of a typical full-width preview
    /// image. Left on the default, these were silently re-downloaded on every launch and after
    /// every NSCache eviction, and the `max-age` bought nothing at all.
    func fetchProxiedMedia(path: String) async -> MediaFetch {
        guard let request = Self.mediaRequest(for: path, baseURL: baseURL, token: token) else {
            return .permanent
        }
        do {
            let (data, response) = try await mediaSession.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) { return .success(data) }
            // ⚠⚠ 503 means COME BACK. The byte proxy maps a transient origin refusal — a 429,
            // a 5xx, and in particular opengraph.githubassets.com's 100-request budget, which a
            // channel with a run of GitHub links spends in one burst — to 503 + Retry-After, and
            // keeps 404 for a refused content type. Treating every non-2xx alike is the bug the
            // web had in the other direction: an <img> takes 404 as final and never re-asks, so
            // a minute of throttling became permanently blank images no reload could repair.
            return code == 503 || code == 429 || (500..<600).contains(code)
                ? .retryable : .permanent
        } catch {
            // A dropped connection says nothing about the file.
            return .retryable
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
        onProgress: @escaping @Sendable (Double) -> Void,
        onServerProgress: @escaping @Sendable (UploadServerProgress) -> Void
    ) async throws -> UploadResponse {
        guard let token, let url = URL(string: baseURL + "/api/uploads") else {
            throw UploadError.notSignedIn
        }

        let body = try MultipartBody.assemble(
            token: progressToken, fileURL: fileURL, filename: filename, mime: mime
        )
        defer { try? FileManager.default.removeItem(at: body.fileURL) }

        // Registered before a byte goes out, and torn down on every exit — including the
        // throws below, which is why it's a `defer` rather than a line after the response.
        // A sink left behind would be a leak keyed on a token nothing will ever send again.
        uploadProgressSinks[progressToken] = onServerProgress
        defer { uploadProgressSinks.removeValue(forKey: progressToken) }

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

    private static func sinceQuery(_ since: Int) -> String {
        since > 0 ? "?since=\(since)" : ""
    }

    /// http → ws, https → wss. Replacing only the leading `http` turns the trailing `s`
    /// of `https` into `wss` for free.
    private static func wsBase(_ base: String) -> String {
        base.replacingOccurrences(of: "^http", with: "ws", options: .regularExpression)
    }

}
